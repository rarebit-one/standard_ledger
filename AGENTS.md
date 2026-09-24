# AGENTS.md - AI Agent Guide for StandardLedger

StandardLedger is a Ruby gem that makes host ActiveRecord models immutable, append-only, idempotent journal entries, with a `StandardLedger.post` helper, a `Projection` base class for host-side projectors, and `StandardLedger.refresh!` for host-owned PostgreSQL materialized views. Read [`standard_ledger-design.md`](./standard_ledger-design.md) before making non-trivial changes.

> **Status: v0.6.0.** 0.6.0 removed the declarative projection engine (`projects_onto`, the six modes, `rebuild!`, `with_modes`, the jobs, the `doctor` task, the Rails engine) because no consumer used it. Design doc §8 has the history. Don't reintroduce any of it without a consumer that needs it.

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
├── lib/standard_ledger.rb          # configure / config / reset! / post / refresh!
├── lib/standard_ledger/
│   ├── version.rb
│   ├── errors.rb         # Error, NotRebuildable, MissingIdempotencyIndex, RefreshInsideTransaction
│   ├── event_emitter.rb  # Routes events to Rails.event.notify (Rails 8.1+) or ActiveSupport::Notifications
│   ├── result.rb         # StandardLedger::Result (default return type)
│   ├── config.rb         # matview_refresh_strategy, result_class/result_adapter, notification_namespace
│   ├── entry.rb          # `include StandardLedger::Entry`: immutability + idempotency-by-unique-index
│   ├── projection.rb     # Base class for host projectors (apply / rebuild); the gem never calls it
│   ├── matview.rb        # REFRESH SQL, identifier validation, transaction guard, `concurrently: :auto` catalog probe (@api private)
│   ├── rspec.rb          # opt-in `require "standard_ledger/rspec"`
│   └── rspec/matchers.rb # `post_ledger_entry` block matcher
├── lib/generators/standard_ledger/install/   # `rails g standard_ledger:install` + initializer template
└── spec/                 # RSpec, SQLite in-memory harness under spec/dummy/
```

There is no Rails engine or railtie. Rails finds the generator on the load path.

## Key Patterns

### Entry

```ruby
class VoucherRecord < ApplicationRecord
  include StandardLedger::Entry

  ledger_entry kind:            :action,
               idempotency_key: :serial_no,
               scope:           :organisation_id
end
```

The invariants live in `.claude/rules/ledger-entry-contract.md`: persisted rows are read-only, `destroy` is blocked unless `allow_destroy: true`, and a collision on the idempotency index returns the existing row with `idempotent? == true`. The index is validated on the first `create!`, and a missing one raises `MissingIdempotencyIndex`.

### `StandardLedger.post`

This is sugar over `create!`. `targets:` are assigned through `belongs_to` (an unknown key raises `ArgumentError`) and `attrs:` are merged. It returns a Result (`idempotent?` on an idempotent return, `failure?` with errors on `RecordInvalid`). `projections` is always `{}`. The key survives only for adapter-signature compatibility.

### `StandardLedger.refresh!(view, concurrently: nil | true | false | :auto)`

`nil` reads `Config#matview_refresh_strategy` (`:concurrent`/`:blocking`/`:auto`). `true` raises `RefreshInsideTransaction` inside a transaction. `:auto` uses `CONCURRENTLY` only when no transaction is open, `pg_class.relispopulated` is true, and a valid unique index exists with no predicate or expressions. Otherwise it runs a plain refresh. A failing probe is reported via `Rails.error` (handled) and degrades to a plain refresh. It emits `projection.refreshed` / `projection.failed`. SQL errors are reported via `Rails.error` (`handled: false`, since 0.7) and re-raised; input errors are not reported.

### Result class + host interop

```ruby
StandardLedger.configure do |c|
  c.result_class   = ApplicationOperation::Result
  c.result_adapter = ->(success:, value:, errors:, entry:, idempotent:, projections:) {
    ApplicationOperation::Result.new(success:, value: value || entry, errors:)
  }
end
```

`Config#custom_result?` is true only when both fields are set. Keep all six adapter keywords stable, because consumer lambdas declare them explicitly.

## Relationship to standard_audit

- **`standard_audit`**: "user X took action Y on target Z", with free-form metadata.
- **`standard_ledger`**: typed, immutable, idempotent journal rows.

A single host operation often writes one of each. Neither subsumes the other.

## Test Strategy

Specs are colocated by topic (`spec/standard_ledger/<topic>_spec.rb`) and run against an in-memory SQLite database (`spec/dummy/`). `entry_spec.rb` covers immutability and idempotency. `post_spec.rb` covers `post`, including idempotent retry, failure Results, `entry.created` and adapter interop. `refresh_spec.rb` covers `refresh!`: it stubs `connection.execute` / `connection.select_one` because SQLite has no matviews, and exercises identifier validation, the transaction guard, events, and every `:auto` branch. The `:auto` catalog SQL was also verified against real PostgreSQL 17 during 0.6.0 development.

`require "standard_ledger/rspec"` (for host apps) defines only the `post_ledger_entry` matcher. It registers no hooks and never touches `Config`.

## Conventions

- **Style:** rubocop-rails-omakase. Run `bin/rubocop -A` before pushing.
- **Worktree-only:** see `CLAUDE.md`. The pre-tool-use hook blocks edits in the main checkout.
- **Signed commits:** lefthook's `verify-signatures.sh` rejects unsigned commits at push time. Configure SSH or GPG signing in your local git config.
- **PR cadence:** keep PRs small. Before adding API surface, confirm a consumer (see `CLAUDE.md`) will call it.
- **No emojis** in code or commit messages unless explicitly requested.
- **Comments:** prefer self-documenting code. Add comments only when the *why* is non-obvious (a constraint, a workaround, a subtle invariant). Don't comment what the code does.

## Useful References

- `standard_ledger-design.md`: current design, consumer usage, and the history of the removed projection engine.
- `CHANGELOG.md`: what has shipped.
- `standard_circuit/AGENTS.md` and `standard_audit/AGENTS.md` — conventions for the sibling gems in the rarebit-one workspace.
