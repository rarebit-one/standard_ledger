# `standard_ledger` — Tech Design

**Status:** Draft — initial framing 2026-05-03
**Owner:** Platform
**Last updated:** 2026-05-03
**Target release:** v0.1.0 (git source), v0.2.0 (rubygems)

## 1. Problem

Across four Rails 8 apps we keep building the same thing under different names: an immutable journal table whose rows update one or more cached aggregates on parent records. The pattern works, but each app re-implements it from scratch with subtly different rules for transactionality, idempotency, and recompute, so improvements don't compose:

- **nutripod-web** — `InventoryRecord` / `VoucherRecord` / `PaymentRecord` / `FulfillmentRecord`, each with its own update mechanism (DB trigger, `after_create_commit` + `increment_counter`, async `with_lock` job, async `with_lock` job over jsonb)
- **luminality-web** — `PromptTxn` (immutable) → `UserPromptInventory` (matview) and `Entitlement` (idempotent grants) → denormalized columns on `UserProfile`
- **fundbright-web** — `Offer` and `Validation` (immutable), with `RefreshAfterValidation` doing manual `update_all` against `BorrowerProfile.successful_loans_count` and a JSONB biodata snapshot
- **sidekick-web** — `DeviceFirmwareUpdate` (state-transitioning counters), `DeviceEvent`/`BatchEvent` (matview-backed fleet/batch stats), plus `HealthSnapshot` telemetry without a projection yet

The shape is identical: an immutable entry, a small set of aggregate targets, an "apply this delta to those targets" rule. What differs is *only* the projection mechanism. Today each app picks one; some pick four (nutripod uses all four mechanisms across its four ledgers). There is no shared module, no shared idempotency contract, no shared way to recompute a projection from the log when a bug ships.

## 2. Goals

- Provide a single Rails Engine that captures "immutable entry → N aggregate projections" as a declarative DSL on the host's existing models.
- **Don't own the schema.** Host apps already have entry tables and aggregate columns; the gem must adapt to them, not replace them.
- Standardize idempotency, transactional boundaries, and projection mode selection so the same entry can be ported between modes (e.g. `:async` → `:inline`) without rewriting the projector.
- Provide a deterministic **rebuild** path: replay the log to recompute any projection from scratch. Today only luminality (matview refresh) and fundbright (no-op, audit log only) have this; nutripod's payment balances cannot be rebuilt without bespoke code.
- Match the distribution pattern of `standard_id` / `standard_audit` / `standard_circuit` so consumers don't have to learn a new workflow.

## 3. Non-goals

- **Not** a double-entry bookkeeping library. None of our four apps need debits-equal-credits, account trees, or trial balances. fundbright is loan-lifecycle, not GL. If that need ever arises, it lives in a separate gem on top of this one.
- **Not** a money / currency library. Entries are typed by the host's columns (cents, BigDecimal, integer counts, jsonb). The gem is currency-agnostic.
- **Not** a replacement for `standard_audit`. Audit captures "who did what" with free-form metadata and no projection; ledger captures "this delta updates these targets" with mandatory projection. Both can write rows in the same transaction; neither subsumes the other (see §4).
- **Not** an event bus. Projections are local to the writing process or its job tier. If an event must leave the app, the host emits a separate `ActiveSupport::Notifications` event after the ledger write.
- **Not** a CQRS framework. There is no command bus, no event store schema, no aggregate roots in the DDD sense. The vocabulary is borrowed from event sourcing; the architecture is not.
- **Not** responsible for the host's transaction strategy. The host operation owns the outer `transaction { ... }`; the gem participates inside it.

## 4. Prior art and starting point

The starting implementation is nutripod's quartet of `*Record` models, the most uniform realization of the pattern in the workspace. Specifically:

- `nutripod-web/app/models/inventory_record.rb` (DB-trigger projection onto `Sku`)
- `nutripod-web/app/models/voucher_record.rb` (`after_create_commit` projection onto **two** parents — `VoucherScheme` and `CustomerProfile`)
- `nutripod-web/app/models/payment_record.rb` + `app/jobs/update_payable_job.rb` (async `with_lock` projection onto `Order.payable_*`)
- `nutripod-web/app/models/fulfillment_record.rb` + `app/jobs/update_fulfillable_job.rb` (async `with_lock` jsonb projection onto `Order.fulfillable_balance`)
- `nutripod-web/app/models/concerns/read_only.rb` (the immutability concern shared by all four)

These are the literal seed for the gem's DSL. Constraints/issues to fix or carry forward during extraction:

1. **`after_create_commit` is not transactional with the INSERT.** If the process dies between commit and callback, projection drifts permanently. The gem must offer a same-transaction inline mode as well.
2. **Multi-counter `increment_counter` calls are not atomic relative to each other.** Voucher's `update_voucher_scheme_counts` issues four separate `UPDATE`s; a crash between #2 and #3 leaves split-brain counters. The gem must coalesce per-target updates.
3. **No declared idempotency.** Today nutripod relies on serial-no uniqueness indexes plus the absence of a retry mechanism. luminality already does it correctly via `RecordNotUnique` rescue in `Purchases::FulfillmentOperation`. The gem must own this pattern.
4. **No rebuild path.** Inventory rebuilds via the trigger (re-INSERT); payments cannot be rebuilt at all without re-summing the log. The gem must provide `Projection.rebuild!` that recomputes from the entry log against the same projector.
5. **Operation result types are inconsistent.** `nutripod`'s `ApplicationOperation::Result`, `luminality`'s `Operation::Result`, `fundbright`'s sorbet-typed result, `sidekick`'s ad-hoc returns. The gem ships a tiny default but interoperates with the host's (§5.8).

`standard_audit` overlap is real and bounded: an audit row records "user X took action Y on target Z"; a ledger entry records "delta D applies to targets {T1, T2} with kind K". A single host operation typically writes both — one audit, one ledger entry, in one transaction. Neither knows about the other; the gem will state this explicitly in the README.

## 5. Public API

### 5.1 Declaring an entry

The host marks an existing model as a ledger entry by including the `Entry` concern and configuring the immutability/idempotency contract:

```ruby
class VoucherRecord < ApplicationRecord
  include StandardLedger::Entry

  ledger_entry kind:            :action,            # column holding the entry kind (enum/string)
               idempotency_key: :serial_no,         # nil → no idempotency
               scope:           :organisation_id,   # idempotency scoped per org
               immutable:       true                # default true; installs ReadOnly behavior
end
```

`ledger_entry` does the following:

- Marks the record class read-only after persistence (raises on `save`/`update`/`destroy` post-creation, matching today's `ReadOnly` concern).
- On `create`, traps `ActiveRecord::RecordNotUnique` against the configured idempotency index and returns the existing row instead of raising. `idempotent?` returns true on the returned row so callers can detect.
- Emits `standard_ledger.entry.created` via `ActiveSupport::Notifications` after commit. `standard_audit` consumers can subscribe; the gem itself does not call into audit.

**There is no `StandardLedger::LedgerEntry` model.** The gem provides no tables. Host owns the schema.

### 5.2 Declaring projections

Aggregate updates are declared on the entry, one block per target:

```ruby
class VoucherRecord < ApplicationRecord
  include StandardLedger::Entry
  include StandardLedger::Projector

  ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id

  projects_onto :voucher_scheme, mode: :inline do
    on(:grant)    { |scheme, _entry| scheme.increment(:granted_vouchers_count) }
    on(:redeem)   { |scheme, _entry| scheme.increment(:redeemed_vouchers_count) }
    on(:consume)  { |scheme, _entry| scheme.increment(:consumed_vouchers_count) }
    on(:clawback) { |scheme, _entry| scheme.increment(:clawed_back_vouchers_count) }
  end

  projects_onto :customer_profile,
                mode: :inline,
                if:   -> { customer_profile_id.present? } do
    on(:grant)    { |profile, _entry| profile.increment(:granted_vouchers_count) }
    on(:redeem)   { |profile, _entry| profile.increment(:redeemed_vouchers_count) }
    on(:consume)  { |profile, _entry| profile.increment(:consumed_vouchers_count) }
    on(:clawback) { |profile, _entry| profile.increment(:clawed_back_vouchers_count) }
  end
end
```

Rules:

- Each `projects_onto` declares **one** target association. Multi-target fan-out is two declarations, not one declaration with a list. This is intentional: the projector for a `VoucherScheme` is not the same as for a `CustomerProfile`, even when the column names are identical.
- `mode:` selects the projection strategy (§5.3). Different targets on the same entry can use different modes (e.g. inline for the scheme, async for the profile).
- `if:` is an optional guard; the projection is skipped when it returns falsey. Useful for nullable targets.
- The block defines per-kind handlers via `on(kind)`. `on(:_)` is the wildcard. Unhandled kinds raise at registration time (`StandardLedger::UnhandledKind`) unless the projection declares `permissive: true` — caught early instead of silently skipped.

For non-trivial projectors (jsonb shape, multi-row aggregates), extract a class:

```ruby
projects_onto :order, mode: :async, via: Orders::FulfillableProjector
```

```ruby
class Orders::FulfillableProjector < StandardLedger::Projection
  # called inside the async job, with target locked
  def apply(order, _entry)
    order.update!(
      fulfillable_balance: order.fulfillment_records.group(:key).sum(:amount),
      fulfillable_status:  order.fulfillment_records.group(:key).sum(:amount).values.all?(&:zero?) ? :fulfilled : :pending
    )
  end

  # called by Projection.rebuild! to recompute from the full log
  def rebuild(order)
    apply(order, nil)
  end
end
```

When `apply` and `rebuild` collapse to the same SQL (true for any "recompute from full log" projection — vouchers don't qualify because they use `increment_counter` deltas), the projector exposes only `rebuild` and the gem calls it for both paths. Delta-based projectors (vouchers) must implement `apply` and may opt out of rebuild by raising `StandardLedger::NotRebuildable`.

### 5.3 Projection modes

Five modes, each a strategy class implementing the same internal interface (`#call(entry, target_resolver)`). Mode is a per-projection choice; there is no global default.

| Mode | When the work runs | Transactional with entry INSERT? | Locking | Rebuildable from log? | Today's call site |
|---|---|---|---|---|---|
| `:inline` | inside `after_create` (still inside the entry's transaction) | **yes** | optimistic on counter UPDATE; opt-in pessimistic via `lock: :pessimistic` | If projector implements `rebuild` | analogue to nutripod vouchers, but transactional (today's `after_create_commit` is not) |
| `:async` | inside an `after_create_commit` job (`StandardLedger::ProjectionJob`) | no — committed before job runs | pessimistic (`with_lock`) by default | If projector implements `rebuild` | nutripod payments, fulfillment |
| `:sql` | inside `after_create`, single `update_all` (no Ruby pre-read of target row) | **yes** | row-level write lock from the UPDATE | If `rebuild` SQL is provided | fundbright `RefreshAfterValidation` |
| `:trigger` | the database, on INSERT | **yes** (same statement) | DB-level | rebuild = `TRUNCATE skus_counters; INSERT ... FROM inventory_records` | nutripod inventory |
| `:matview` | scheduled refresh (`REFRESH MATERIALIZED VIEW CONCURRENTLY`) | no — refresh on schedule | view-level | trivially: refresh = rebuild | luminality `UserPromptInventory`, sidekick `DeviceFleetStat` |

#### 5.3.1 `:inline`

The default for delta-based counter updates. Runs inside `after_create`, which fires before the transaction commits. If the host wraps `VoucherRecord.create!` in a larger transaction, the projection participates; if anything raises, both the entry and the counter update roll back.

```ruby
projects_onto :voucher_scheme, mode: :inline do
  on(:grant) { |s, _| s.increment(:granted_vouchers_count) }
end
```

`#increment` issues a `UPDATE ... SET col = col + 1 WHERE id = ?`. Multiple counter updates against the same row coalesce into one UPDATE before flush — this fixes the "split-brain across four UPDATEs" problem in today's voucher callback.

Pessimistic locking is opt-in for projections where the new value depends on the old:

```ruby
projects_onto :wallet, mode: :inline, lock: :pessimistic do
  on(:debit)  { |w, e| w.update!(balance: w.balance - e.amount) }
  on(:credit) { |w, e| w.update!(balance: w.balance + e.amount) }
end
```

#### 5.3.2 `:async`

Used when the projection is too expensive or stateful for the entry's transaction (jsonb rebuild, multi-row aggregate). The gem ships `StandardLedger::ProjectionJob` which:

1. Resolves the target.
2. Wraps `target.with_lock { projector.apply(target, entry) }`.
3. On failure, retries up to N times (configurable per-projection, default 3) before dead-lettering.

This is exactly nutripod's `UpdatePayableJob` shape, generalized. The host can supply its own job class via `job: Orders::FulfillableProjectionJob` if it needs custom queue routing or telemetry. The gem's default job uses the host's default queue adapter (SolidQueue in all four apps).

#### 5.3.3 `:sql`

For projections expressible as a single `UPDATE` driven by an aggregate over the log. Lower overhead than `:inline` for "recompute from scratch" projections and naturally rebuildable.

```ruby
projects_onto :sku, mode: :sql do
  recompute <<~SQL
    UPDATE skus SET
      total_count    = (SELECT COALESCE(SUM(CASE WHEN action IN ('increase','decrease') THEN quantity ELSE 0 END), 0) FROM inventory_records WHERE sku_id = skus.id),
      reserved_count = (SELECT COALESCE(SUM(CASE WHEN action IN ('reserve','release') THEN quantity ELSE 0 END), 0) FROM inventory_records WHERE sku_id = skus.id),
      free_count     = total_count - reserved_count
    WHERE id = :target_id
  SQL
end
```

The gem binds `:target_id` from the entry's foreign key. `Projection.rebuild!` runs the same statement with `WHERE id IN (?)` over a batch — the same SQL serves both paths.

#### 5.3.4 `:trigger`

The host writes the trigger in a Rails migration; the gem does **not** create or manage triggers. This is deliberate — triggers are versioned by `db/schema.rb` like any DDL, and giving a Ruby DSL the power to install/replace triggers is a deploy footgun (silent re-creation on `db:schema:load` against a non-empty DB). Instead:

```ruby
projects_onto :sku, mode: :trigger,
              trigger_name: "inventory_records_apply_to_skus" do
  rebuild_sql <<~SQL
    UPDATE skus SET total_count = ..., reserved_count = ..., free_count = ...
    FROM (SELECT sku_id, ... FROM inventory_records GROUP BY sku_id) c
    WHERE skus.id = c.sku_id
  SQL
end
```

The gem records the trigger's name and rebuild SQL for two purposes:

- `Projection.rebuild!` runs the rebuild SQL when invoked.
- A diagnostic rake task (`standard_ledger:doctor`) verifies the named trigger exists in the schema; warns if missing. Migration drift is caught at deploy time, not at runtime.

#### 5.3.5 `:matview`

The host owns the view (created in a migration via `scenic` or hand-rolled SQL); the gem owns the refresh schedule.

```ruby
projects_onto :user_profile, mode: :matview,
              view: "user_prompt_inventories",
              refresh: { every: 5.minutes, concurrently: true }
```

The gem schedules `StandardLedger::MatviewRefreshJob` via the host's scheduler (SolidQueue Recurring Tasks in all four apps; configurable). `concurrently: true` adds `CONCURRENTLY` to the refresh statement, requires a unique index on the view (validated at boot if `concurrently: true`).

A `StandardLedger.refresh!(:user_prompt_inventories)` API exists for ad-hoc refresh after critical writes — luminality's prompt-draw flow can invoke it at the end of the operation to give users immediate read-your-write semantics on the projection (today this is missed; users see stale counts until the next 5-min refresh).

#### 5.3.6 Mode selection guidance (in the README)

- **Read-your-write required, simple delta** → `:inline`
- **Read-your-write required, complex projector** → `:sql` (if expressible) or `:inline` with `lock: :pessimistic`
- **Read-your-write *not* required, projector is heavy** → `:async`
- **Already have a trigger** → `:trigger` (no rewrite required)
- **Projection is a query, not a delta** → `:matview`

### 5.4 Posting an entry

Two equivalent forms — pick whichever fits the call site:

```ruby
# 1. Direct create — works for any host with an Entry-typed model
VoucherRecord.create!(action: :grant, voucher_scheme: scheme, customer_profile: profile, serial_no: ...)

# 2. Module-level form — for parity with StandardAudit.record / StandardCircuit.run
StandardLedger.post(VoucherRecord,
                    kind: :grant,
                    targets: { voucher_scheme: scheme, customer_profile: profile },
                    attrs:   { serial_no: ... })
```

Form (1) is the canonical API; (2) is sugar that maps `targets:` onto the entry's foreign keys via `reflect_on_association` and is useful in operations that write multiple entry types over time. Both go through the same code path; both are idempotent and return a `StandardLedger::Result` (§5.8).

Posting an entry inside a transaction the host already owns is the expected case. The gem does not start its own transaction for `:inline`/`:sql`/`:trigger` modes — the entry's `INSERT` and the projection's `UPDATE` ride the host's outer transaction.

### 5.5 Rebuilding projections from the log

A separate, explicit operation:

```ruby
StandardLedger.rebuild!(VoucherRecord, target: scheme)         # single target
StandardLedger.rebuild!(VoucherRecord, target_class: VoucherScheme)  # all schemes
StandardLedger.rebuild!(VoucherRecord)                         # all projections, all targets
```

This calls `projector.rebuild(target)` for each registered projection on the entry. For `:matview` projections it issues `REFRESH MATERIALIZED VIEW`; for `:trigger` and `:sql` it runs the recorded rebuild SQL; for `:inline` and `:async` it requires the projector to implement `rebuild`, raising `NotRebuildable` otherwise.

`rebuild!` runs in batches with configurable batch size (default 1000). It is **not** atomic across all targets — each target rebuilds in its own transaction. Concurrent writes to the entry log during rebuild produce eventually-correct results: a running rebuild for target T sees a consistent snapshot of the log up to its `SELECT`, and any entries written after that snapshot project normally via the entry's own callback.

This addresses one of the workspace's recurring problems: today, any bug in nutripod's payment projection is unrecoverable without bespoke code.

### 5.6 Configuration

```ruby
# config/initializers/standard_ledger.rb
StandardLedger.configure do |c|
  c.default_async_job  = StandardLedger::ProjectionJob   # default
  c.default_async_retries = 3                            # default
  c.scheduler          = :solid_queue                    # :solid_queue | :sidekiq_cron | :custom
  c.matview_refresh_strategy = :concurrent               # default; :blocking for views without unique idx
  c.result_class       = ::ApplicationOperation::Result  # interop with host (§5.8)
  c.notification_namespace = "standard_ledger"           # AS::Notifications event prefix
end
```

Matches `StandardId.configure` / `StandardAudit.configure` / `StandardCircuit.configure`.

### 5.7 ActiveSupport::Notifications

The gem instruments three events:

- `standard_ledger.entry.created` — fired after commit. Payload: `{ entry: <record>, kind:, targets: { name => target } }`.
- `standard_ledger.projection.applied` — fired after each projection writes. Payload: `{ entry:, target:, projection:, mode:, duration_ms: }`.
- `standard_ledger.projection.failed` — fired on projector exception. Payload: `{ entry:, target:, projection:, error: }`.

These are the only public extension points outside the DSL itself. `standard_audit` subscribes to the first; metric pipelines subscribe to the second and third.

### 5.8 Operation result interop

The gem ships its own minimal Result:

```ruby
module StandardLedger
  class Result
    attr_reader :value, :errors, :entry
    def success?;     @success; end
    def idempotent?;  @idempotent; end
  end
end
```

Returned by `StandardLedger.post` and `StandardLedger.rebuild!`.

Hosts that already have a Result type (nutripod's `ApplicationOperation::Result`, luminality's `Operation::Result`, fundbright's sorbet-typed Result) can register an adapter:

```ruby
StandardLedger.configure do |c|
  c.result_class = ApplicationOperation::Result
  c.result_adapter = ->(success:, value:, errors:, entry:, idempotent:) {
    ApplicationOperation::Result.new(success:, value: value || entry, errors:)
  }
end
```

When configured, `StandardLedger.post` returns the host's Result type. If the host's Result lacks an `idempotent?` field, the lambda owns the choice of whether to surface that signal (typically by stuffing it into `value`). The default adapter (gem's own Result) preserves it.

This solves the original request — define our own, but don't fight the host's — without introducing a duck-typing layer the gem has to maintain.

### 5.9 Test helper

```ruby
require "standard_ledger/rspec"
# registers RSpec.configure { |c| c.before(:each) { StandardLedger.reset! } }

# Block form — assert exactly one entry written
expect {
  Orders::Checkout.call(...)
}.to post_ledger_entry(PaymentRecord).with(kind: :charge, amount: 1000)

# Mode override for fast unit specs
StandardLedger.with_modes(payment_record: :inline) do
  Orders::Checkout.call(...)
end
```

`with_modes` lets specs avoid background jobs by forcing async projections inline; the host opts in per-spec rather than monkey-patching the entry. Auto-cleanup via the registered hook.

## 6. Idempotency strategy

Every entry that can be retried must declare `idempotency_key:`. The gem enforces this contract:

1. The host adds a unique index on the entry table over `(scope, kind, idempotency_key)` (or the configured subset).
2. On `create`, the gem catches `ActiveRecord::RecordNotUnique` against that index, looks up the existing row, and returns it with `idempotent? == true`.
3. The projection is **not** re-applied on idempotent returns — the original write already projected.

The gem refuses to register an `Entry` declaration whose `idempotency_key:` is non-nil if no matching unique index exists at boot. This is checked once via `connection.indexes(table)` and cached. The check fails loud at app boot, not silently at runtime — pulled from luminality's already-correct `Entitlement` pattern.

For entries that genuinely cannot be retried safely (telemetry events with no natural key, e.g. sidekick's `HealthSnapshot`), declare `idempotency_key: nil` explicitly. This is a deliberate ceremony; "I considered idempotency and chose not to have it" should not be the default.

## 7. Transactional semantics

The single most consequential design decision: **`:inline`, `:sql`, and `:trigger` modes are transactional with the entry INSERT; `:async` and `:matview` are not.**

Concretely:

- `:inline`/`:sql`/`:trigger` projections fire from `after_create` (still inside the transaction). If the host's outer `transaction { ... }` rolls back, the projection rolls back. If any projection raises, the entry rolls back too.
- `:async` projections fire from `after_create_commit`. The entry is durable before the projection runs; a process death between commit and job enqueue produces drift. The projection job must be idempotent against re-runs (because SolidQueue can run a job twice on retry).
- `:matview` projections are decoupled by definition; refresh sees whatever the log contains at the moment the refresh statement runs.

This split is named explicitly in `StandardLedger.post`'s return: `result.projections` is `{ inline: [...], async: [...], matview: [...] }` so callers can distinguish "applied now" from "queued" from "scheduled."

For mixed-mode entries (e.g. nutripod fulfillment writes one `:async` projection onto Order; luminality entitlement writes both `:inline` UserProfile counters and a `:matview` UserPromptInventory refresh) the gem coordinates: inline projections all run before the transaction commits; commit happens; then async jobs are enqueued and matview refreshes are scheduled.

## 8. Multi-aggregate fan-out

A single entry projecting onto multiple targets is the bread-and-butter case (every app has it). The gem treats the projection list as ordered — declared order is execution order — for `:inline` and `:sql` modes, and unordered for `:async` (jobs are enqueued in declared order but execute concurrently). Hosts that need ordering across async projections must combine them into a single projector.

**Failure semantics for fan-out:**

- Inline mode: any projection raising aborts the entry's transaction. All-or-nothing.
- Async mode: per-projection retry; failed projection does not block others; exhausted retries dead-letter that projection only. The entry stays committed.
- Matview mode: refresh failures are reported via `standard_ledger.projection.failed` and retried on the next scheduled refresh.

`StandardLedger::PartialFailure` is raised by `post` when the inline portion succeeds but async enqueue fails (rare — usually a connection problem against the queue store). Hosts can choose to roll back or accept; the gem's default is to log and continue, since the entry is durable and async jobs can be re-enqueued.

## 9. Gem layout and distribution

```
standard_ledger/
├── standard_ledger.gemspec
├── Gemfile
├── lib/
│   ├── standard_ledger.rb
│   └── standard_ledger/
│       ├── version.rb
│       ├── engine.rb               # isolate_namespace StandardLedger
│       ├── config.rb
│       ├── result.rb
│       ├── entry.rb                # include StandardLedger::Entry
│       ├── projector.rb            # include StandardLedger::Projector
│       ├── projection.rb           # base class for projector classes
│       ├── modes/
│       │   ├── inline.rb
│       │   ├── async.rb
│       │   ├── sql.rb
│       │   ├── trigger.rb
│       │   └── matview.rb
│       ├── projection_job.rb
│       ├── matview_refresh_job.rb
│       ├── rebuild.rb              # StandardLedger.rebuild!
│       ├── doctor.rb               # rake standard_ledger:doctor
│       ├── notifications.rb        # AS::Notifications instrumentation
│       └── rspec.rb                # opt-in: require "standard_ledger/rspec"
├── spec/
│   ├── dummy/                      # minimal Rails app for engine specs
│   └── standard_ledger/...
├── lib/generators/standard_ledger/
│   └── install/
│       ├── install_generator.rb
│       └── templates/
│           └── standard_ledger.rb  # config/initializers template
├── .github/workflows/ci.yml        # matrix: ruby-3.4.4, ruby-4.0.1
├── .rubocop.yml
├── README.md
└── CHANGELOG.md
```

**Runtime dependencies:** `railties >= 8.0`, `activerecord >= 8.0`, `activejob >= 8.0`, `concurrent-ruby ~> 1.3`. No `globalid` (entry foreign keys are concrete columns; we don't go through GlobalID). No `scenic` (matview ownership stays in the host).

**Ruby requirement:** `>= 3.4`. CI matrix-tests 3.4.4 and 4.0.1.

**Initial distribution:** private git repo. Apps pull in via:

```ruby
gem "standard_ledger", git: "https://github.com/<org>/standard_ledger", ref: "<sha>"
```

**Promotion to rubygems:** target `v0.2.0` once nutripod-web has run the gem in production for at least two weeks across all four ledgers.

## 10. Rollout plan

**Step 1 — extract and stabilize (nutripod vouchers).** The textbook case: two-target inline counters, declared idempotency, no jsonb. Replace `VoucherRecord`'s `after_create_commit` callback with the gem DSL; verify `granted_vouchers_count` on `VoucherScheme` and `CustomerProfile` track identically; add the `Projection.rebuild!` test by truncating both counter columns and re-running. **Risk: low — this is the cleanest existing pattern.**

**Step 2 — nutripod inventory and payments.** Inventory exercises `:trigger` mode (gem records the existing trigger, `doctor` verifies it). Payments and fulfillment exercise `:async` mode against an `Order` jsonb projector. After this step the gem has covered four of the five modes (only `:matview` is unexercised). **Risk: medium — payments/fulfillment have the most state; if the gem gets `with_lock` semantics wrong, balances drift.**

**Step 3 — luminality entitlements and prompts.** Entitlements use `:inline` with idempotency-by-unique-index — this validates the gem's idempotency contract against luminality's existing `RecordNotUnique` rescue. Prompt draws use `:matview` — first matview adopter, validates `MatviewRefreshJob` and `StandardLedger.refresh!` for read-your-write. **Risk: medium — read-your-write semantics for prompt draws are user-visible; getting refresh timing wrong shows up immediately in the UI.**

**Step 4 — fundbright validation outcomes.** `Validation` already uses the project's `Immutable` concern and `RefreshAfterValidation` does manual `update_all`. Convert to `:sql` mode against `BorrowerProfile.successful_loans_count` and the JSONB biodata snapshot. Audit log stays untouched (lives in `standard_audit`). **Risk: low — the projection is already `update_all`; the gem just owns the wiring.**

**Step 5 — sidekick firmware and events.** `DeviceFirmwareUpdate`'s state-transitioning counters use `:inline` (multi-counter coalescing fixes a real concurrency hazard there). `DeviceEvent`/`BatchEvent` matview-backed stats use `:matview`. `HealthSnapshot` gains a projection for the first time (or stays unprojected — a deliberate `idempotency_key: nil` declaration). **Risk: low — sidekick's pattern is nearly identical to nutripod's by step 5.**

**Step 6 — promote to rubygems.** Once all four apps are green for two weeks AND `Projection.rebuild!` has been exercised in production at least once (proving the rebuild path actually works on real data), cut `v0.2.0` and republish. Apps move from `git:` source to `"~> 0.2"`.

"Green" for step 6 means: zero `standard_ledger.projection.failed` events attributable to gem bugs (mode-selection drift, rebuild bugs, idempotency rescue holes). Projector bugs in host code don't count against the green window.

No step is merged without the next step already in a worktree, so ownership is continuous.

## 11. Per-app ledger specifications

### 11.1 nutripod-web

| Entry | Targets | Mode(s) | Idempotency key | Notes |
|---|---|---|---|---|
| `InventoryRecord` | `Sku` (total/reserved/free) | `:trigger` | `(organisation_id, action, serial_no)` | Existing trigger stays; gem registers it for `doctor` and rebuild SQL |
| `VoucherRecord` | `VoucherScheme`, `CustomerProfile` (4 counters each) | `:inline` × 2 | `(organisation_id, action, serial_no)` | Replaces today's `after_create_commit` + 8 separate `increment_counter` calls; coalesces to 2 UPDATEs (one per target) |
| `PaymentRecord` | `Order` (`payable_balance`, `payable_status`, `total_paid`) | `:async` | none currently — **add** `(payable_id, payable_type, source_payload->'idempotency_key')` if Stripe events are replayed | Replaces today's `UpdatePayableJob`; projector is `Orders::PayableProjector` |
| `FulfillmentRecord` | `Order` (`fulfillable_balance` jsonb, `fulfillable_status`) | `:async` | similar — add if needed | Replaces `UpdateFulfillableJob`; projector is `Orders::FulfillableProjector` (jsonb GROUP BY rebuild) |

`AuditEvent` stays in `standard_audit`'s territory. The line is: if there's a projection target with cached state, it's a ledger; if the row is "for the record only," it's an audit log.

### 11.2 luminality-web

| Entry | Targets | Mode(s) | Idempotency key | Notes |
|---|---|---|---|---|
| `Entitlement` | `UserProfile` (`credits_balance`, `credits_purchased`, `pass_status`, `pass_ends_at`) | `:inline` | `(purchase_id, grantable_type, grantable_id)` (already exists) | Drops the manual `RecordNotUnique` rescue in `Purchases::FulfillmentOperation` |
| `PromptTxn` | `UserPromptInventory` (matview) | `:matview` | none — events are not idempotent today; consider adding `(drawable_id, drawable_type, prompt_template_id, created_at)` if drawing is retriable | View name `user_prompt_inventories`; refresh `every: 5.minutes, concurrently: true`; explicit `StandardLedger.refresh!(:user_prompt_inventories)` at end of `PromptPacks::DrawOperation` for read-your-write |
| `Purchase` | (none direct — drives Entitlement creation) | not a ledger entry | n/a | Stays a regular ActiveRecord; calls `Entitlement.create!` from `Purchases::FulfillmentOperation` |

### 11.3 fundbright-web

| Entry | Targets | Mode(s) | Idempotency key | Notes |
|---|---|---|---|---|
| `Validation` | `BorrowerProfile.successful_loans_count`, `BorrowerProfile.biodata` (jsonb) | `:sql` | per-application (one `Validation` per `Application`, already unique) | Replaces `RefreshAfterValidation`'s manual UPDATE; projector emits the same statement, plus rebuild SQL |
| `Offer` | (none — no projection target today) | not a ledger entry yet | n/a | Stays a plain immutable record. If `accepted_offers_count` ever lands on `BorrowerProfile`, becomes a ledger entry |
| `AuditLog` | (none) | not a ledger entry | n/a | Stays in `standard_audit`-territory pattern (events without projections) |

The narrow scope here reflects fundbright's current state: it has the strongest immutability story but the weakest projection footprint. Adopting the gem doesn't expand its surface; it standardizes the one place that already has the pattern.

### 11.4 sidekick-web

| Entry | Targets | Mode(s) | Idempotency key | Notes |
|---|---|---|---|---|
| `DeviceFirmwareUpdate` | `FirmwareUpdate` (4 state-counter columns) | `:inline` | `(firmware_update_id, device_id)` (one update per device per firmware) | Today's `after_create`/`after_update` hooks have a multi-counter race window; coalesced inline UPDATE fixes it |
| `DeviceEvent` | `DeviceFleetStat`, `BatchDeviceStat` (both matviews) | `:matview` × 2 | `(device_id, event_type, occurred_at)` if telemetry is retriable; else `nil` | Refresh schedule TBD by view query cost — start at `every: 1.minute` |
| `BatchEvent` | `Batch.status`, `BatchDeviceStat` | `:inline` (status), `:matview` (stat) | `(batch_id, event_type)` for state events; `nil` for shipped/closed if those are user-driven once-only | `BatchEvent.log!` helper becomes a thin wrapper around `BatchEvent.create!` |
| `ProvisioningToken` | `ProvisioningStation` (`active_tokens_count`, `tokens_count`) | `:inline` | n/a (not retriable; one row per token issuance) | Today's hooks are correct; gem just standardizes the wiring |
| `HealthSnapshot` | (none) | not a ledger entry | `idempotency_key: nil` (telemetry, no natural key) | Stays unprojected. If device health rollups land later, becomes a ledger entry |

## 12. Testing

Each integration has a dedicated spec file. Shared helpers:

```ruby
# spec/support/standard_ledger_helpers.rb
RSpec.configure do |c|
  c.before(:each) { StandardLedger.reset! }
end
```

Gem-level spec suite covers:
- `StandardLedger.post` happy path, idempotent path (`RecordNotUnique` rescue returns existing row, projection not re-applied), invalid kind raises `UnhandledKind`
- Each mode's transactional semantics — `:inline`/`:sql`/`:trigger` roll back with the host's outer transaction; `:async` survives rollback (or doesn't, depending on `after_create_commit` semantics — the spec pins which)
- Multi-target fan-out — declared-order execution for inline; per-projection failure isolation for async
- `Projection.rebuild!` against a synthetic log; assert post-rebuild counters equal the sum of the log's deltas
- Idempotency contract — registering an Entry with `idempotency_key:` but no matching unique index raises at boot
- `:trigger` mode `doctor` rake task — flags missing trigger, reports rebuild SQL on demand
- `:matview` mode — refresh job handles `CONCURRENTLY` correctly; missing unique index raises; ad-hoc `StandardLedger.refresh!` works
- Result interop — host `result_class` adapter is invoked when configured; default Result is returned otherwise
- `with_modes` test helper — async projections run inline within block; restored on exit

Per-app specs are thin: verify the app's entries register the expected projections, run one representative call site through `StandardLedger.post`, and run the rebuild path against a small synthetic log.

## 13. Risks and open questions

**Risk — abstraction premature for `:async` projector authors.** The gem's `:async` mode says "implement `apply` and `rebuild`," but most existing async projectors (nutripod payments, fulfillment) only have `apply` and would have to write `rebuild` for the first time during adoption. Mitigation: `:async` projectors can opt out of rebuild via `NotRebuildable`; the gem documents this as a known weakness for retrofit, not a goal. The "we can rebuild" promise is a goal for new ledgers, not a hard requirement for migration.

**Risk — multi-counter `increment_counter` coalescing changes observable timing.** Today nutripod's voucher callbacks issue four UPDATEs in sequence; observers (Sentry traces, replicas) see intermediate states. Coalescing into one UPDATE per target changes that. Mitigation: this is a strict improvement (atomicity), not a regression; document in CHANGELOG.

**Risk — `:trigger` mode's "host owns the trigger" stance leaves room for drift.** A host could rename a column on the projection target without updating the trigger; the gem can't catch this at boot. Mitigation: `standard_ledger:doctor` runs as a deploy-time rake task and reports trigger presence. Drift in trigger *contents* (vs. the recorded rebuild SQL) is out of scope.

**Open question — does the gem need a `bulk_post` API?** A common pattern is "checkout writes 10 fulfillment records in a loop." Today this fires 10 `after_create` callbacks. For inline/sql modes that's fine (transactional). For async it's 10 jobs enqueued — wasteful when one would suffice. Decision: defer to v0.3; for now, hosts can manually batch by calling the projector once after creating all entries in a transaction.

**Open question — coupling with `standard_audit`.** A natural extension is "every ledger entry also writes an audit row" via a default subscription on `standard_ledger.entry.created`. This binds the two gems where they're orthogonal today. Decision: do **not** ship this; document the subscription pattern in the README as a one-liner the host can add if it wants.

**Open question — projection ordering across entry types.** A single host operation may write `PaymentRecord` and `FulfillmentRecord` in the same transaction. Each has its own projections. Today the order is creation-order; declared. Is there ever a case where a host wants to reorder projection apply across entries? No example exists in the four apps. Decision: keep declared-order, document, revisit if a real case arises.

**Resolved — gem name.** `standard_ledger` stays. Matches `standard_id` / `standard_audit` / `standard_circuit` / `standard_health`. (Alternatives: `rarebit_journal`, `entry_log`, `ledger_kit` — all rejected as inconsistent with the suite.)

**Resolved — engine vs. plain gem.** Rails Engine for consistency, even though the gem ships no tables and no routes. Matches `standard_circuit`'s "engine for the wrapper benefits, no tables" precedent.

**Resolved — own Result class plus host adapter.** Ship `StandardLedger::Result`, allow host to register an adapter that translates to its own Result type. Default behavior unchanged for hosts that don't configure interop.

**Resolved — `standard_ledger` vs. `standard_audit`.** Different gems, different concerns. Audit = "for the record" with free-form metadata, no projection. Ledger = "this delta updates these targets" with mandatory projection. A single host operation typically writes one of each, in one transaction.
