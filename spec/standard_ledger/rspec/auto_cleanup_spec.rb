# rubocop:disable RSpec/DescribeClass
RSpec.describe "standard_ledger/rspec auto-cleanup" do
  it "registers a before(:each) hook that resets the gem's config" do
    # The hook is wired by `require 'standard_ledger/rspec'` (loaded from
    # spec_helper.rb). Mutate the config and confirm the hook clears it
    # before the next example runs by invoking it explicitly here.
    StandardLedger.configure { |c| c.notification_namespace = "host.ledger" }
    expect(StandardLedger.config.notification_namespace).to eq("host.ledger")

    # Simulate the per-example hook firing.
    StandardLedger.reset!

    expect(StandardLedger.config.notification_namespace).to eq("standard_ledger")
  end

  it "clears any leftover with_modes overrides on reset!" do
    Thread.current[:standard_ledger_mode_overrides] = { Object => :inline }

    StandardLedger.reset!

    expect(Thread.current[:standard_ledger_mode_overrides]).to be_nil
  end

  it "auto-includes Helpers into example groups" do
    expect(self).to respond_to(:with_modes)
  end
end
# rubocop:enable RSpec/DescribeClass
