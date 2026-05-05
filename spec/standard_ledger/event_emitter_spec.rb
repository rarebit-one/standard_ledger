require "spec_helper"

RSpec.describe StandardLedger::EventEmitter do
  describe ".emit" do
    let(:payload) { { entry: "row", kind: :grant, targets: {} } }

    context "when Rails.event is available" do
      it "routes through Rails.event.notify with the **payload splat" do
        captured = nil
        rails_event = Object.new
        rails_event.define_singleton_method(:respond_to?) { |m, *| m == :notify || super(m) }
        rails_event.define_singleton_method(:notify) do |name, **payload|
          captured = { name: name, payload: payload }
        end
        rails_const = Module.new
        rails_const.define_singleton_method(:respond_to?) { |m, *| m == :event || super(m) }
        rails_const.define_singleton_method(:event) { rails_event }
        stub_const("Rails", rails_const)

        described_class.emit("standard_ledger.entry.created", payload)

        expect(captured).to eq(name: "standard_ledger.entry.created", payload: payload)
      end
    end

    context "when Rails.event is unavailable" do
      it "falls back to ActiveSupport::Notifications.instrument with the payload hash" do
        hide_const("Rails") if defined?(::Rails)

        events = []
        callback = ->(name, _start, _finish, _id, payload) { events << [ name, payload ] }
        ActiveSupport::Notifications.subscribed(callback, "standard_ledger.entry.created") do
          described_class.emit("standard_ledger.entry.created", payload)
        end

        expect(events).to eq([ [ "standard_ledger.entry.created", payload ] ])
      end
    end

    it "swallows subscriber failures so ledger observability cannot break a host request" do
      faulty_rails = Module.new
      faulty_rails.define_singleton_method(:respond_to?) { |m, *| m == :event || super(m) }
      faulty_event = Object.new
      faulty_event.define_singleton_method(:respond_to?) { |m, *| m == :notify || super(m) }
      faulty_event.define_singleton_method(:notify) { |*| raise "subscriber blew up" }
      faulty_rails.define_singleton_method(:event) { faulty_event }
      stub_const("Rails", faulty_rails)

      expect {
        described_class.emit("standard_ledger.entry.created", { entry: "x" })
      }.not_to raise_error
    end

    it "prints a warning when an emit fails" do
      faulty_rails = Module.new
      faulty_rails.define_singleton_method(:respond_to?) { |m, *| m == :event || super(m) }
      faulty_event = Object.new
      faulty_event.define_singleton_method(:respond_to?) { |m, *| m == :notify || super(m) }
      faulty_event.define_singleton_method(:notify) { |*| raise "subscriber blew up" }
      faulty_rails.define_singleton_method(:event) { faulty_event }
      stub_const("Rails", faulty_rails)

      expect {
        described_class.emit("standard_ledger.entry.created", { entry: "x" })
      }.to output(/\[StandardLedger\] event emit for "standard_ledger.entry.created" failed: RuntimeError: subscriber blew up/).to_stderr
    end
  end

  describe ".rails_event_available?" do
    it "is false when Rails is not defined" do
      hide_const("Rails") if defined?(::Rails)

      expect(described_class).not_to be_rails_event_available
    end

    it "is false when Rails is defined but does not respond to :event" do
      stub_const("Rails", Module.new)

      expect(described_class).not_to be_rails_event_available
    end

    it "is true when Rails.event responds to :notify" do
      rails_event = Object.new
      rails_event.define_singleton_method(:respond_to?) { |m, *| m == :notify || super(m) }
      rails_event.define_singleton_method(:notify) { |*| nil }
      rails_const = Module.new
      rails_const.define_singleton_method(:respond_to?) { |m, *| m == :event || super(m) }
      rails_const.define_singleton_method(:event) { rails_event }
      stub_const("Rails", rails_const)

      expect(described_class).to be_rails_event_available
    end
  end
end
