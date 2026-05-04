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
