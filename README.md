# standard_ledger

Immutable, append-only journal entries for Rails apps, with a `post` helper
and a materialized-view refresh wrapper.

> **Status: v0.6.0.** 0.6.0 removed the declarative projection engine
> (`projects_onto`, the `:inline`/`:async`/`:sql`/`:trigger`/`:matview`/`:manual`
> modes, `rebuild!`, `with_modes`, the jobs and the `standard_ledger:doctor`
> task) because no consuming app used it. See the
> [CHANGELOG](CHANGELOG.md#060---2026-09-24) for the upgrade note and
> [`standard_ledger-design.md`](standard_ledger-design.md) for the design.

## What it is

Our apps keep building the same thing: an immutable journal table (voucher
issuance, commission entries, runner usage, device events, prompt
transactions) whose rows are permanent facts. `standard_ledger` gives those
tables one shared contract on top of the host's existing ActiveRecord models.
The gem **does not own the schema**: hosts keep their tables and the gem
adapts to them.

What you get:

| Piece | What it does |
|---|---|
| `StandardLedger::Entry` | Makes persisted rows read-only, blocks `destroy` (opt out with `allow_destroy:`), and gives `create!` idempotency-by-unique-index. |
| `StandardLedger.post` | Sugar over `create!` that maps `targets:` onto `belongs_to` associations and returns a Result (the gem's, or your app's own). |
| `StandardLedger::Projection` | An optional base class for host-side projector objects you call yourself (`apply` / `rebuild`). |
| `StandardLedger.refresh!` | `REFRESH MATERIALIZED VIEW [CONCURRENTLY]` for host-owned views, with `concurrently: :auto`. |
| `post_ledger_entry` | An RSpec block matcher. |

The gem does **not** keep aggregates up to date for you. Updating derived
state is the host's job: a projector it calls from its own operation, a
counter update in the same transaction, or a materialized view refreshed on a
schedule.

## Entries

```ruby
class VoucherRecord < ApplicationRecord
  include StandardLedger::Entry

  belongs_to :voucher_scheme
  belongs_to :customer_profile

  ledger_entry kind:            :action,           # column holding the kind
               idempotency_key: :serial_no,        # nil = not idempotent
               scope:           :organisation_id   # unique index is [organisation_id, serial_no]
end
```

- After a row is persisted, `save`/`update` raise `ActiveRecord::ReadOnlyRecord`.
  New, unsaved instances stay writable.
- `destroy` raises unless `ledger_entry ..., allow_destroy: true`. That option
  exists so an owner's `dependent: :destroy` cascade can clean up; it doesn't
  make entries editable.
- With `idempotency_key:`, a `create!` that trips the matching unique index
  returns the existing row with `idempotent? == true` instead of raising. The
  index must exist; the gem raises `StandardLedger::MissingIdempotencyIndex` on
  first use if it doesn't.
- `<prefix>.entry.created` fires after commit (see [Events](#events)).

## Posting

```ruby
result = StandardLedger.post(VoucherRecord,
                             kind:    :grant,
                             targets: { voucher_scheme: scheme, customer_profile: profile },
                             attrs:   { serial_no: "v-123", organisation_id: org.id })

result.success?     # false when the entry failed validation (errors in result.errors)
result.idempotent?  # true when the idempotency key matched an existing row
result.entry        # the persisted (or existing) entry
```

Pass foreign keys through `attrs:` (`voucher_scheme_id: 42`) when you don't
have a loaded record. A `targets:` key that isn't an association raises
`ArgumentError`.

## Projectors

Subclass `StandardLedger::Projection` for a projector your code calls itself:

```ruby
class Validations::ProfileProjector < StandardLedger::Projection
  def apply(profile, validation)
    profile.increment!(:successful_loans_count) if validation.successful?
  end

  def rebuild(profile)
    profile.update!(successful_loans_count: profile.validations.successful.count)
  end
end

Validations::ProfileProjector.new.apply(profile, validation)
```

Unimplemented `apply` raises `NotImplementedError`. Unimplemented `rebuild`
raises `StandardLedger::NotRebuildable`.

## Materialized views

The host creates and owns the view (e.g. with a `scenic` migration) and
schedules refreshes itself (SolidQueue recurring task, cron, …). The gem
issues the SQL and emits events. PostgreSQL only.

```ruby
StandardLedger.refresh!(:device_fleet_stats)                        # Config#matview_refresh_strategy
StandardLedger.refresh!(:device_fleet_stats, concurrently: :auto)   # concurrent when it can be
StandardLedger.refresh!(:device_fleet_stats, concurrently: true)    # always CONCURRENTLY
StandardLedger.refresh!(:device_fleet_stats, concurrently: false)   # always plain (blocking)
```

`REFRESH MATERIALIZED VIEW CONCURRENTLY` has three preconditions. Postgres
rejects it:

- inside a transaction block (the gem raises `StandardLedger::RefreshInsideTransaction` before sending SQL),
- on a view that has never been populated (e.g. created `WITH NO DATA`, or empty right after deploy),
- on a view without a unique index that uses only column names and has no `WHERE` clause.

`concurrently: :auto` checks all three first: it looks for an open
transaction, then reads `pg_class.relispopulated` and `pg_index` for the
view. It refreshes `CONCURRENTLY` only when all three are met and falls back
to a plain refresh otherwise. If the catalog lookup itself fails, the error is
reported to `Rails.error` (`handled: true`, `source: "standard_ledger"`) and a
plain refresh runs. A job that previously caught
`PG::ObjectNotInPrerequisiteState` and `RefreshInsideTransaction` to retry
with `concurrently: false` can pass `concurrently: :auto` instead.

`refresh!` returns a success Result with
`projections[:refreshed] = [{ view:, concurrently: }]` (the concurrency mode
that was actually used). If the SQL fails, it emits `projection.failed`,
reports the error to `Rails.error` (`handled: false`, `severity: :error`,
`context: { view:, concurrently: }`, `source: "standard_ledger"`), and
re-raises so your job runner can retry. Since 0.7 you don't need a
report-and-re-raise rescue around `refresh!` in your job. An existing one is
harmless: Rails skips an exception object it has already reported, so the
failure is reported once. Input errors (an invalid view name, an unknown
`concurrently:`, `RefreshInsideTransaction`) are raised before any SQL runs
and are not reported by the gem. View names must be bare or `schema.view`
identifiers. Anything else raises `ArgumentError`.

## Installation

```ruby
gem "standard_ledger", "~> 0.7"
```

(Don't reintroduce a `git:` reference. It makes a bare `bundle install` a
prerequisite for every other command in a fresh checkout.)

```bash
bin/rails g standard_ledger:install
```

This writes `config/initializers/standard_ledger.rb` with every setting
commented out. A typical configuration:

```ruby
Rails.application.config.to_prepare do
  StandardLedger.configure do |c|
    c.matview_refresh_strategy = :auto   # :concurrent (default) | :blocking | :auto

    # Optional — return the host's Result type from post / refresh!:
    c.result_class   = ApplicationOperation::Result
    c.result_adapter = ->(success:, value:, errors:, entry:, idempotent:, projections:) {
      ApplicationOperation::Result.new(success:, value: { entry: value || entry, idempotent:, projections: }, errors:)
    }
  end
end
```

The adapter always receives all six keywords. `projections:` is `{}` for
`post` and `{ refreshed: [...] }` for `refresh!`.

## Events

On Rails 8.1+ events go through `Rails.event.notify(name, **payload)`. On
older Rails they fall back to
`ActiveSupport::Notifications.instrument(name, payload)`. Names are prefixed
with `Config#notification_namespace` (default `standard_ledger`).

| Event | Fired when | Payload |
|---|---|---|
| `<prefix>.entry.created` | after the entry's transaction commits (not on idempotent returns) | `entry:`, `kind:`, `targets:` (`{ name => record }` for non-nil `belongs_to`) |
| `<prefix>.projection.refreshed` | a matview refresh succeeded | `view:`, `concurrently:`, `duration_ms:` |
| `<prefix>.projection.failed` | the `REFRESH` SQL raised | `view:`, `concurrently:`, `mode: :matview`, `error:` |

`projection.failed` doesn't fire for input errors (an invalid view name, or
`RefreshInsideTransaction`) because no SQL was sent. The event names keep
their pre-0.6 `projection.*` spelling so existing subscribers keep working.

**Subscriber exceptions are swallowed** (warned to stderr, not re-raised).
Ledger observability must never take down a request.

## Testing

```ruby
# spec/rails_helper.rb
require "standard_ledger/rspec"
```

This defines the `post_ledger_entry` block matcher. It listens on the channel
the gem emits through, so it works on Rails 8.1+ as well:

```ruby
expect {
  Vouchers::IssueOperation.call(scheme: scheme, profile: profile)
}.to post_ledger_entry(VoucherRecord).with(
  kind:    :grant,
  targets: { voucher_scheme: scheme },
  attrs:   { serial_no: "v-2025-1" }
)
```

It registers no hooks and never resets your `Config`.

## Development

```bash
bundle install
bundle exec rspec
bundle exec rubocop
```

## Relationship to standard_audit

- **`standard_audit`**: "user X took action Y on target Z", with free-form
  metadata.
- **`standard_ledger`**: typed, immutable, idempotent journal rows that other
  state is derived from.

A single host operation often writes one of each. Subscribe to
`entry.created` if you want an audit row per entry. The gem never calls into
audit itself.

## License

MIT. See [LICENSE](LICENSE).
