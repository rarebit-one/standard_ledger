# rubocop:disable RSpec/DescribeClass
RSpec.describe "standard_ledger/rspec auto-cleanup" do
  # The auto-cleanup hook (registered in lib/standard_ledger/rspec.rb) only
  # clears thread-local mode overrides — it deliberately preserves `Config`
  # so a host's Rails initializer config survives across examples. These
  # specs mutate Config in-test, so they must clean up after themselves.
  after { StandardLedger.reset! }

  it "preserves the gem's config across the per-example hook" do
    # Hosts that configure the gem from a Rails initializer (e.g. setting
    # `result_adapter`) need that configuration to survive between
    # examples. Mutate the config and confirm invoking the hook's reset
    # preserves it.
    StandardLedger.configure { |c| c.notification_namespace = "host.ledger" }
    expect(StandardLedger.config.notification_namespace).to eq("host.ledger")

    # Simulate the per-example hook firing.
    StandardLedger.reset_mode_overrides!

    # Config survives — initializer-driven host config is not nuked.
    expect(StandardLedger.config.notification_namespace).to eq("host.ledger")
  end

  it "clears any leftover with_modes overrides via reset_mode_overrides!" do
    Thread.current[:standard_ledger_mode_overrides] = { Object => :inline }

    StandardLedger.reset_mode_overrides!

    expect(Thread.current[:standard_ledger_mode_overrides]).to be_nil
  end

  it "still wipes both config and overrides via the full reset!" do
    StandardLedger.configure { |c| c.notification_namespace = "host.ledger" }
    Thread.current[:standard_ledger_mode_overrides] = { Object => :inline }

    StandardLedger.reset!

    expect(StandardLedger.config.notification_namespace).to eq("standard_ledger")
    expect(Thread.current[:standard_ledger_mode_overrides]).to be_nil
  end

  it "auto-includes Helpers into example groups" do
    expect(self).to respond_to(:with_modes)
  end
end
# rubocop:enable RSpec/DescribeClass
