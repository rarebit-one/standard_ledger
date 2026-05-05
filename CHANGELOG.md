# Changelog

All notable changes to this project will be documented in this file. The format
is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- `:async` projection mode + `StandardLedger::ProjectionJob`. Used when
  the projection is too expensive or stateful for the entry's transaction
  (jsonb rebuild, multi-row aggregate) — the canonical example is
  nutripod's `Order#payable_balance` / `Order#fulfillable_balance` jsonb
  columns. The strategy installs an `after_create_commit` callback that
  enqueues `StandardLedger::ProjectionJob` per (entry, projection) pair;
  the job resolves the target via the entry's `belongs_to`, wraps
  `target.with_lock { projector.apply(target, entry) }`, and fires the
  same `<prefix>.projection.applied` / `<prefix>.projection.failed`
  events as `:inline` (with an additional `attempt:` key drawn from
  ActiveJob's `executions` accessor).
  - Class-form only: `:async` projections must declare `via: ProjectorClass`.
    The projector's `apply(target, entry)` should recompute from the log
    inside `with_lock` rather than apply a delta — async retries can run
    the projector more than once, so block-form per-kind handlers
    (incrementing counters) are silently corrupting under retry. The
    registration path rejects block forms with a clear ArgumentError;
    `lock:` and `permissive: true` are also rejected (`with_lock` is
    unconditional and there are no per-kind handlers).
  - Retries: `Config#default_async_retries` (default 3 total attempts —
    one initial run + two retries, matching ActiveJob's `retry_on
    attempts:` semantics) caps the attempt count. The job uses a
    hand-rolled `rescue_from(StandardError)` that reads the cap at
    perform time so reconfiguration in tests / hosts takes effect
    immediately, with `discard_on StandardLedger::Error` so programmer
    errors (missing definition, renamed association) skip the retry
    budget entirely. Each failure emits its own
    `<prefix>.projection.failed` event with the current `attempt` so
    subscribers see the full retry history.
  - `Config#default_async_job` — hosts can swap the default
    `StandardLedger::ProjectionJob` for their own subclass (per-mode
    queue routing, custom retry policies). The strategy reads it at
    enqueue time.
  - `with_modes(EntryClass => :inline)` interop: when the override map
    forces an entry class to `:inline`, the strategy short-circuits the
    enqueue and runs `target.with_lock { projector.apply(target, entry) }`
    synchronously inside the block. Useful in unit specs that want
    end-to-end coverage without standing up a job runner. Notifications
    fire with `mode: :async, attempt: 1` so subscribers can't tell the
    difference.
  - `StandardLedger.rebuild!` extends to `:async` projections — same
    per-target rebuild semantics as `:inline` (delegates to
    `definition.projector_class.new.rebuild(target)`). The mode
    difference is only in the after-create path, not the rebuild path.
- `:trigger` projection mode. The host owns the database trigger
  (created in a Rails migration); the gem **does not create or manage
  triggers** — that's deliberate, because giving a Ruby DSL the power
  to install/replace triggers is a deploy footgun (silent re-creation
  on `db:schema:load` against a non-empty DB), and triggers are
  versioned by `db/schema.rb` like any other DDL. The gem only records
  the trigger's name and the equivalent rebuild SQL.
  - `projects_onto :assoc, mode: :trigger, trigger_name: "..." do
    rebuild_sql "..." end` declares a trigger projection. The
    `trigger_name:` keyword is required (a non-empty string); the
    block must call `rebuild_sql "..."` exactly once with a SQL
    string containing the `:target_id` placeholder. Registration
    rejects `via:`, `lock:`, and `permissive:` (none are meaningful
    for `:trigger` mode — the trigger is the contract). `Definition`
    gains a `trigger_name` field, populated only for `:trigger` mode;
    the rebuild SQL is stored in the existing `recompute_sql` slot
    (shared with `:sql` mode — both modes use it the same way).
  - `StandardLedger::Modes::Trigger` strategy — `install!` is a no-op
    marker (trigger projections fire from the database, not Ruby, so
    no `after_create` callback is wired). The strategy class exists
    only to keep `Projector#install_mode_callbacks_for`'s dispatch
    table uniform across modes and to mark the entry class as having
    at least one `:trigger` projection registered.
  - `StandardLedger.rebuild!(EntryClass)` extends to `:trigger`
    projections: the same SQL recompute path as `:sql` mode runs the
    recorded `rebuild_sql` against each target the log references,
    binding `:target_id` to each target's id. `target:` /
    `target_class:` / no-arg scoping works the same way.
    `<prefix>.projection.rebuilt` fires per target with `mode:
    :trigger`. The gem does NOT verify or recreate the trigger
    during `rebuild!` — `standard_ledger:doctor` is the deploy-time
    check.
- `standard_ledger:doctor` rake task. Iterates every registered
  `:trigger` projection across all loaded entry classes (discovered
  by walking `ActiveRecord::Base.descendants` for classes that
  include `StandardLedger::Projector` and have at least one `:trigger`
  projection). For each, queries `pg_trigger` to confirm the named
  trigger exists in the connected schema. Reports missing triggers
  on stderr with a clear remediation message and exits 1; prints a
  success message and exits 0 otherwise. **Postgres-only** — the
  task queries `pg_trigger` directly and will raise on a non-Postgres
  connection. SQLite has no comparable per-statement trigger
  introspection that fits this gem's contract; the only adopter
  today is nutripod-web (Postgres). The task is auto-loaded via
  `Engine.rake_tasks` so `bin/rails -T standard_ledger` shows it
  immediately after the gem is installed.
- Integration spec for `:trigger` mode
  (`spec/standard_ledger/trigger_integration_spec.rb`) covers DSL
  registration validation (missing `trigger_name`, missing block,
  empty block, `via:` / `lock:` / `permissive:` rejection,
  `:target_id` placeholder enforcement, double `rebuild_sql` call),
  the strategy's no-callback contract (creating an entry does NOT
  mutate the target via Ruby — that's the trigger's job in
  production), and `StandardLedger.rebuild!` for both single-target
  and walk-the-log scoping with the `<prefix>.projection.rebuilt`
  event firing with `mode: :trigger`.
- Doctor task spec
  (`spec/standard_ledger/tasks/doctor_spec.rb`) mocks the
  `connection.exec_query` against `pg_trigger` to exercise the
  task's three behaviours (success, failure with exit 1 + stderr
  message, ignoring entry classes without `:trigger` projections)
  without requiring a real Postgres database.
- Integration spec for `:async` mode
  (`spec/standard_ledger/async_integration_spec.rb`) covers DSL
  registration validation, after-commit enqueue, multi-target fan-out,
  nil-FK skip (both at enqueue and at perform), the `with_modes`
  inline override, the `default_async_job` swap, retry-on-failure with
  attempt-counter telemetry, the `discard_on StandardLedger::Error`
  programmer-error path, and the rebuild path.

## [0.2.0] - 2026-05-05

### Added
- `StandardLedger::EventEmitter` — internal dispatcher that routes
  gem events through `Rails.event.notify` on Rails 8.1+ and falls back
  to `ActiveSupport::Notifications.instrument` on older Rails. Subscriber
  exceptions are swallowed (printed via `warn`) so observability cannot
  break the host's request path. All existing event names and payloads
  are preserved — host subscribers via `ActiveSupport::Notifications.subscribe`
  continue to work unchanged. Mirrors the `StandardCircuit::EventEmitter`
  pattern for cross-gem consistency.
- `:matview` projection mode + ad-hoc refresh API. The host owns the
  PostgreSQL materialized view (created in a migration via `scenic` or
  hand-rolled SQL); the gem owns the refresh schedule and the ad-hoc
  refresh primitive.
  - `projects_onto :assoc, mode: :matview, view: "view_name", refresh: { every: 5.minutes, concurrently: true }`
    declares a matview projection. The `view:` keyword is required;
    `refresh:` is optional metadata for the host's scheduler. Block-DSL
    is not accepted (matview projections have no per-kind handlers —
    they refresh on a schedule). `Definition` gains `view` and
    `refresh_options` fields, populated only for `:matview` mode.
  - `StandardLedger::Modes::Matview` strategy — `install!` records the
    matview registration on the entry class without installing any
    `after_create` callback (matview is scheduled, not entry-driven);
    `.refresh!(view_name, concurrently:)` issues `REFRESH MATERIALIZED
    VIEW [CONCURRENTLY] <view_name>` against the active connection,
    instruments `<prefix>.projection.refreshed` on success and
    `<prefix>.projection.failed` on raise (re-raising so the host's
    scheduler / job runner sees the failure). The `view_name` is
    validated against `/\A[a-zA-Z_][a-zA-Z0-9_.]*\z/` to refuse SQL
    injection via crafted identifiers.
  - `StandardLedger.refresh!(view_name, concurrently: nil)` — module-level
    ad-hoc refresh API. `concurrently: nil` (default) consults
    `Config#matview_refresh_strategy`; `true`/`false` overrides per call.
    Returns a `Result` with `projections[:refreshed]` listing the view
    refreshed; re-raises on SQL failure after firing the `failed` event.
    Hosts call this at the end of read-your-write-critical operations
    (e.g. luminality's `PromptPacks::DrawOperation` refreshing
    `user_prompt_inventories` after a draw).
  - `StandardLedger::MatviewRefreshJob` — thin `ActiveJob::Base` wrapper
    around `StandardLedger.refresh!`. Hosts wire their scheduler
    (SolidQueue Recurring Tasks, sidekiq-cron, etc.) at this job class
    with `(view_name, concurrently:)` arguments. The gem deliberately
    does not auto-schedule — schedule cadence and backend selection is a
    host concern.
  - `StandardLedger.rebuild!(EntryClass)` extends to `:matview`
    projections: each registered matview projection triggers a single
    `refresh!` (no per-target loop — the matview holds state for every
    target in one relation). `target:` / `target_class:` scoping is
    silently ignored for matviews (Postgres has no partial-refresh
    primitive). `result.projections[:rebuilt]` includes a
    `{ target_class: nil, target_id: nil, projection:, view: }` entry per
    refreshed view.
- `:sql` mode: single-`UPDATE` recompute projections that bind
  `:target_id` from the entry's foreign key. Block-DSL takes a single
  `recompute "..."` clause instead of per-kind `on(:kind)` handlers; the
  same SQL serves both the after-create path and `StandardLedger.rebuild!`.
  Fires inside `after_create` (in the entry's transaction), so failures
  roll back the entry alongside the projection. Skips silently on nil
  FK or false `if:` guard. Notifications under the configured prefix:
  `<prefix>.projection.applied` (mode: `:sql`, `target: nil`, includes
  `duration_ms`) and `<prefix>.projection.failed` (re-raises after the
  payload is published). Registration validates that `:target_id`
  appears in the SQL, that no `via:`/`lock:`/`permissive:` are supplied
  (none are meaningful for `:sql` mode — the recompute SQL is the whole
  contract), and that the block actually called `recompute` exactly once.
  `StandardLedger.rebuild!` runs the same statement against each target
  the log references; `target:` / `target_class:` / no-arg scoping
  works the same as for `:inline`.
- Integration specs for both new modes
  (`spec/standard_ledger/sql_integration_spec.rb` and
  `spec/standard_ledger/matview_integration_spec.rb`) cover the
  end-to-end flows including registration validation, transactional
  semantics, notifications, idempotent install, and rebuild paths.
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
- `StandardLedger.rebuild!(EntryClass, target:, target_class:,
  batch_size:)` log-replay path. Recomputes projections from the
  entry log by delegating to the registered projector class's
  `rebuild(target)`. Scope is one of: a single `target:` instance,
  every row of `target_class:`, or (with neither) every projection
  on the entry class for every target referenced by the log. Each
  (target, projection) rebuild runs in its own transaction; per
  design doc §5.5, failures mid-loop are NOT unwound across earlier
  successes. Refuses block-form (delta) projections with
  `StandardLedger::NotRebuildable`, and modes other than `:inline`
  with `StandardLedger::Error` until their respective mode PRs land.
  Returns a Result (or host's Result via the adapter) with
  `projections[:rebuilt]` listing each (target_class, target_id,
  projection) that was rebuilt.
- `<prefix>.projection.rebuilt` notification fires for each
  successful target rebuild. Payload `{ entry_class:, target:,
  projection:, mode: }`. Joins the existing `entry.created`,
  `projection.applied`, and `projection.failed` events under the
  configured `notification_namespace`.
- Integration spec
  (`spec/standard_ledger/rebuild_integration_spec.rb`) covers the
  end-to-end rebuild flow: 50-entry log replay restoring counters
  after truncation, `target:` / `target_class:` / no-arg scoping,
  block-form / no-`rebuild` / unsupported-mode raises, the
  `projection.rebuilt` notification, and host Result interop.

## [0.1.0] - 2026-05-04

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
- Remaining mode implementations: `:async` (`ProjectionJob` + `with_lock`)
  and `:trigger` (host-owned, gem records rebuild SQL).
- `standard_ledger:doctor` rake task (verifies trigger presence, etc.).

[Unreleased]: https://github.com/rarebit-one/standard_ledger/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/rarebit-one/standard_ledger/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/rarebit-one/standard_ledger/releases/tag/v0.1.0
