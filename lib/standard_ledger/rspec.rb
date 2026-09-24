require "rspec/core"
require "rspec/expectations"

require "standard_ledger"
require "standard_ledger/rspec/matchers"

# Opt-in test support for host apps. Hosts add this require to their
# `spec/rails_helper.rb` (or equivalent):
#
#   require "standard_ledger/rspec"
#
# Loading this file defines the `post_ledger_entry` matcher for assertions of
# the form `expect { ... }.to post_ledger_entry(EntryClass).with(kind: ...)`.
#
# It registers no hooks: the gem keeps no per-example state (the thread-local
# `with_modes` overrides it used to reset were removed in 0.6.0), and it never
# touches the host's `Config`, so an initializer-configured `result_adapter`
# survives across examples.
module StandardLedger
  module RSpec
  end
end
