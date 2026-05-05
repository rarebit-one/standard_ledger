# AGENTS.md - AI Agent Guide for StandardLedger

StandardLedger is a Ruby gem that captures the recurring "immutable journal entry → N aggregate projections" pattern as a declarative DSL on host ActiveRecord models. The design is documented in [`standard_ledger-design.md`](./standard_ledger-design.md); read it before making non-trivial changes.

> **Status: v0.2.0** — production-ready for `:inline`, `:sql`, `:matview`, and `:trigger` projections (covering luminality-web, fundbright-web, sidekick-web, and nutripod-web's inventory). `:async` mode ships in a subsequent PR ahead of nutripod-web's payments / fulfillment adoption. See `standard_ledger-design.md` for the full design and rollout plan.

## Quick Reference

```bash
# Run tests
bundle exec rspec

# Run a single spec file
bundle exec rspec spec/standard_ledger/config_spec.rb

# Run linting
bin/rubocop

# Auto-fix lint issues
bin/rubocop -A

# Security scans (matches CI)
bundle exec brakeman --no-pager --force
bundle exec bundler-audit --update
```

## Project Structure

```
standard_ledger/
├── lib/standard_ledger/
│   ├── version.rb        # Gem version
│   ├── errors.rb         # Error hierarchy
│   ├── event_emitter.rb  # Routes events to Rails.event.notify (Rails 8.1+) or ActiveSupport::Notifications
│   ├── result.rb         # StandardLedger::Result (default return type)
│   ├── config.rb         # StandardLedger.configure { |c| ... }
│   ├── engine.rb         # Rails engine boot hook
│   ├── entry.rb          # `include StandardLedger::Entry` concern
│   ├── projector.rb      # `include StandardLedger::Projector` concern + `projects_onto` DSL
│   ├── projection.rb     # Base class for class-form projectors
│   ├── modes/
│   │   ├── inline.rb     # `:inline` mode runtime — installs `after_create`, applies projections, coalesces multi-counter writes
│   │   ├── async.rb      # `:async` mode runtime — installs `after_create_commit`, enqueues ProjectionJob per (entry, target), honors `with_modes(:inline)` override
│   │   ├── sql.rb        # `:sql` mode runtime — installs `after_create`, runs the recompute SQL with `:target_id` bound from the entry's FK
│   │   ├── matview.rb    # `:matview` mode runtime — issues `REFRESH MATERIALIZED VIEW [CONCURRENTLY]`, no per-entry callback
│   │   └── trigger.rb    # `:trigger` mode runtime — no-op marker; the host owns the DB trigger, the gem records `trigger_name` + `rebuild_sql` for `rebuild!` and `doctor`
│   ├── jobs/
│   │   ├── matview_refresh_job.rb # ActiveJob wrapper around `StandardLedger.refresh!` for hosts to schedule
│   │   └── projection_job.rb      # ActiveJob class run by `:async` mode; resolves target, wraps `target.with_lock { projector.apply(target, entry) }`, retries up to `Config#default_async_retries`
│   └── tasks/
│       └── standard_ledger.rake   # `standard_ledger:doctor` — verifies every `:trigger` projection's named trigger exists in `pg_trigger` (Postgres-only)
├── lib/generators/standard_ledger/install/
│   ├── install_generator.rb       # `rails g standard_ledger:install`
│   └── templates/initializer.rb.tt # Generated initializer with commented-out Config DSL
└── spec/                 # RSpec tests
```

`StandardLedger.rebuild!(EntryClass, target:, target_class:, batch_size:)` (in `lib/standard_ledger.rb`) drives the log-replay path: for `:inline` projections it dispatches to the registered projector class's `rebuild(target)` (firing `<prefix>.projection.rebuilt` per success); for `:sql` and `:trigger` projections it runs the recorded recompute / rebuild SQL with `:target_id` bound to each target; for `:matview` projections it issues a single `REFRESH MATERIALIZED VIEW [CONCURRENTLY] <view>` (firing `<prefix>.projection.refreshed`) — refresh *is* rebuild for matview. It refuses block-form (delta) `:inline` projections plus modes other than `:inline`/`:sql`/`:matview`/`:trigger` until the remaining `:async` PR lands.

`StandardLedger.refresh!(view_name, concurrently: nil)` is the ad-hoc matview refresh API for hosts that need immediate read-your-write semantics (e.g. at the end of an operation, before the next scheduled refresh would otherwise show stale counts). `StandardLedger::MatviewRefreshJob` is the ActiveJob wrapper hosts point their scheduler (SolidQueue Recurring Tasks, sidekiq-cron, etc.) at.

The remaining `:async` mode lands in a subsequent PR — see `CHANGELOG.md` "Pending" for the complete list. `StandardLedger.post(EntryClass, kind:, targets:, attrs:)` ships in the same PR as the inline runtime.

The `standard_ledger:doctor` rake task (in `lib/tasks/standard_ledger.rake`, auto-loaded by `Engine.rake_tasks`) iterates every registered `:trigger` projection across loaded entry classes and queries `pg_trigger` to verify each named trigger exists in the connected schema. Postgres-only by design; nutripod-web is the only adopter today and runs Postgres. Run as a deploy-time check — exits 1 with a stderr report when triggers are missing.

## Key Patterns

### Entry + Projector DSL

The host marks an existing model as a ledger entry and declares one or more projections. Each `projects_onto` registers a `Definition` struct on the host class; the gem reads these at runtime to drive `StandardLedger.post`.

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
end
```

For non-trivial projectors (jsonb shape, multi-row aggregates), extract a `StandardLedger::Projection` subclass with `apply` and `rebuild` and pass it via `via:`.

### Five projection modes

Each mode is a strategy class implementing the same internal interface. Hosts pick per-projection; different projections on the same entry can use different modes.

| Mode | Where | Transactional with INSERT? | Rebuildable from log? |
|---|---|---|---|
| `:inline` | `after_create`, in entry's transaction | yes | if projector implements `rebuild` |
| `:async` | `after_create_commit` job + `with_lock` | no | if projector implements `rebuild` |
| `:sql` | `after_create`, single `UPDATE ... FROM (SELECT ...)` | yes | yes (rebuild = same SQL) |
| `:trigger` | the database, on INSERT | yes | yes (host-owned trigger; gem records rebuild SQL) |
| `:matview` | scheduled `REFRESH MATERIALIZED VIEW CONCURRENTLY` | no | trivially (refresh = rebuild) |

See design doc §5.3 for full semantics and §5.3.6 for the selection cheat sheet.

### Result class + host interop

The gem ships `StandardLedger::Result` with `success?`/`failure?`/`idempotent?`/`entry`/`value`/`errors`/`projections`. Hosts with their own Result type (e.g. `ApplicationOperation::Result`) wire up an adapter:

```ruby
StandardLedger.configure do |c|
  c.result_class   = ApplicationOperation::Result
  c.result_adapter = ->(success:, value:, errors:, entry:, idempotent:, projections:) {
    ApplicationOperation::Result.new(success:, value: value || entry, errors:)
  }
end
```

`Config#custom_result?` is true only when both fields are set; the gem falls back to its built-in Result otherwise.

### Idempotency contract

Entries declaring `idempotency_key:` MUST have a matching unique index on the table. The gem validates this at boot; missing indexes raise `MissingIdempotencyIndex`. At runtime, `RecordNotUnique` from a duplicate insert is caught and the existing row is returned with `idempotent? == true`. The projection is **not** re-applied for idempotent returns — the original write already projected.

Entries that genuinely cannot be retried safely (telemetry events with no natural key) declare `idempotency_key: nil` explicitly. Boot-time validation and `RecordNotUnique` rescue land in the next PR.

## Relationship to standard_audit

Different gems, different concerns:

- **`standard_audit`** — "user X took action Y on target Z," free-form metadata, no projection.
- **`standard_ledger`** — "this delta updates these targets," typed kind, mandatory projection.

A single host operation typically writes one of each, in one transaction. Neither subsumes the other.

## Test Strategy

Specs are colocated by topic (`spec/standard_ledger/<topic>_spec.rb`). End-to-end coverage of the inline runtime lives in `spec/standard_ledger/inline_integration_spec.rb`, which exercises `StandardLedger.post` against the `spec/dummy/` SQLite harness — multi-target fan-out, transactional rollback, idempotent retry, all three notifications, `lock: :pessimistic`, multi-counter coalescing, and Result interop. End-to-end coverage of the `:sql` mode lives in `spec/standard_ledger/sql_integration_spec.rb`, which exercises registration validation (missing `recompute`, `via:`/`lock:`/`permissive:` rejection, `:target_id` placeholder enforcement), after-create execution, transactional rollback when a sibling callback raises, the `if:`-guard skip, the nil-FK skip, the `applied`/`failed` notifications, idempotent install, and `rebuild!` for both single-target and walk-the-log scoping. End-to-end coverage of the matview runtime lives in `spec/standard_ledger/matview_integration_spec.rb`, which mocks `connection.execute` (SQLite has no `REFRESH MATERIALIZED VIEW`) to capture the SQL the gem would issue in Postgres and asserts the DSL surface, the `refresh!` API + identifier validation, the `MatviewRefreshJob` delegation contract, and `rebuild!` for matview projections. End-to-end coverage of the `:trigger` mode lives in `spec/standard_ledger/trigger_integration_spec.rb`, which exercises registration validation (missing `trigger_name`, missing block, `via:`/`lock:`/`permissive:` rejection, `:target_id` placeholder, double `rebuild_sql`), the no-callback contract (creating an entry does NOT mutate the target via Ruby — that's the trigger's job in production), and `rebuild!` for both single-target and walk-the-log scoping. The `standard_ledger:doctor` rake task is exercised in `spec/standard_ledger/tasks/doctor_spec.rb`, which mocks `connection.exec_query` against `pg_trigger` to assert success / missing-trigger / no-`:trigger`-projections behaviours without booting a real Postgres database. End-to-end coverage of the rebuild path lives in `spec/standard_ledger/rebuild_integration_spec.rb`, which replays a 50-entry log via a class-form projector to restore truncated counters, asserts the `target:` / `target_class:` / no-arg scoping rules, and verifies the `<prefix>.projection.rebuilt` notification, `NotRebuildable` for block-form projections, and `Error` for unsupported modes. The base of unit specs (`Config`, `Result`, `Entry`, `Projector`) covers the lower-level surfaces in isolation.

### Host-app helpers (`require "standard_ledger/rspec"`)

Host apps opt into the gem's RSpec support by adding `require "standard_ledger/rspec"` to their `spec/rails_helper.rb`. Loading that file:

- Registers a `before(:each)` hook that calls `StandardLedger.reset!`, which clears `StandardLedger.config` and the thread-local `with_modes` override map between examples.
- Defines the `post_ledger_entry(EntryClass).with(kind:, targets:, attrs:)` block matcher — subscribes to `<namespace>.entry.created`, captures every event fired during the block, and asserts (or refutes, when negated) that a matching event was emitted.
- Auto-includes `StandardLedger::RSpec::Helpers` into every example group, exposing `with_modes(...)` as sugar over `StandardLedger.with_modes`.

`StandardLedger.with_modes(EntryClass => :inline) { ... }` writes its overrides into a thread-local hash; mode strategies will consult `StandardLedger.mode_override_for(entry_class)` once `Modes::Async` ships. Today (only `:inline` exists) it's effectively a no-op for already-inline projections — the API lands now so async-mode specs can opt into the inline path the moment the strategy ships.

Future spec coverage (lands with the corresponding PRs):

- `:async` mode transactional semantics (jobs enqueue at `after_create_commit`, with `with_lock` inside the job)

## Conventions

- **Style:** rubocop-rails-omakase. Run `bin/rubocop -A` before pushing.
- **Worktree-only:** see `CLAUDE.md`. The pre-tool-use hook blocks edits in the main checkout.
- **Signed commits:** lefthook's `verify-signatures.sh` rejects unsigned commits at push time. Configure SSH or GPG signing in your local git config.
- **PR cadence:** keep PRs small and aligned with the rollout in design doc §10. Each adopter (nutripod vouchers, nutripod inventory, etc.) should be one PR plus its preceding gem-side PR for any new mode/feature it requires.
- **No emojis** in code or commit messages unless explicitly requested.
- **Comments:** prefer self-documenting code. Add comments only when the *why* is non-obvious (a constraint, a workaround, a subtle invariant). Don't comment what the code does.

## Useful References

- `standard_ledger-design.md` — full design discussion, per-app rollout, open questions.
- `CHANGELOG.md` — what's shipped and what's pending.
- `standard_circuit/AGENTS.md` and `standard_audit/AGENTS.md` — conventions for the sibling gems in the rarebit-one workspace.
