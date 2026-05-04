# standard_ledger

Immutable journal entries with declarative aggregate projections for Rails apps.

> **Status: scaffolding (v0.1.0).** The gem layout, public API surface, and
> build pipeline are in place; the runtime behavior (mode implementations,
> idempotency rescue, rebuild path) lands in subsequent PRs. See
> [`standard_ledger-design.md`](https://github.com/rarebit-one/standard_ledger/blob/main/standard_ledger-design.md)
> in the workspace for the full design.

## What it is

Across our four Rails apps (nutripod-web, luminality-web, fundbright-web,
sidekick-web) we keep building the same thing: an immutable journal table
whose rows update one or more cached aggregates on parent records. Inventory
movements, voucher issuance, payment records, fulfillment records, prompt
transactions, entitlement grants, validation outcomes, device firmware
updates — same shape, eight different ad-hoc implementations.

`standard_ledger` extracts the pattern into a single declarative DSL that
lives on top of the host's existing ActiveRecord models. The gem **does not
own the schema** — host apps already have entry tables and aggregate columns,
and the gem adapts to them rather than replacing them.

## Sketch

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

  projects_onto :customer_profile,
                mode: :inline,
                if:   -> { customer_profile_id.present? } do
    on(:grant)    { |profile, _| profile.increment(:granted_vouchers_count) }
    on(:redeem)   { |profile, _| profile.increment(:redeemed_vouchers_count) }
    on(:consume)  { |profile, _| profile.increment(:consumed_vouchers_count) }
    on(:clawback) { |profile, _| profile.increment(:clawed_back_vouchers_count) }
  end
end
```

Post an entry with the module API (sugar over `VoucherRecord.create!`):

```ruby
result = StandardLedger.post(VoucherRecord,
  kind:    :grant,
  targets: { voucher_scheme: scheme, customer_profile: profile },
  attrs:   { organisation_id: org.id, serial_no: "v-2025-1" })

result.success?     # => true
result.entry        # => the persisted VoucherRecord
result.idempotent?  # => false (true on retry against the same serial_no)
result.projections  # => { inline: [:voucher_scheme, :customer_profile] }
```

Counters on both targets are incremented inside the same transaction as
the INSERT — if any projection raises, the entry rolls back too. Posting
twice with the same `serial_no` returns the original entry (with
`idempotent? == true`) and skips the projection.

Rebuild a target's projection from the log when its counters drift
or a projection bug needs replaying — extract a `Projection` subclass
that implements `rebuild(target)` and pass it via `via:`:

```ruby
class SchemeProjector < StandardLedger::Projection
  def apply(scheme, entry)
    scheme.increment(:"#{entry.action}_vouchers_count")
    scheme.save!
  end

  def rebuild(scheme)
    records = VoucherRecord.where(voucher_scheme_id: scheme.id)
    scheme.update!(
      granted_vouchers_count:  records.where(action: "grant").count,
      redeemed_vouchers_count: records.where(action: "redeem").count
    )
  end
end

# Single target, single class, or every target across every projection.
StandardLedger.rebuild!(VoucherRecord, target: scheme)
StandardLedger.rebuild!(VoucherRecord, target_class: VoucherScheme)
StandardLedger.rebuild!(VoucherRecord)
```

Each (target, projection) pair runs in its own transaction; failures
mid-loop are not unwound. Block-form (delta) projections raise
`NotRebuildable` because they cannot be reconstructed from the log
without a host-supplied recompute path.

Five projection modes — pick per declaration:

| Mode | Where the work runs | Transactional? | Rebuildable? |
|---|---|---|---|
| `:inline` | `after_create`, in the entry's transaction | yes | yes (if projector implements `rebuild`) |
| `:async` | `after_create_commit` job, `with_lock` | no | yes (if projector implements `rebuild`) |
| `:sql` | `after_create`, single `UPDATE ... FROM (SELECT ...)` | yes | yes (rebuild = same SQL) |
| `:trigger` | the database, on INSERT | yes (same statement) | yes (host-owned trigger; gem records rebuild SQL) |
| `:matview` | scheduled `REFRESH MATERIALIZED VIEW CONCURRENTLY` | no | trivially (refresh = rebuild) |

## Installation

The gem is private during incubation. Pin from git:

```ruby
gem "standard_ledger", git: "https://github.com/rarebit-one/standard_ledger", ref: "<sha>"
```

Then run the install generator to drop a configured initializer in place:

```bash
bin/rails g standard_ledger:install
```

This writes `config/initializers/standard_ledger.rb` with commented-out
examples covering every public `Config` setting — uncomment and edit only
what you want to override. The generator is idempotent; re-running on an
existing initializer skips with a clear message (pass `--force` to
overwrite).

A typical configuration looks like:

```ruby
StandardLedger.configure do |c|
  c.default_async_retries     = 3
  c.scheduler                 = :solid_queue
  c.matview_refresh_strategy  = :concurrent

  # Optional — return the host's Result type from StandardLedger.post:
  c.result_class   = ApplicationOperation::Result
  c.result_adapter = ->(success:, value:, errors:, entry:, idempotent:, projections:) {
    ApplicationOperation::Result.new(success:, value: value || entry, errors:)
  }
end
```

## Testing

The gem ships an opt-in RSpec support file. Hosts add this to their
`spec/rails_helper.rb`:

```ruby
require "standard_ledger/rspec"
```

That registers a `before(:each)` hook that calls `StandardLedger.reset!`
between examples (so per-spec configuration doesn't leak), and exposes:

- `post_ledger_entry(EntryClass).with(...)` — a block matcher that
  subscribes to the `<namespace>.entry.created` notification for the
  duration of the block and asserts an entry of the expected class was
  written (with optional `kind:`/`targets:`/`attrs:` constraints).

  ```ruby
  it "records a voucher grant" do
    expect {
      Vouchers::IssueOperation.call(scheme: scheme, profile: profile)
    }.to post_ledger_entry(VoucherRecord).with(
      kind:    :grant,
      targets: { voucher_scheme: scheme, customer_profile: profile },
      attrs:   { serial_no: "v-2025-1" }
    )
  end
  ```

- `with_modes(EntryClass => :inline) { ... }` — forces specific entry
  classes' projections to run inline for the duration of the block. The
  override is thread-local and restored on block exit, so async-mode
  projections can be exercised end-to-end in a unit spec without a job
  runner.

  ```ruby
  it "fast-runs an async projection inline" do
    with_modes(PaymentRecord => :inline) do
      Orders::CheckoutOperation.call(...)
    end
  end
  ```

## Development

```bash
bundle install
bundle exec rspec
bundle exec rubocop
```

## Relationship to standard_audit

Different gems, different concerns:

- **`standard_audit`** — "user X took action Y on target Z," free-form
  metadata, no projection.
- **`standard_ledger`** — "this delta updates these targets," typed kind,
  mandatory projection.

A single host operation typically writes one of each, in one transaction.
Neither subsumes the other.

## License

MIT. See [MIT-LICENSE](MIT-LICENSE).
