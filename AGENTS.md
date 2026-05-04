# AGENTS.md - AI Agent Guide for StandardLedger

StandardLedger is a Ruby gem that captures the recurring "immutable journal entry → N aggregate projections" pattern as a declarative DSL on host ActiveRecord models. The design is documented in [`standard_ledger-design.md`](./standard_ledger-design.md); read it before making non-trivial changes.

> **Status: scaffolding (v0.1.0).** The gem layout, public API surfaces, and build pipeline are in place; the runtime behavior (mode implementations, idempotency rescue, rebuild path, instrumentation) is enumerated in `CHANGELOG.md` under "Pending" and lands in subsequent PRs.

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
│   ├── result.rb         # StandardLedger::Result (default return type)
│   ├── config.rb         # StandardLedger.configure { |c| ... }
│   ├── engine.rb         # Rails engine boot hook
│   ├── entry.rb          # `include StandardLedger::Entry` concern
│   ├── projector.rb      # `include StandardLedger::Projector` concern + `projects_onto` DSL
│   ├── projection.rb     # Base class for class-form projectors
│   └── modes/
│       └── inline.rb     # `:inline` mode runtime — installs `after_create`, applies projections, coalesces multi-counter writes
├── lib/generators/standard_ledger/install/
│   ├── install_generator.rb       # `rails g standard_ledger:install`
│   └── templates/initializer.rb.tt # Generated initializer with commented-out Config DSL
└── spec/                 # RSpec tests
```

`StandardLedger.rebuild!(EntryClass, target:, target_class:, batch_size:)` (in `lib/standard_ledger.rb`) drives the log-replay path: it dispatches to the registered projector class's `rebuild(target)` for each in-scope (target, projection) pair, fires `<prefix>.projection.rebuilt` per success, and refuses block-form (delta) projections plus modes other than `:inline` until their respective PRs land.

The remaining modes (`async`, `sql`, `trigger`, `matview`) and the `.refresh!` API land in subsequent PRs — see `CHANGELOG.md` "Pending" for the complete list. `StandardLedger.post(EntryClass, kind:, targets:, attrs:)` ships in the same PR as the inline runtime.

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

Specs are colocated by topic (`spec/standard_ledger/<topic>_spec.rb`). End-to-end coverage of the inline runtime lives in `spec/standard_ledger/inline_integration_spec.rb`, which exercises `StandardLedger.post` against the `spec/dummy/` SQLite harness — multi-target fan-out, transactional rollback, idempotent retry, all three notifications, `lock: :pessimistic`, multi-counter coalescing, and Result interop. End-to-end coverage of the rebuild path lives in `spec/standard_ledger/rebuild_integration_spec.rb`, which replays a 50-entry log via a class-form projector to restore truncated counters, asserts the `target:` / `target_class:` / no-arg scoping rules, and verifies the `<prefix>.projection.rebuilt` notification, `NotRebuildable` for block-form projections, and `Error` for unsupported modes. The base of unit specs (`Config`, `Result`, `Entry`, `Projector`) covers the lower-level surfaces in isolation.

### Host-app helpers (`require "standard_ledger/rspec"`)

Host apps opt into the gem's RSpec support by adding `require "standard_ledger/rspec"` to their `spec/rails_helper.rb`. Loading that file:

- Registers a `before(:each)` hook that calls `StandardLedger.reset!`, which clears `StandardLedger.config` and the thread-local `with_modes` override map between examples.
- Defines the `post_ledger_entry(EntryClass).with(kind:, targets:, attrs:)` block matcher — subscribes to `<namespace>.entry.created`, captures every event fired during the block, and asserts (or refutes, when negated) that a matching event was emitted.
- Auto-includes `StandardLedger::RSpec::Helpers` into every example group, exposing `with_modes(...)` as sugar over `StandardLedger.with_modes`.

`StandardLedger.with_modes(EntryClass => :inline) { ... }` writes its overrides into a thread-local hash; mode strategies will consult `StandardLedger.mode_override_for(entry_class)` once `Modes::Async` ships. Today (only `:inline` exists) it's effectively a no-op for already-inline projections — the API lands now so async-mode specs can opt into the inline path the moment the strategy ships.

Future spec coverage (lands with the corresponding PRs):

- `:async` mode transactional semantics (jobs enqueue at `after_create_commit`, with `with_lock` inside the job)
- `:sql`/`:trigger`/`:matview` modes
- `:trigger` mode `doctor` rake task; `:matview` mode `CONCURRENTLY` refresh

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
