module StandardLedger
  class Error < StandardError; end

  # Raised at registration time when a `projects_onto` block declares an
  # `on(:kind)` for a kind that the entry's enum/set does not include, or
  # when an entry is posted with a kind that no projection has registered
  # a handler for. Use `permissive: true` on the projection to opt out.
  class UnhandledKind < Error; end

  # Raised by `StandardLedger.rebuild!` when the projector does not implement
  # `rebuild` and is therefore not replayable from the entry log. Delta-based
  # projectors (e.g. `increment_counter`-flavored) typically raise this
  # because they cannot be reconstructed without summing the full log.
  class NotRebuildable < Error; end

  # Raised at boot when an Entry declares `idempotency_key:` but no matching
  # unique index exists on the entry table. Caught early instead of silently
  # admitting duplicates at runtime.
  class MissingIdempotencyIndex < Error; end

  # Raised by `StandardLedger.post` when the inline portion of fan-out
  # succeeded but enqueuing one or more async projections failed. The entry
  # itself is durable; callers may choose to roll back or accept-and-log.
  class PartialFailure < Error
    attr_reader :enqueued, :failed

    def initialize(enqueued:, failed:)
      @enqueued = enqueued
      @failed = failed
      super("Enqueued #{enqueued.size} projections; #{failed.size} failed to enqueue")
    end
  end
end
