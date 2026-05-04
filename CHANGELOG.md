# Changelog

All notable changes to this project will be documented in this file. The format
is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Install generator: `rails g standard_ledger:install` writes
  `config/initializers/standard_ledger.rb` with commented-out examples
  covering every public `Config` setting (async retries, scheduler,
  matview strategy, notification namespace, host Result interop). The
  generator is idempotent — re-running on an existing initializer skips
  with a clear message; pass `--force` to overwrite.
- RSpec helpers behind an opt-in `require "standard_ledger/rspec"` (typically
  loaded from the host's `spec/rails_helper.rb`):
  - `post_ledger_entry(EntryClass).with(kind:, targets:, attrs:)` block
    matcher — subscribes to `<namespace>.entry.created` for the duration of
    the block and asserts that a matching event fired (or, in the negated
    form, that none did). Honors a custom `notification_namespace`.
  - `StandardLedger.with_modes(EntryClass => :inline) { ... }` block —
    captures a thread-local override map so future async-mode projections
    can be forced inline inside the block. Restored on block exit
    (including on exception); nested blocks compose;
    `StandardLedger.reset_mode_overrides!` clears the map (the auto-cleanup
    hook calls this so host-configured Config survives between examples).
    `StandardLedger.mode_override_for(entry_class)` reads the active
    override for use by mode strategies as they ship. The `with_modes`
    sugar is auto-included into RSpec example groups via
    `StandardLedger::RSpec::Helpers`.
  - Auto-cleanup hook (`RSpec.configure { before(:each) { StandardLedger.reset_mode_overrides! } }`)
    so per-spec override state doesn't leak between examples without
    clobbering the host's initializer-level Config.
- `StandardLedger::Entry` runtime: read-only enforcement after persistence
  (`save`/`update`/`destroy` raise `ActiveRecord::ReadOnlyRecord` when
  `immutable: true`, the default). `immutable: false` opts out.
- `StandardLedger::Entry` idempotency rescue: `create!` traps
  `ActiveRecord::RecordNotUnique` against the configured
  `[*scope, idempotency_key]` unique index, looks up the existing row,
  and returns it with `idempotent? == true`. `idempotency_key: nil` skips
  the rescue and behaves as a regular `create!`.
- Lazy boot-time index validation: the first idempotent `create!` call on
  an Entry verifies a unique index covers exactly `[*scope,
  idempotency_key]` (set equality, order-insensitive); raises
  `MissingIdempotencyIndex` with a clear message if missing or if the
  index covers extra columns. Cached per-class.
- `spec/dummy/` minimal Rails-free AR harness backed by SQLite
  `:memory:`, loaded from `spec/spec_helper.rb` so AR-backed integration
  tests can run without a host app.
- `Projector#apply_projection!(definition)` — runtime evaluator that resolves
  the target association, evaluates the optional `if:` guard against the
  entry, looks up the per-kind handler (with `:_` wildcard fallback when
  `permissive: true`), and invokes the handler or `via:` projector class.
  Wraps the call in `target.with_lock { ... }` when `lock: :pessimistic`.
  Skips silently when the target is `nil`; raises
  `StandardLedger::UnhandledKind` when no handler matches and the projection
  is non-permissive; raises `StandardLedger::Error` when the entry's kind
  column is `nil`.
- `Projector.standard_ledger_projections_for(mode)` — class-side filter that
  returns the registered definitions whose `mode` matches the argument, for
  the per-mode strategy classes (`Modes::Inline`, future `Modes::Async`,
  ...) to discover which projections they own.
- `projects_onto` registration validation: now raises `ArgumentError` when a
  block and `via:` are both given (mutually exclusive), when the block is
  empty (no `on(:kind)` calls), or when neither a block nor `via:` is
  supplied.
- `StandardLedger::Modes::Inline` runtime: applies inline-mode projections
  inside `after_create`, transactional with the entry insert. A single
  `after_create` callback is installed once per entry class on first
  `:inline` registration (`Modes::Inline.install!`), and dispatches to
  every `:inline` definition via `entry.apply_projection!`. Multiple
  projections targeting the same association coalesce into a single
  UPDATE per (entry, target): handlers run in declared order, then
  `target.save!` persists the accumulated in-memory mutations once.
  When any projection in a per-target group declares `lock: :pessimistic`,
  the entire apply-then-save cycle is wrapped in `target.with_lock`, so
  the row lock spans both handler invocation and the coalesced save —
  closing the lost-update window that an inner-only lock would leave open
  between lock release and save. Lock interpretation is the mode's
  responsibility; `Projector#apply_projection!` no longer wraps in
  `with_lock` itself. `:inline` mode now refuses to install on a non-AR
  entry class — `Modes::Inline.install!` raises `ArgumentError` instead
  of silently no-op-ing.
- `StandardLedger.post(EntryClass, kind:, targets:, attrs:)` module API —
  sugar over `EntryClass.create!` that maps `targets:` onto the entry's
  `belongs_to` setters via `reflect_on_association`. Returns a
  `StandardLedger::Result` (or the host's Result type when
  `Config#custom_result?` is true). Wraps `ActiveRecord::RecordInvalid`
  into `Result.failure(errors:)`; lets every other exception propagate so
  the entry's transaction rolls back. `targets:` accepts model instances
  only; pass foreign keys via `attrs:` (e.g. `voucher_scheme_id: 42`)
  when an instance isn't on hand. `result.projections[:inline]` reflects
  the projections that *actually* ran for this entry — projections
  short-circuited by an `if:` guard, a nil target, or a permissive
  no-handler miss are excluded, and an idempotent retry returns
  `[]` (no projections fire on the rescue path).
- ActiveSupport::Notifications instrumentation under the configured
  `notification_namespace` prefix (default `"standard_ledger"`):
  - `<prefix>.entry.created` — `after_commit on: :create`. Payload
    `{ entry:, kind:, targets: { name => target } }`. Targets are
    discovered from the entry's non-polymorphic `belongs_to` reflections.
  - `<prefix>.projection.applied` — fired per inline projection on
    success. Payload `{ entry:, target:, projection:, mode: :inline,
    duration_ms: }`.
  - `<prefix>.projection.failed` — fired per inline projection on raise,
    before re-raising so the entry's transaction rolls back. Payload
    `{ entry:, target:, projection:, error: }`.
- Host Result interop in `StandardLedger.post`: when both
  `config.result_class` and `config.result_adapter` are set, the adapter
  is invoked with `success:, value:, errors:, entry:, idempotent:,
  projections:` and its return value is returned as-is. Falls back to
  `StandardLedger::Result` otherwise.
- Integration spec (`spec/standard_ledger/inline_integration_spec.rb`)
  exercising the end-to-end flow against the `spec/dummy/` SQLite
  harness: multi-target fan-out, transactional rollback on projector
  raise, idempotent-retry projection skip, all three notifications,
  `lock: :pessimistic`, multi-counter coalescing, and Result interop.

## [0.1.0] — 2026-05-04

Initial scaffold. Establishes the gem layout, public API surface stubs, and the
build/test pipeline. **Not yet usable in production** — see the design doc
(`standard_ledger-design.md` in the workspace root) for the full v0.1 → v0.2
roadmap.

### Added
- Rails Engine with `isolate_namespace StandardLedger`, no routes, no tables.
- `StandardLedger.configure { |c| ... }` block with `Config` settings:
  `default_async_job`, `default_async_retries`, `scheduler`,
  `matview_refresh_strategy`, `result_class`, `result_adapter`,
  `notification_namespace`.
- `StandardLedger::Result` with `success?` / `failure?` / `idempotent?` /
  `entry` / `value` / `errors` / `projections`. `Config#custom_result?`
  governs whether the gem returns its own type or delegates to the host's via
  `result_adapter`.
- `StandardLedger::Entry` concern: `ledger_entry kind:, idempotency_key:,
  scope:, immutable:` class macro stores configuration on the host model.
  Read-only enforcement and idempotency rescue land in the next PR.
- `StandardLedger::Projector` concern: `projects_onto target, mode:, via:,
  if:, lock:, permissive:` class macro with block-DSL `on(:kind) { ... }`
  registration. Stores `Definition` structs on the host model.
- `StandardLedger::Projection` base class for class-form projectors with
  `apply` and `rebuild` interface.
- `StandardLedger::Modes::Inline` strategy class skeleton; `#call` raises
  `NotImplementedError` until the nutripod vouchers integration lands.
- Error hierarchy: `Error`, `UnhandledKind`, `NotRebuildable`,
  `MissingIdempotencyIndex`, `PartialFailure`.
- RSpec suite with passing specs for version, configure, reset, Config
  defaults, and Result success/failure helpers.
- GitHub Actions CI on Ruby 3.4.4 running RSpec + RuboCop.

### Pending (tracked in design doc, lands in subsequent PRs)
- `StandardLedger.rebuild!(EntryClass, target:)` log-replay path.
- `StandardLedger.refresh!(:view_name)` ad-hoc matview refresh.
- Remaining mode implementations: `:async` (`ProjectionJob` + `with_lock`),
  `:sql` (recompute via `update_all`), `:trigger` (host-owned, gem
  records rebuild SQL), `:matview` (`MatviewRefreshJob` + ad-hoc refresh).
- `standard_ledger:doctor` rake task (verifies trigger presence, etc.).

[Unreleased]: https://github.com/rarebit-one/standard_ledger/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/rarebit-one/standard_ledger/releases/tag/v0.1.0
