module StandardLedger
  module RSpec
    # Convenience methods auto-included into every RSpec example group when
    # the host loads `require "standard_ledger/rspec"`. The actual override
    # map lives on `StandardLedger` itself so non-RSpec callers (e.g. a
    # background job spec running outside RSpec) can use the same API.
    module Helpers
      # Forwards to `StandardLedger.with_modes` so specs can write
      # `with_modes(...) { ... }` instead of the fully-qualified form.
      def with_modes(overrides, &block)
        StandardLedger.with_modes(overrides, &block)
      end
    end
  end
end
