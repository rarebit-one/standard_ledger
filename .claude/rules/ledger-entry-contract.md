---
paths:
  - "lib/standard_ledger/**/*.rb"
  - "spec/**/*.rb"
---

# Ledger entry contract — invariants to preserve

`StandardLedger::Entry` marks an ActiveRecord model as an **immutable,
append-only** journal row. The whole point of this gem is that a persisted
entry is a permanent fact. When editing `entry.rb`, the modes, or projection
code, preserve these invariants — a change that quietly relaxes them is a
correctness regression, not a refactor.

## Immutability (default `immutable: true`)

- After a row is **persisted**, `save`/`update` must raise
  `ActiveRecord::ReadOnlyRecord`. This is implemented via `readonly?` returning
  true for persisted immutable rows — AR consults it on the write paths.
- **New, unpersisted instances stay writable** so the initial `create` works.
  Don't make `readonly?` return true unconditionally.
- `destroy` is **blocked** on immutable rows *unless* `allow_destroy: true`.
  `allow_destroy` exists only so an owner's `dependent: :destroy` cascade can
  clean up (sandbox tear-down, GDPR erasure) — it is not a general "entries are
  editable" switch. Keep it opt-in and defaulted to `false`.
- The destroy-bypass uses a transient `@_standard_ledger_destroying` flag so
  `readonly?` returns false only for the duration of an allowed destroy. Don't
  leak that state.

## Idempotency-by-unique-index

- When `idempotency_key:` is non-nil, `create!` catches the unique-index
  collision and **returns the existing row** (with `idempotent? == true`)
  instead of raising `RecordNotUnique`. Preserve this rescue.
- Block-form `create! { |r| ... }` is deliberately **not** covered by the
  idempotent rescue (AR passes `attributes = nil`), so a colliding block-form
  insert re-raises like vanilla AR. Don't "fix" this without handling the nil.
- `scope:` is always normalised to a **flat array** on the stored config
  (`Array(scope).compact`). Host specs compare against `[:foo]`, not `:foo` —
  keep the normalisation so downstream reads don't have to handle both shapes.

## Decoupling

Immutability (`Entry`) and projection registration (`Projector`) are **separate
concerns** — an entry can be immutable without projecting, and vice versa. Don't
re-couple them.
