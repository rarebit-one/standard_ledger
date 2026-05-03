require "active_support"
require "active_support/notifications"
require "concurrent"

require "standard_ledger/version"
require "standard_ledger/errors"
require "standard_ledger/result"
require "standard_ledger/config"
require "standard_ledger/entry"
require "standard_ledger/projection"
require "standard_ledger/projector"
require "standard_ledger/modes/inline"
require "standard_ledger/engine" if defined?(::Rails::Engine)

# StandardLedger captures the recurring "immutable journal entry → N
# aggregate projections" pattern as a declarative DSL on host ActiveRecord
# models. See `standard_ledger-design.md` in the workspace root for the
# full design discussion.
#
# Public surface:
#
#   StandardLedger.configure { |c| ... }   # configure once at boot
#   StandardLedger.config                  # read configured values
#   StandardLedger.post(EntryClass, ...)   # write an entry + project (lands in v0.1 follow-up)
#   StandardLedger.rebuild!(EntryClass)    # recompute projections from log
#   StandardLedger.refresh!(:view_name)    # ad-hoc matview refresh
#   StandardLedger.reset!                  # test helper
module StandardLedger
  class << self
    # Configure the gem once per app, typically from
    # `config/initializers/standard_ledger.rb`. Yields the `Config` instance.
    def configure
      yield config
      config
    end

    def config
      @config ||= Config.new
    end

    def reset!
      @config = nil
    end
  end
end
