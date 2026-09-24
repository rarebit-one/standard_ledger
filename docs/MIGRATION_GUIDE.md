# Adopting StandardLedger in an Existing App

As of 0.6.0 the gem does four things: it makes a journal table immutable and
idempotent (`Entry`), writes entries with a Result (`post`), gives projector
objects a base class (`Projection`), and refreshes materialized views
(`refresh!`). It doesn't run projections for you. The earlier mode-picking
guide (`:inline`, `:async`, `:sql`, `:trigger`, `:matview`, `:manual`) went
with the engine; see git tag `v0.5.1` if you need it for history.

## 1. Mark the table as a ledger entry

Replace a hand-rolled read-only concern and `RecordNotUnique` rescue:

```ruby
class PayoutEntry < ApplicationRecord
  include StandardLedger::Entry

  ledger_entry kind: :kind, idempotency_key: :idempotency_key, scope: :account_id
end
```

Add the unique index the gem expects: exactly `[*scope, idempotency_key]`, as
a full index or partial `WHERE <key> IS NOT NULL`. Without it the first
`create!` raises `StandardLedger::MissingIdempotencyIndex`. If the table has
no natural key, declare `idempotency_key: nil` explicitly.

## 2. Write entries with `post`

```ruby
result = StandardLedger.post(PayoutEntry,
                             kind:  :payout,
                             attrs: { account_id: account.id, idempotency_key: key, amount_cents: cents })
return result if result.failure?
notify! unless result.idempotent?   # skip side effects on a retry
```

To get your app's own Result type back, configure `result_class` and
`result_adapter` (see the README). The adapter gets all six keywords,
including `idempotent:`. Don't drop that one: it's the only signal that a
retry matched an existing row.

## 3. Keep derived state in host code

Put the update in the same operation, inside the same transaction as the
`post`. When it's more than a line, extract a projector:

```ruby
class Validations::ProfileProjector < StandardLedger::Projection
  def apply(profile, validation) = ...
  def rebuild(profile) = ...   # recompute from the log; omit if not possible
end
```

## 4. Materialized views

Own the view in a migration (e.g. `scenic`). Give it a unique index if you
want concurrent refreshes, and schedule the refresh from your own recurring
job:

```ruby
class RefreshMaterializedViewsJob < ApplicationJob
  VIEWS = %i[device_fleet_stats batch_device_stats].freeze

  def perform
    VIEWS.each { |view| StandardLedger.refresh!(view, concurrently: :auto) }
  end
end
```

`:auto` uses `CONCURRENTLY` only when the view is populated, has a unique
index with no `WHERE` clause or expressions, and no transaction is open.
Otherwise it runs a plain refresh. That covers the first refresh after a
deploy (empty view) and jobs run inline under transactional specs, with no
rescue-and-retry.

For read-your-write after a critical write, refresh **after** the transaction
commits:

```ruby
ActiveRecord::Base.transaction do
  # ... create entries ...
end
StandardLedger.refresh!(:user_stats, concurrently: :auto)
```

`concurrently: true` inside a transaction raises
`StandardLedger::RefreshInsideTransaction`. `concurrently: :auto` inside a
transaction runs a plain refresh, which blocks reads on the view while it
runs.

## Cascade deletes (`dependent: :destroy`)

If an owning record declares `has_many :events, dependent: :destroy` for
sandbox cleanup or GDPR erasure, opt the entry into that path:

```ruby
ledger_entry kind: :event_type, scope: :device_id, allow_destroy: true
```

`save`/`update` on persisted rows still raise `ActiveRecord::ReadOnlyRecord`.
Only `destroy` is permitted.
