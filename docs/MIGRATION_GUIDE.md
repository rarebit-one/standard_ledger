# Adopting StandardLedger in an Existing App

This guide covers the three patterns we hit in the rarebit-one / sidekick-labs
adoption sweep (fundbright, luminality, sidekick-web, nutripod). Each starts
from existing app code and shows the smallest change that gets you onto the
gem's contract.

## TL;DR — picking the right mode

| Starting pattern | Recommended mode |
|---|---|
| `after_create_commit` callback that calls `increment_counter` on a counter cache | `:inline` with `counters:` |
| `after_create_commit` that calls a custom block | `:inline` with a block |
| Bespoke `Update*Job` enqueued from `after_create_commit`, doing a recompute-from-log | `:async` via `Projection` subclass |
| Existing Postgres trigger doing the projection | `:trigger` |
| Existing Scenic materialised view, refreshed on a schedule | `:matview` |
| AASM / state-machine model where the projection should fire on a transition (not on create) | `:manual` |

## Pattern 1 — Counter caches → `:inline`

**Before**

```ruby
class VoucherRecord < ApplicationRecord
  enum :action, { grant: "grant", redeem: "redeem", consume: "consume", clawback: "clawback" }

  after_create_commit :update_scheme_counts
  after_create_commit :update_profile_counts

  private

  def update_scheme_counts
    VoucherScheme.increment_counter(:granted_vouchers_count, voucher_scheme_id) if grant?
    VoucherScheme.increment_counter(:redeemed_vouchers_count, voucher_scheme_id) if redeem?
    # ... and so on
  end

  def update_profile_counts
    # ... mirror of the above
  end
end
```

**After**

```ruby
class VoucherRecord < ApplicationRecord
  include StandardLedger::Entry
  include StandardLedger::Projector

  enum :action, { grant: "grant", redeem: "redeem", consume: "consume", clawback: "clawback" }

  ledger_entry kind: :action,
               idempotency_key: :serial_no,
               scope: %i[organisation_id action]

  projects_onto :voucher_scheme, mode: :inline, counters: {
    grant:    :granted_vouchers_count,
    redeem:   :redeemed_vouchers_count,
    consume:  :consumed_vouchers_count,
    clawback: :clawed_back_vouchers_count
  }

  projects_onto :customer_profile, mode: :inline, counters: {
    grant:    :granted_vouchers_count,
    redeem:   :redeemed_vouchers_count,
    consume:  :consumed_vouchers_count,
    clawback: :clawed_back_vouchers_count
  }
end
```

**What changes:**
- The projection now runs in `after_create` (in-transaction) instead of
  `after_create_commit` (post-commit). If the host transaction rolls back,
  counter mutations roll back with it — the journal and its projections
  can no longer drift.
- The `counters:` shortcut synthesises one
  `on(kind) { |target, _| target.class.increment_counter(col, target.id) }`
  per kind. Direct UPDATE (the class-method form) is intentional: it
  invalidates the SQL query cache for the target table on each call,
  which keeps multiple sibling-entry creates inside one transaction (e.g.
  via `accepts_nested_attributes_for`) from losing updates against
  stale cached reads. Block form is still available for non-counter
  projections — see Pattern 2.
- Idempotency arrives "free" — duplicate `create!` calls under the same
  unique-index scope return the existing row with `idempotent? == true`.

## Pattern 2 — Custom logic on create → `:inline` with a block

When the projection isn't a simple counter cache (computes a derived
column, conditionally updates one of several attributes, etc.), use the
block form:

```ruby
projects_onto :voucher_scheme, mode: :inline do
  on(:grant) do |scheme, entry|
    scheme.increment(:granted_vouchers_count)
    scheme.update_column(:last_granted_at, entry.created_at) if scheme.last_granted_at.nil?
  end
end
```

`target.increment(col)` is in-memory only; the gem coalesces all handlers
that mutated the same target and issues one `target.save!` per
(entry, target) pair. If you need direct SQL semantics (e.g. for the
sibling-entry race described above), call
`target.class.increment_counter(col, target.id)` instead.

## Pattern 3 — Bespoke job → `:async` via Projection

**Before**

```ruby
class PaymentRecord < ApplicationRecord
  after_create_commit { |r| UpdatePayableJob.perform_later(r.payable) }
end

class UpdatePayableJob < ApplicationJob
  queue_as :default
  retry_on ActiveRecord::RecordNotFound, wait: :polynomially_longer, attempts: 3

  def perform(payable)
    payable.with_lock do
      balance = payable.payment_records.sum(:amount)
      status  = balance.zero? ? :current : balance.positive? ? :refund_due : :payment_due
      payable.update!(payable_balance: balance, payable_status: status)
    end
  end
end
```

**After**

```ruby
class PaymentRecord < ApplicationRecord
  include StandardLedger::Entry
  include StandardLedger::Projector

  ledger_entry kind: :source_type,
               idempotency_key: nil,
               scope: %i[payable_type payable_id]

  projects_onto :payable, mode: :async, via: Payments::PayableProjector
end

# app/operations/payments/payable_projector.rb
module Payments
  class PayableProjector < StandardLedger::Projection
    def apply(payable, _entry)
      balance = payable.payment_records.sum(:amount)
      status  = balance.zero? ? :current : balance.positive? ? :refund_due : :payment_due
      payable.update!(payable_balance: balance, payable_status: status)
    end

    # `rebuild` is invoked by `StandardLedger.rebuild!` for log replay
    # (e.g. after a backfill or repair). For recompute-from-log
    # projectors it's just `apply` with a nil entry.
    def rebuild(payable) = apply(payable, nil)
  end
end
```

**What changes:**
- `UpdatePayableJob` (and its spec) is deleted. `StandardLedger::ProjectionJob`
  takes over: it wraps the projector in `target.with_lock`, retries on
  `StandardError` with polynomial backoff (cap configurable via
  `Config#default_async_retries`), and emits the standard
  `<prefix>.projection.applied` / `.failed` notifications with the
  attempt number on retries.
- Adding `rebuild` makes the projection log-replayable —
  `StandardLedger.rebuild!(PaymentRecord)` can recompute every payable
  from the full payment_records log. Recompute-from-log projectors get
  `rebuild` for free as a one-liner delegating to `apply`.

## Pattern 4 — Existing Postgres trigger → `:trigger`

The gem doesn't create or manage triggers — it records the trigger's
name (so `standard_ledger:doctor` can verify its presence in the
connected schema) and the rebuild SQL (so `StandardLedger.rebuild!` can
recompute targets from the full entry log after a repair).

```ruby
class InventoryRecord < ApplicationRecord
  include StandardLedger::Entry
  include StandardLedger::Projector

  trigger.after(:insert) do
    # ... existing hairtrigger DDL untouched ...
  end

  ledger_entry kind: :action, idempotency_key: nil, scope: :sku_id

  projects_onto :sku,
                mode: :trigger,
                trigger_name: "inventory_records_after_insert_row_tr",
                rebuild_sql: <<~SQL.squish
                  WITH inventory_counts AS (
                    SELECT
                      COALESCE(SUM(CASE WHEN action IN ('reserve', 'release') THEN quantity ELSE 0 END), 0) AS reserved,
                      COALESCE(SUM(CASE WHEN action IN ('increase', 'decrease') THEN quantity ELSE 0 END), 0) AS total
                    FROM inventory_records
                    WHERE sku_id = :target_id
                  )
                  UPDATE skus
                  SET reserved_count = inventory_counts.reserved,
                      total_count    = inventory_counts.total,
                      free_count     = inventory_counts.total - inventory_counts.reserved
                  FROM inventory_counts
                  WHERE id = :target_id;
                SQL
end
```

The `:target_id` placeholder is bound by the gem to each target's id
when `StandardLedger.rebuild!` walks the log.

## Pattern 5 — State-machine entries → `:manual`

When the projection should fire on an AASM transition (or any other
host-controlled lifecycle event) — not on `after_create` — use
`mode: :manual`. The gem records the contract (target + projector
class) so `rebuild!` can replay from the log, but installs no
auto-firing callback. The host invokes the projector explicitly:

```ruby
class Validation < ApplicationRecord
  include AASM
  include StandardLedger::Entry
  include StandardLedger::Projector

  aasm column: :outcome, enum: true do
    state :pending, initial: true
    state :auto_validated, :validated, :auto_invalidated, :invalidated, :manual_review
    event(:auto_validate) { transitions from: :pending, to: :auto_validated }
    # ... more transitions
  end

  ledger_entry kind: :outcome, idempotency_key: nil, scope: :application_id, immutable: false

  # Records the contract so StandardLedger.rebuild!(Validation) works,
  # but installs no callback — Validations::ProcessResponse and
  # Validations::Resolve invoke ProfileProjector explicitly when a
  # transition reaches a successful outcome.
  projects_onto :borrower_profile, mode: :manual, via: Validations::ProfileProjector
end

# In the operation that drives the transition:
def execute
  ActiveRecord::Base.transaction do
    validation.auto_validate!
    Validations::ProfileProjector.new.apply(borrower_profile, validation)
  end
end
```

The `immutable: false` setting is required because AASM transitions
issue UPDATEs after the row is created — the strict immutable contract
would block them. The journal contract still holds in spirit:
application code never UPDATEs anything except the AASM column.

## Cascade deletes (`dependent: :destroy`)

If the entry's owning record declares `has_many :events, dependent: :destroy`
for sandbox cleanup or GDPR erasure, opt the entry into the destroy
path with `allow_destroy: true`:

```ruby
ledger_entry kind: :event_type,
             scope: :device_id,
             immutable: true,
             allow_destroy: true
```

`save`/`update` paths still raise `ActiveRecord::ReadOnlyRecord` on
persisted rows; only `destroy` is permitted. The journal contract
holds in normal app code — only owning-record destruction triggers
cascade deletes.

## Refresh from inside an operation (`refresh!` and transactions)

`StandardLedger.refresh!(:view, concurrently: true)` raises
`StandardLedger::RefreshInsideTransaction` if called inside an open
transaction — Postgres rejects `REFRESH MATERIALIZED VIEW CONCURRENTLY`
inside transaction blocks. To get read-your-write consistency from a
host operation, move the refresh outside the transaction:

```ruby
def perform_draws
  ActiveRecord::Base.transaction do
    # ... create entries, etc ...
  end

  # Outside the transaction — race-safe and Postgres-legal.
  StandardLedger.refresh!(:user_prompt_inventories)
rescue StandardError => e
  # Refresh failures are best-effort here — the scheduled
  # MatviewRefreshJob is the safety net for missed refreshes.
  Rails.error.report(e, handled: true)
end
```

The non-concurrent form (`concurrently: false`) is permitted by
Postgres inside transactions, but it blocks reads on the matview for
the duration of the refresh — usually not what you want.
