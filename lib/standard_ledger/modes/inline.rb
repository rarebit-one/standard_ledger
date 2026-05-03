module StandardLedger
  module Modes
    # `:inline` mode: applies the projection inside the entry's `after_create`
    # callback, which fires while the host's outer transaction is still open.
    # If the host's transaction rolls back, the projection rolls back too.
    #
    # This is the default for delta-based counter updates. For complex
    # projectors (jsonb shape, multi-row aggregates), use `:async` instead.
    #
    # The actual `#call` implementation lands with the first integration
    # (nutripod vouchers, per design doc §10 step 1). This file establishes
    # the strategy interface so other modes can stub against it.
    class Inline
      def initialize(definition)
        @definition = definition
      end

      # Apply the projection synchronously within the entry's transaction.
      #
      # @param entry [ActiveRecord::Base] the just-created entry.
      # @param target_resolver [Proc] callable returning the target instance
      #   for a given association name.
      # @return [void]
      def call(entry, target_resolver)
        raise NotImplementedError, "Modes::Inline#call lands in the next PR (nutripod vouchers integration)"
      end
    end
  end
end
