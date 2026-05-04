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

Then in `config/initializers/standard_ledger.rb`:

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
