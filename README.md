# standard_ledger

Immutable journal entries with declarative aggregate projections for Rails apps.

> **Status: v0.2.0** — production-ready for `:inline`, `:sql`, `:matview`,
> and `:trigger` projections (covering luminality-web, fundbright-web,
> sidekick-web, and nutripod-web's inventory). `:async` mode ships in a
> subsequent PR ahead of nutripod-web's payments / fulfillment adoption.
> See [`standard_ledger-design.md`](https://github.com/rarebit-one/standard_ledger/blob/main/standard_ledger-design.md)
> for the full design and rollout plan.

## What it is

Across our four Rails apps (nutripod-web, luminality-web, fundbright-web,
sidekick-web) we keep building the same thing: an immutable journal table
whose rows update one or more cached aggregates on parent records. Inventory
movements, voucher issuance, payment records, fulfillment records, prompt
transactions, entitlement grants, validation outcomes, device firmware
updates — same shape, eight different ad-hoc implementations.

`standard_ledger` extracts the pattern into a single declarative DSL that
lives on top of the host's existing ActiveRecord models. The gem **does not
own the schema** — host apps already have entry tables and aggregate columns,
and the gem adapts to them rather than replacing them.

## Sketch

```ruby
class VoucherRecord < ApplicationRecord
  include StandardLedger::Entry
  include StandardLedger::Projector

  ledger_entry kind:            :action,
               idempotency_key: :serial_no,
               scope:           :organisation_id

  projects_onto :voucher_scheme, mode: :inline do
    on(:grant)    { |scheme, _| scheme.increment(:granted_vouchers_count) }
    on(:redeem)   { |scheme, _| scheme.increment(:redeemed_vouchers_count) }
    on(:consume)  { |scheme, _| scheme.increment(:consumed_vouchers_count) }
    on(:clawback) { |scheme, _| scheme.increment(:clawed_back_vouchers_count) }
  end

  projects_onto :customer_profile,
                mode: :inline,
                if:   -> { customer_profile_id.present? } do
    on(:grant)    { |profile, _| profile.increment(:granted_vouchers_count) }
    on(:redeem)   { |profile, _| profile.increment(:redeemed_vouchers_count) }
    on(:consume)  { |profile, _| profile.increment(:consumed_vouchers_count) }
    on(:clawback) { |profile, _| profile.increment(:clawed_back_vouchers_count) }
  end
end
```

Post an entry with the module API (sugar over `VoucherRecord.create!`):

```ruby
result = StandardLedger.post(VoucherRecord,
  kind:    :grant,
  targets: { voucher_scheme: scheme, customer_profile: profile },
  attrs:   { organisation_id: org.id, serial_no: "v-2025-1" })

result.success?     # => true
result.entry        # => the persisted VoucherRecord
result.idempotent?  # => false (true on retry against the same serial_no)
result.projections  # => { inline: [:voucher_scheme, :customer_profile] }
```

Counters on both targets are incremented inside the same transaction as
the INSERT — if any projection raises, the entry rolls back too. Posting
twice with the same `serial_no` returns the original entry (with
`idempotent? == true`) and skips the projection.

Rebuild a target's projection from the log when its counters drift
or a projection bug needs replaying — extract a `Projection` subclass
that implements `rebuild(target)` and pass it via `via:`:

```ruby
class SchemeProjector < StandardLedger::Projection
  def apply(scheme, entry)
    scheme.increment(:"#{entry.action}_vouchers_count")
    scheme.save!
  end

  def rebuild(scheme)
    records = VoucherRecord.where(voucher_scheme_id: scheme.id)
    scheme.update!(
      granted_vouchers_count:  records.where(action: "grant").count,
      redeemed_vouchers_count: records.where(action: "redeem").count
    )
  end
end

# Single target, single class, or every target across every projection.
StandardLedger.rebuild!(VoucherRecord, target: scheme)
StandardLedger.rebuild!(VoucherRecord, target_class: VoucherScheme)
StandardLedger.rebuild!(VoucherRecord)
```

Each (target, projection) pair runs in its own transaction; failures
mid-loop are not unwound. Block-form (delta) projections raise
`NotRebuildable` because they cannot be reconstructed from the log
without a host-supplied recompute path.

For projections too expensive or stateful to run inside the entry's
transaction (jsonb rebuild, multi-row aggregate), use `mode: :async` —
the strategy enqueues `StandardLedger::ProjectionJob` from
`after_create_commit`, and the job runs `target.with_lock { projector.apply(target, entry) }`
on the configured ActiveJob backend:

```ruby
class Orders::FulfillableProjector < StandardLedger::Projection
  # Recompute the jsonb balance from the full log inside with_lock.
  # `:async` projectors must be retry-safe — async retries can run
  # `apply` more than once, so block-form per-kind handlers
  # (incrementing counters) are rejected at registration time.
  def apply(order, _entry)
    order.update!(
      fulfillable_balance: order.fulfillment_records.group(:key).sum(:amount)
    )
  end

  def rebuild(order)
    apply(order, nil)
  end
end

class FulfillmentRecord < ApplicationRecord
  include StandardLedger::Entry
  include StandardLedger::Projector

  belongs_to :order

  ledger_entry kind: :action, idempotency_key: :external_ref, scope: :organisation_id

  projects_onto :order, mode: :async, via: Orders::FulfillableProjector
end
```

Retries are capped by `Config#default_async_retries` (default 3); the
job emits `<prefix>.projection.applied` and `<prefix>.projection.failed`
events with an additional `attempt:` key so subscribers can tell
first-try success from retry success. Tests can force async projections
to run inline via `StandardLedger.with_modes(FulfillmentRecord => :inline) { ... }`
— the strategy short-circuits the enqueue and runs the projector
synchronously inside `with_lock`, so end-to-end coverage works without a
job runner.

For projections expressible as a single `UPDATE` over an aggregate of the
log, use `mode: :sql` — no Ruby-side handlers, no AR object loads, just
a recompute statement that runs in the entry's `after_create`:

```ruby
class VoucherRecord < ApplicationRecord
  include StandardLedger::Entry
  include StandardLedger::Projector

  ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id

  belongs_to :voucher_scheme

  projects_onto :voucher_scheme, mode: :sql do
    recompute <<~SQL
      UPDATE voucher_schemes SET
        granted_vouchers_count     = (SELECT COUNT(*) FROM voucher_records WHERE voucher_scheme_id = :target_id AND action = 'grant'),
        redeemed_vouchers_count    = (SELECT COUNT(*) FROM voucher_records WHERE voucher_scheme_id = :target_id AND action = 'redeem'),
        consumed_vouchers_count    = (SELECT COUNT(*) FROM voucher_records WHERE voucher_scheme_id = :target_id AND action = 'consume'),
        clawed_back_vouchers_count = (SELECT COUNT(*) FROM voucher_records WHERE voucher_scheme_id = :target_id AND action = 'clawback')
      WHERE id = :target_id
    SQL
  end
end
```

The gem binds `:target_id` from the entry's foreign key. The recompute
SQL is the entire contract — `:sql` projections are naturally
rebuildable: `StandardLedger.rebuild!` runs the same statement against
every target the log references.

When the host **already has** a database trigger that updates the
projection target on every entry INSERT, register it with `mode: :trigger`
so the gem records the trigger's name and the equivalent rebuild SQL —
without taking ownership of the trigger DDL. The host writes the trigger
in a Rails migration; the gem only consumes the metadata.

```ruby
class InventoryRecord < ApplicationRecord
  include StandardLedger::Entry
  include StandardLedger::Projector

  belongs_to :sku

  ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id

  projects_onto :sku, mode: :trigger,
                      trigger_name: "inventory_records_apply_to_skus" do
    rebuild_sql <<~SQL
      UPDATE skus SET
        total_count    = c.total_count,
        reserved_count = c.reserved_count,
        free_count     = c.total_count - c.reserved_count
      FROM (
        SELECT sku_id,
               COUNT(*) FILTER (WHERE action IN ('grant','adjust_in')) AS total_count,
               COUNT(*) FILTER (WHERE action = 'reserve')              AS reserved_count
        FROM inventory_records
        WHERE sku_id = :target_id
        GROUP BY sku_id
      ) c
      WHERE skus.id = :target_id AND skus.id = c.sku_id
    SQL
  end
end
```

The trigger continues to fire on every `INSERT` (the host owns the DDL);
the gem records the trigger name + rebuild SQL for two purposes:

- `StandardLedger.rebuild!(InventoryRecord, target: sku)` runs the
  recorded `rebuild_sql` with `:target_id` bound to each target's id.
- `bin/rails standard_ledger:doctor` verifies that every registered
  `:trigger` projection's named trigger exists in the connected schema
  (queries `pg_trigger`). Run this as a deploy-time check — migration
  drift surfaces immediately rather than at runtime. **Postgres-only**;
  the task raises on non-Postgres connections.

Registration rejects `via:`, `lock:`, and `permissive:` (none are
meaningful when the trigger itself is the contract). The `trigger_name:`
keyword is required; the block must call `rebuild_sql "..."` exactly
once with a SQL string containing the `:target_id` placeholder.

Refresh a `:matview` projection ad-hoc when the host needs immediate
read-your-write semantics (e.g. at the end of a draw operation, before
the next scheduled refresh would otherwise show stale counts):

```ruby
class PromptTxn < ApplicationRecord
  include StandardLedger::Entry
  include StandardLedger::Projector

  belongs_to :user_profile

  ledger_entry kind: :event, idempotency_key: nil

  projects_onto :user_profile,
                mode:    :matview,
                view:    "user_prompt_inventories",
                refresh: { every: 5.minutes, concurrently: true }
end

# Schedule the recurring refresh from the host (SolidQueue Recurring
# Tasks, sidekiq-cron, etc.) targeting:
#   StandardLedger::MatviewRefreshJob
#   args: ["user_prompt_inventories", { concurrently: true }]

# Ad-hoc refresh after a critical write:
StandardLedger.refresh!(:user_prompt_inventories)               # honors Config#matview_refresh_strategy
StandardLedger.refresh!("user_prompt_inventories", concurrently: true)
```

`StandardLedger.rebuild!(PromptTxn)` is equivalent to refreshing every
`:matview` projection on the entry class — for matview, refresh *is*
rebuild. Postgres has no partial-refresh primitive, so `target:` /
`target_class:` scope arguments are ignored for `:matview` projections
and the full view is always refreshed.

Note: the default `:concurrent` strategy (and `concurrently: true`) requires
a unique index on the matview — Postgres rejects `REFRESH MATERIALIZED VIEW
CONCURRENTLY` otherwise. Add a unique index in the host migration that
creates the view, or set `Config#matview_refresh_strategy = :blocking` (or
pass `concurrently: false` per-call) if a unique index isn't an option.

Five projection modes — pick per declaration:

| Mode | Where the work runs | Transactional? | Rebuildable? |
|---|---|---|---|
| `:inline` | `after_create`, in the entry's transaction | yes | yes (if projector implements `rebuild`) |
| `:async` | `after_create_commit` job, `with_lock` | no | yes (if projector implements `rebuild`) |
| `:sql` | `after_create`, single `UPDATE ... FROM (SELECT ...)` | yes | yes (rebuild = same SQL) |
| `:trigger` | the database, on INSERT | yes (same statement) | yes (host-owned trigger; gem records rebuild SQL) |
| `:matview` | scheduled `REFRESH MATERIALIZED VIEW CONCURRENTLY` | no | trivially (refresh = rebuild) |

## Installation

The gem is private during incubation. Pin from git:

```ruby
gem "standard_ledger", git: "https://github.com/rarebit-one/standard_ledger", ref: "<sha>"
```

Then run the install generator to drop a configured initializer in place:

```bash
bin/rails g standard_ledger:install
```

This writes `config/initializers/standard_ledger.rb` with commented-out
examples covering every public `Config` setting — uncomment and edit only
what you want to override. The generator is idempotent; re-running on an
existing initializer skips with a clear message (pass `--force` to
overwrite).

A typical configuration looks like:

```ruby
StandardLedger.configure do |c|
  c.default_async_retries     = 3
  c.scheduler                 = :solid_queue
  c.matview_refresh_strategy  = :concurrent

  # Optional — return the host's Result type from StandardLedger.post:
  c.result_class   = ApplicationOperation::Result
  c.result_adapter = ->(success:, value:, errors:, entry:, idempotent:, projections:) {
    ApplicationOperation::Result.new(success:, value: value || entry, errors:)
  }
end
```

## Testing

The gem ships an opt-in RSpec support file. Hosts add this to their
`spec/rails_helper.rb`:

```ruby
require "standard_ledger/rspec"
```

That registers a `before(:each)` hook that calls `StandardLedger.reset!`
between examples (so per-spec configuration doesn't leak), and exposes:

- `post_ledger_entry(EntryClass).with(...)` — a block matcher that
  subscribes to the `<namespace>.entry.created` notification for the
  duration of the block and asserts an entry of the expected class was
  written (with optional `kind:`/`targets:`/`attrs:` constraints).

  ```ruby
  it "records a voucher grant" do
    expect {
      Vouchers::IssueOperation.call(scheme: scheme, profile: profile)
    }.to post_ledger_entry(VoucherRecord).with(
      kind:    :grant,
      targets: { voucher_scheme: scheme, customer_profile: profile },
      attrs:   { serial_no: "v-2025-1" }
    )
  end
  ```

- `with_modes(EntryClass => :inline) { ... }` — forces specific entry
  classes' projections to run inline for the duration of the block. The
  override is thread-local and restored on block exit, so async-mode
  projections can be exercised end-to-end in a unit spec without a job
  runner.

  ```ruby
  it "fast-runs an async projection inline" do
    with_modes(PaymentRecord => :inline) do
      Orders::CheckoutOperation.call(...)
    end
  end
  ```

## Development

```bash
bundle install
bundle exec rspec
bundle exec rubocop
```

## Relationship to standard_audit

Different gems, different concerns:

- **`standard_audit`** — "user X took action Y on target Z," free-form
  metadata, no projection.
- **`standard_ledger`** — "this delta updates these targets," typed kind,
  mandatory projection.

A single host operation typically writes one of each, in one transaction.
Neither subsumes the other.

## License

MIT. See [MIT-LICENSE](MIT-LICENSE).
