RSpec.describe StandardLedger::Config do
  subject(:config) { described_class.new }

  describe "defaults" do
    it "has the documented default values" do
      expect(config.default_async_retries).to eq(3)
      expect(config.scheduler).to eq(:solid_queue)
      expect(config.matview_refresh_strategy).to eq(:concurrent)
      expect(config.notification_namespace).to eq("standard_ledger")
    end

    it "leaves result interop unset by default" do
      expect(config.result_class).to be_nil
      expect(config.result_adapter).to be_nil
      expect(config.custom_result?).to be(false)
    end
  end

  describe "#custom_result?" do
    it "is true only when both result_class and result_adapter are set" do
      config.result_class = Class.new
      expect(config.custom_result?).to be(false)

      config.result_adapter = ->(**) { :host_result }
      expect(config.custom_result?).to be(true)
    end
  end
end
