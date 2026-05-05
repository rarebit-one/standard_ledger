require "simplecov"
SimpleCov.start do
  enable_coverage :branch
  add_filter "/spec/"
end

require "standard_ledger"
require "standard_ledger/rspec"

require_relative "dummy/config/database"
ActiveRecord::Schema.verbose = false
load File.expand_path("dummy/db/schema.rb", __dir__)

# ActiveJob serializes its arguments and ActiveRecord instances are passed
# through GlobalID — rspec-rails normally wires this up automatically, but
# this gem's spec harness is Rails-free so we wire GlobalID by hand. Sets
# the app slug for the ID and includes GlobalID::Identification on AR base
# (the include in Rails happens in railties' Identification railtie).
require "globalid"
GlobalID.app = "standard-ledger-test"
ActiveRecord::Base.include(GlobalID::Identification) unless ActiveRecord::Base < GlobalID::Identification

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.mock_with :rspec do |m|
    m.verify_partial_doubles = true
  end

  config.order = :random
  Kernel.srand config.seed
end
