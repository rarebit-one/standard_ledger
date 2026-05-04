require "rspec/core"
require "rspec/expectations"

require "standard_ledger"
require "standard_ledger/rspec/matchers"
require "standard_ledger/rspec/helpers"

# Opt-in test support for host apps. Hosts add this require to their
# `spec/rails_helper.rb` (or equivalent):
#
#   require "standard_ledger/rspec"
#
# Loading this file:
#
# - Registers a `before(:each)` hook that calls
#   `StandardLedger.reset_mode_overrides!` so the thread-local `with_modes`
#   override map doesn't leak between examples. We deliberately do *not* call
#   the full `reset!` here: hosts often configure the gem from a Rails
#   initializer (`StandardLedger.configure { |c| c.result_adapter = ... }`),
#   and wiping `@config` between examples would silently undo that
#   configuration for every spec. The reset is wired via `RSpec.configure`
#   rather than a custom shared context so it applies to every example group
#   automatically.
# - Defines the `post_ledger_entry` matcher (see
#   `StandardLedger::RSpec::Matchers`) for assertions of the form
#   `expect { ... }.to post_ledger_entry(EntryClass).with(kind: ...)`.
# - Includes `StandardLedger::RSpec::Helpers` into every example group so
#   specs can call `with_modes(...)` directly without the module prefix.
#
# We intentionally avoid touching subscribers, AR connections, or any host
# state — the gem only owns its own configuration. Hosts that need additional
# cleanup wire their own hooks alongside this one.
module StandardLedger
  module RSpec
  end
end

::RSpec.configure do |config|
  config.before(:each) do
    StandardLedger.reset_mode_overrides!
  end

  config.include StandardLedger::RSpec::Helpers
end
