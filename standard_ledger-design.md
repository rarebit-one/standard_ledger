# `standard_ledger`: Tech Design

**Status:** Current as of v0.6.0
**Owner:** Platform
**Last updated:** 2026-09-24

This document describes the gem as it ships in 0.6.0. Versions 0.1 through 0.5
shipped a much larger declarative projection engine. §8 records what that
engine was and why 0.6.0 removed it, so nobody rebuilds it from scratch
without the adoption evidence.

## 1. Problem

Our Rails apps keep building immutable journal tables: commission entries,
runner-usage entries, device and batch events, prompt transactions, voucher
records. Each row is a permanent fact that billing, analytics or a cached
aggregate is derived from. Written ad hoc, these tables drift in three ways:

- **Mutability.** Nothing stops a later `update!` or `destroy` from rewriting
  history.
- **Idempotency.** Retries (webhooks, jobs, operator re-runs) double-insert
  unless every call site rescues `RecordNotUnique` correctly.
- **Result handling.** Each app wraps `create!` in its own Result type in a
  slightly different way.

Deriving state from those entries is a separate problem, and in practice every
app already solves it in its own code (see §8).

## 2. Goals

- One shared contract for immutable, append-only, idempotent entry tables,
  applied to the host's existing models. **The gem does not own the schema.**
- A `post` helper that returns a Result, including the host's own Result type.
- A safe wrapper for refreshing host-owned PostgreSQL materialized views, since
  several apps derive read models that way.
- A small surface. Anything that no consumer calls gets deleted.

## 3. Non-goals

- **Not a projection engine.** The gem doesn't keep aggregates up to date. The
  host derives state itself (§5.3, §5.4).
- **Not** double-entry bookkeeping, a money library, an event bus, or CQRS.
- **Not** a replacement for `standard_audit`. Audit records "who did what"
  with free-form metadata. Ledger records typed, immutable, idempotent facts.
  A single operation often writes one of each.
- **Not** responsible for the host's transactions. `post` runs inside
  whatever transaction the caller opened.

## 4. Consumers (as of 2026-09-24)

| App | Entries | Uses |
|---|---|---|
| jumpdrive-web (control-plane) | `RunnerUsageEntry` | `Entry`, `StandardLedger.post` (`app/services/runner_usage.rb`) |
| fundbright-web | `CommissionEntry`, `Validation` | `Entry`, `StandardLedger.post` (`Billing::CrystallizeCommission`), `Projection` subclass `Validations::ProfileProjector` called from `Borrowers::RefreshAfterValidation`, `result_adapter` |
| sidekick-web | `DeviceEvent`, `BatchEvent` | `Entry`, `StandardLedger.refresh!` for 13 Scenic matviews (`RefreshMaterializedViewsJob`), rescues `RefreshInsideTransaction`, requires `standard_ledger/rspec` |
| luminality-web | `PromptTxn` | `Entry`. Its only matview (`user_prompt_inventories`) was dropped on 2026-09-24 (luminality-web#1175), so it no longer calls `refresh!`. |

nutripod-web does not use the gem.

## 5. Public API

### 5.1 Entry

```ruby
class VoucherRecord < ApplicationRecord
  include StandardLedger::Entry

  ledger_entry kind:            :action,            # column holding the entry kind
               idempotency_key: :serial_no,         # nil → not idempotent (explicit opt-out)
               scope:           :organisation_id,   # idempotency index is scoped by these columns
               immutable:       true,               # default
               allow_destroy:   false               # default; true only for dependent: :destroy cleanup
end
```

- Persisted immutable rows are `readonly?`: `save`/`update` raise
  `ActiveRecord::ReadOnlyRecord`. New rows stay writable.
- `destroy` raises unless `allow_destroy: true`.
- `create!` rescues `RecordNotUnique` **only** for the idempotency index,
  finds the existing row and returns it with `idempotent? == true`. A
  collision on any other unique index re-raises. Block-form `create!` isn't
  covered, because AR passes no attributes hash to build the lookup from.
- The idempotency index is validated on first use. A missing index raises
  `MissingIdempotencyIndex`. It isn't checked at boot, because the table may
  not exist yet when the class loads.
- `scope:` is stored as a flat array.
- `<prefix>.entry.created` fires `after_commit on: :create`, so it runs for
  real INSERTs only and never for idempotent returns.

### 5.2 `StandardLedger.post`

```ruby
StandardLedger.post(EntryClass, kind:, targets: {}, attrs: {})
```

Maps `kind` onto the configured kind column, assigns each `targets:` entry
through its `belongs_to` association (an unknown key raises `ArgumentError`),
merges `attrs:`, and calls `create!`. It returns a success Result
(`idempotent?` set on an idempotent return), or a failure Result carrying
`errors.full_messages` on `RecordInvalid`. `projections` is `{}`. The
key stays only so existing adapters keep their signature.

### 5.3 `StandardLedger::Projection`

A plain base class with `apply(target, entry)` (which raises
`NotImplementedError`) and `rebuild(target)` (which raises `NotRebuildable`).
The gem never calls it. It exists so host projectors share one shape and fail
clearly when a method is missing. fundbright's `Validations::ProfileProjector`
is the reference user.

### 5.4 `StandardLedger.refresh!`

```ruby
StandardLedger.refresh!(view_name, concurrently: nil) # true | false | :auto | nil
```

- The view name must match a bare or `schema.view` identifier. Anything else
  raises `ArgumentError` before any SQL is sent.
- `nil` resolves from `Config#matview_refresh_strategy`: `:concurrent` becomes
  `true`, `:blocking` becomes `false`, `:auto` becomes `:auto`.
- `true` inside an open transaction raises `RefreshInsideTransaction` before
  any SQL is sent.
- `:auto` resolves to `CONCURRENTLY` only when all of these hold:
  1. no transaction is open;
  2. `pg_class.relispopulated` is true for the view;
  3. `pg_index` has a valid unique index on it with `indpred IS NULL` and
     `indexprs IS NULL`, which is Postgres's own requirement for
     `CONCURRENTLY`.

  Otherwise it runs a plain refresh. The probe is one catalog query
  (`to_regclass(?)` with the name bound as a literal). A missing view resolves
  to plain, so Postgres raises its own "relation does not exist" error. If the
  probe raises, the error is reported via `Rails.error.report(handled: true,
  severity: :warning, source: "standard_ledger")` (or
  `ActiveSupport.error_reporter` outside Rails) and the refresh runs plain.
  All of these branches were checked against PostgreSQL 17: an empty view,
  populated with a unique index, no unique index, a partial unique index, an
  expression unique index, a refresh inside a transaction, and a missing view.
- On success it emits `<prefix>.projection.refreshed` and returns a Result with
  `projections[:refreshed] = [{ view:, concurrently: <resolved Boolean> }]`.
  If the SQL fails, it emits `<prefix>.projection.failed`, reports the error via
  `Rails.error.report(handled: false, severity: :error)` (since 0.7) and
  re-raises. Rails' reporter skips an already-reported exception, so a host
  rescue that reports again, or the job executor, doesn't double-report.

The motivating caller is sidekick's `RefreshMaterializedViewsJob`. It tried
`concurrently: true`, rescued `PG::ObjectNotInPrerequisiteState` (empty view)
and `RefreshInsideTransaction` (transactional specs), then retried with
`concurrently: false`. `:auto` makes that decision up front and doesn't pay for
a failed statement.

### 5.5 Configuration

```ruby
StandardLedger.configure do |c|
  c.matview_refresh_strategy = :concurrent # | :blocking | :auto
  c.result_class             = ApplicationOperation::Result
  c.result_adapter           = ->(success:, value:, errors:, entry:, idempotent:, projections:) { ... }
  c.notification_namespace   = "standard_ledger"
end
```

`custom_result?` is true only when both `result_class` and `result_adapter`
are set. The adapter always gets all six keywords.

### 5.6 Events

Events go through `Rails.event` on Rails 8.1+, and
`ActiveSupport::Notifications` otherwise. The backend is chosen per call.
Subscriber exceptions are swallowed.

- `<prefix>.entry.created`: `entry:`, `kind:`, `targets:`
- `<prefix>.projection.refreshed`: `view:`, `concurrently:`, `duration_ms:`
- `<prefix>.projection.failed`: `view:`, `concurrently:`, `mode: :matview`, `error:`

The `projection.*` names are kept for subscriber compatibility.

### 5.7 Test support

`require "standard_ledger/rspec"` defines the `post_ledger_entry` block
matcher, which listens on the same channel `EventEmitter` uses. It registers
no hooks.

## 6. Layout

```
lib/
├── standard_ledger.rb          # configure / config / reset! / post / refresh!
├── standard_ledger/
│   ├── version.rb
│   ├── config.rb
│   ├── errors.rb               # Error, NotRebuildable, MissingIdempotencyIndex, RefreshInsideTransaction
│   ├── event_emitter.rb
│   ├── result.rb
│   ├── entry.rb
│   ├── projection.rb
│   ├── matview.rb              # REFRESH SQL, :auto probe (@api private)
│   ├── rspec.rb
│   └── rspec/matchers.rb
└── generators/standard_ledger/install/   # rails g standard_ledger:install
```

There is no Rails engine: the gem has no routes, tables, jobs or rake tasks.
Rails finds the generator on the load path. Runtime dependencies are
`activerecord`, `activesupport` and `railties` (for the generator), all
`>= 8.1`. Ruby `>= 4.0`.

## 7. Testing

The spec suite runs on in-memory SQLite. Refresh specs stub
`connection.execute` and `connection.select_one` to capture the SQL the gem
would send and to feed probe results. The `:auto` catalog query was also run
against a real PostgreSQL 17 server during 0.6.0 development (§5.4).

## 8. History: the projection engine (0.1–0.5, removed in 0.6.0)

The original design (May 2026) aimed to capture "immutable entry → N aggregate
projections" as a declarative DSL. `include StandardLedger::Projector` and
`projects_onto :target, mode:` offered six modes: `:inline` (after_create,
coalesced counters, optional `lock: :pessimistic`), `:async` (post-commit
`ProjectionJob` with `with_lock`), `:sql` (a recompute `UPDATE`), `:trigger`
(a host-owned DB trigger, plus rebuild SQL and a `standard_ledger:doctor`
presence check), `:matview` (scheduled `MatviewRefreshJob`) and `:manual`.
Around them sat `StandardLedger.rebuild!` log replay, `with_modes` test
overrides and `PartialFailure`.

The plan was for each app to move its bespoke projection onto one of those
modes. Adoption went differently. By September 2026 an audit of every
consumer's `main` (app, lib, config, spec, db) found **no** call to
`projects_onto`, `Projector`, any mode, `ProjectionJob`, `MatviewRefreshJob`,
`rebuild!`, `with_modes` or `standard_ledger:doctor`. What happened instead:

- fundbright deliberately declared no `projects_onto` on `Validation`. It
  calls `Validations::ProfileProjector#apply` / `#rebuild` from its own
  operation, and `CommissionEntry` is journal-only.
- sidekick drives its matviews from its own recurring job through
  `refresh!`.
- luminality's single matview was unused and has been dropped.
- nutripod, the seed of the original design, never adopted the gem.

The engine was about 1,400 lines of code plus about 2,700 lines of specs that
only its own tests exercised. 0.6.0 removed it and kept exactly what consumers
use. If a real need for declarative projections comes back, start from this
history and the git tag `v0.5.1` rather than from a blank page.

## 9. Open questions

- **Coupling with `standard_audit`.** Still deliberately absent. A host that
  wants an audit row per entry subscribes to `entry.created`.
- **Event names.** `projection.refreshed` / `projection.failed` are now
  refresh-only and would read better as `matview.*`. A rename is deferred
  because it would break subscribers for no functional gain.
