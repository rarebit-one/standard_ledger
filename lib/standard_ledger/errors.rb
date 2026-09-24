module StandardLedger
  class Error < StandardError; end

  # Raised by `StandardLedger::Projection#rebuild` when a projector subclass
  # does not override it — i.e. the projector cannot be recomputed from the
  # entry log.
  class NotRebuildable < Error; end

  # Raised at boot when an Entry declares `idempotency_key:` but no matching
  # unique index exists on the entry table. Caught early instead of silently
  # admitting duplicates at runtime.
  class MissingIdempotencyIndex < Error; end

  # Raised when `StandardLedger.refresh!(view, concurrently: true)` is called
  # inside an open transaction. PostgreSQL rejects
  # `REFRESH MATERIALIZED VIEW CONCURRENTLY` inside transaction blocks; the
  # gem catches this at the boundary so the failure is a clear,
  # gem-attributable error instead of a raw `PG::ActiveSqlTransaction`.
  # Pass `concurrently: :auto` to fall back to a plain refresh instead, move
  # the refresh outside the transaction, or defer it with
  # `connection.add_transaction_record { ... }`.
  class RefreshInsideTransaction < Error; end
end
