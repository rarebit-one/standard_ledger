# Changelog

All notable changes to this project will be documented in this file. The format
is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
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
- `StandardLedger.post(EntryClass, ...)` module API.
- `StandardLedger.rebuild!(EntryClass, target:)` log-replay path.
- `StandardLedger.refresh!(:view_name)` ad-hoc matview refresh.
- Mode implementations: `:async` (`ProjectionJob` + `with_lock`), `:sql`
  (recompute via `update_all`), `:trigger` (host-owned, gem records rebuild
  SQL), `:matview` (`MatviewRefreshJob` + ad-hoc refresh).
- `standard_ledger:doctor` rake task (verifies trigger presence, etc.).
- Install generator (`rails g standard_ledger:install`).
- ActiveSupport::Notifications instrumentation (`entry.created`,
  `projection.applied`, `projection.failed`).
- RSpec helpers: `post_ledger_entry` matcher, `with_modes` block, opt-in
  `require "standard_ledger/rspec"` auto-cleanup.

[Unreleased]: https://github.com/rarebit-one/standard_ledger/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/rarebit-one/standard_ledger/releases/tag/v0.1.0
