RSpec.describe StandardLedger::Config do
  subject(:config) { described_class.new }

  describe "defaults" do
    it "has the documented default values" do
      expect(config.matview_refresh_strategy).to eq(:concurrent)
      expect(config.notification_namespace).to eq("standard_ledger")
    end

    it "no longer exposes the removed projection-engine settings" do
      %i[default_async_job default_async_retries scheduler].each do |setting|
        expect(config).not_to respond_to(setting)
      end
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
