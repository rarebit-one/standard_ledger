RSpec.describe StandardLedger::Projector do
  def fresh_entry_class
    Class.new do
      include StandardLedger::Entry
      include StandardLedger::Projector

      ledger_entry kind: :action

      attr_accessor :voucher_scheme, :customer_profile, :order, :action

      def self.name = "TestEntry"

      def initialize(action: nil, voucher_scheme: nil, customer_profile: nil, order: nil)
        @action = action
        @voucher_scheme = voucher_scheme
        @customer_profile = customer_profile
        @order = order
      end
    end
  end

  let(:entry_class) { fresh_entry_class }

  describe "DSL registration" do
    it "stores handlers when given a block" do
      entry_class.projects_onto :voucher_scheme, mode: :inline do
        on(:grant)  { |s, _| s.granted += 1 }
        on(:redeem) { |s, _| s.redeemed += 1 }
      end

      definition = entry_class.standard_ledger_projections.first
      expect(definition.target_association).to eq(:voucher_scheme)
      expect(definition.mode).to eq(:inline)
      expect(definition.handlers.keys).to contain_exactly(:grant, :redeem)
      expect(definition.projector_class).to be_nil
    end

    it "stores projector_class when given via:" do
      projector_class = Class.new(StandardLedger::Projection) do
        def apply(target, _entry); target.touched = true; end
      end

      entry_class.projects_onto :order, mode: :async, via: projector_class

      definition = entry_class.standard_ledger_projections.first
      expect(definition.projector_class).to eq(projector_class)
      expect(definition.handlers).to be_empty
    end

    it "captures the if: guard, lock:, and permissive flags" do
      guard = -> { true }
      entry_class.projects_onto :voucher_scheme,
                                mode: :inline,
                                if: guard,
                                lock: :pessimistic,
                                permissive: true do
        on(:_) { |_, _| nil }
      end

      definition = entry_class.standard_ledger_projections.first
      expect(definition.guard).to equal(guard)
      expect(definition.lock).to eq(:pessimistic)
      expect(definition.permissive).to be(true)
    end

    it "raises ArgumentError when both a block and via: are given" do
      projector_class = Class.new(StandardLedger::Projection)

      expect {
        entry_class.projects_onto :order, mode: :async, via: projector_class do
          on(:grant) { |_, _| nil }
        end
      }.to raise_error(ArgumentError, /mutually exclusive/)
    end

    it "raises ArgumentError for an empty block (no on(:_) calls)" do
      expect {
        entry_class.projects_onto :voucher_scheme, mode: :inline do
          # nothing
        end
      }.to raise_error(ArgumentError, /at least one `on\(:kind\) \{ \.\.\. \}` handler/)
    end

    it "raises ArgumentError when neither a block nor via: is given" do
      expect {
        entry_class.projects_onto :voucher_scheme, mode: :inline
      }.to raise_error(ArgumentError, /requires either a block .* or `via:/)
    end
  end

  describe "#apply_projection!" do
    let(:target) { Struct.new(:granted, :redeemed, :touched, :balance).new(0, 0, false, 0) }

    it "dispatches to the right handler by kind" do
      entry_class.projects_onto :voucher_scheme, mode: :inline do
        on(:grant)  { |s, _| s.granted += 1 }
        on(:redeem) { |s, _| s.redeemed += 1 }
      end

      entry = entry_class.new(action: :grant, voucher_scheme: target)
      definition = entry_class.standard_ledger_projections.first

      entry.apply_projection!(definition)

      expect(target.granted).to eq(1)
      expect(target.redeemed).to eq(0)
    end

    it "raises UnhandledKind for unknown kinds when permissive: false" do
      entry_class.projects_onto :voucher_scheme, mode: :inline do
        on(:grant) { |s, _| s.granted += 1 }
      end

      entry = entry_class.new(action: :clawback, voucher_scheme: target)
      definition = entry_class.standard_ledger_projections.first

      expect {
        entry.apply_projection!(definition)
      }.to raise_error(StandardLedger::UnhandledKind, /clawback/)
    end

    it "falls back to the :_ wildcard when permissive: true and a wildcard exists" do
      wildcard_calls = []

      entry_class.projects_onto :voucher_scheme, mode: :inline, permissive: true do
        on(:grant) { |s, _| s.granted += 1 }
        on(:_)     { |s, e| wildcard_calls << [ s, e.action ] }
      end

      entry = entry_class.new(action: :clawback, voucher_scheme: target)
      definition = entry_class.standard_ledger_projections.first

      entry.apply_projection!(definition)

      expect(wildcard_calls).to eq([ [ target, :clawback ] ])
    end

    it "skips silently when permissive: true but no wildcard registered" do
      entry_class.projects_onto :voucher_scheme, mode: :inline, permissive: true do
        on(:grant) { |s, _| s.granted += 1 }
      end

      entry = entry_class.new(action: :clawback, voucher_scheme: target)
      definition = entry_class.standard_ledger_projections.first

      expect { entry.apply_projection!(definition) }.not_to raise_error
      expect(target.granted).to eq(0)
    end

    it "skips when the if: guard returns false" do
      entry_class.projects_onto :voucher_scheme, mode: :inline, if: -> { false } do
        on(:grant) { |s, _| s.granted += 1 }
      end

      entry = entry_class.new(action: :grant, voucher_scheme: target)
      definition = entry_class.standard_ledger_projections.first

      entry.apply_projection!(definition)

      expect(target.granted).to eq(0)
    end

    it "evaluates the if: guard in the entry's instance context" do
      seen = []
      guard = -> { seen << action; true }

      entry_class.projects_onto :voucher_scheme, mode: :inline, if: guard do
        on(:grant) { |s, _| s.granted += 1 }
      end

      entry = entry_class.new(action: :grant, voucher_scheme: target)
      definition = entry_class.standard_ledger_projections.first

      entry.apply_projection!(definition)

      expect(seen).to eq([ :grant ])
      expect(target.granted).to eq(1)
    end

    it "skips when the target is nil" do
      entry_class.projects_onto :customer_profile, mode: :inline do
        on(:grant) { |p, _| p.granted += 1 }
      end

      entry = entry_class.new(action: :grant, customer_profile: nil)
      definition = entry_class.standard_ledger_projections.first

      expect { entry.apply_projection!(definition) }.not_to raise_error
    end

    it "raises StandardLedger::Error when the kind column is nil" do
      entry_class.projects_onto :voucher_scheme, mode: :inline do
        on(:grant) { |s, _| s.granted += 1 }
      end

      entry = entry_class.new(action: nil, voucher_scheme: target)
      definition = entry_class.standard_ledger_projections.first

      expect {
        entry.apply_projection!(definition)
      }.to raise_error(StandardLedger::Error, /nil kind/)
    end

    it "calls the projector class's apply(target, entry) when class form" do
      projector_class = Class.new(StandardLedger::Projection) do
        def apply(t, entry)
          t.touched = true
          t.balance = entry.action == :credit ? 100 : 0
        end
      end

      entry_class.projects_onto :order, mode: :async, via: projector_class

      entry = entry_class.new(action: :credit, order: target)
      definition = entry_class.standard_ledger_projections.first

      entry.apply_projection!(definition)

      expect(target.touched).to be(true)
      expect(target.balance).to eq(100)
    end

    context "with lock: :pessimistic" do
      let(:lock_target_class) do
        Class.new do
          attr_accessor :granted, :with_lock_called, :handler_ran_inside_lock
          attr_reader :inside_lock

          def initialize
            @granted = 0
            @with_lock_called = false
            @handler_ran_inside_lock = false
          end

          def with_lock
            @with_lock_called = true
            inside_before = @inside_lock
            @inside_lock = true
            yield
          ensure
            @inside_lock = inside_before
          end
        end
      end
      let(:lock_target) { lock_target_class.new }

      it "wraps the handler call in target.with_lock" do
        entry_class.projects_onto :voucher_scheme, mode: :inline, lock: :pessimistic do
          on(:grant) do |s, _|
            s.handler_ran_inside_lock = s.inside_lock
            s.granted += 1
          end
        end

        entry = entry_class.new(action: :grant, voucher_scheme: lock_target)
        definition = entry_class.standard_ledger_projections.first

        entry.apply_projection!(definition)

        expect(lock_target.with_lock_called).to be(true)
        expect(lock_target.handler_ran_inside_lock).to be(true)
        expect(lock_target.granted).to eq(1)
      end
    end

    it "does NOT call with_lock when no lock is specified" do
      target_with_spy = double("target", granted: 0)
      allow(target_with_spy).to receive(:granted=)

      entry_class.projects_onto :voucher_scheme, mode: :inline do
        on(:grant) { |s, _| s.granted = (s.granted || 0) + 1 }
      end

      entry = entry_class.new(action: :grant, voucher_scheme: target_with_spy)
      definition = entry_class.standard_ledger_projections.first

      expect(target_with_spy).not_to receive(:with_lock)

      entry.apply_projection!(definition)
    end

    context "with via: ProjectorClass and lock: :pessimistic" do
      let(:projector_class) do
        Class.new(StandardLedger::Projection) do
          def apply(target, _entry)
            target.applied = true
          end
        end
      end
      let(:simple_lock_target_class) do
        Class.new do
          attr_accessor :applied, :with_lock_called

          def initialize
            @applied = false
            @with_lock_called = false
          end

          def with_lock
            @with_lock_called = true
            yield
          end
        end
      end
      let(:simple_lock_target) { simple_lock_target_class.new }

      it "wraps the projector class call in target.with_lock" do
        entry_class.projects_onto :order, mode: :async, via: projector_class, lock: :pessimistic

        entry = entry_class.new(action: :grant, order: simple_lock_target)
        definition = entry_class.standard_ledger_projections.first

        entry.apply_projection!(definition)

        expect(simple_lock_target.with_lock_called).to be(true)
        expect(simple_lock_target.applied).to be(true)
      end
    end
  end

  describe ".standard_ledger_projections_for" do
    it "filters projections by mode" do
      entry_class.projects_onto :voucher_scheme, mode: :inline do
        on(:grant) { |_, _| nil }
      end
      entry_class.projects_onto :customer_profile, mode: :async do
        on(:grant) { |_, _| nil }
      end
      entry_class.projects_onto :order, mode: :inline do
        on(:grant) { |_, _| nil }
      end

      inline = entry_class.standard_ledger_projections_for(:inline)
      async  = entry_class.standard_ledger_projections_for(:async)

      expect(inline.map(&:target_association)).to eq([ :voucher_scheme, :order ])
      expect(async.map(&:target_association)).to eq([ :customer_profile ])
    end

    it "returns an empty array for a mode with no registered projections" do
      entry_class.projects_onto :voucher_scheme, mode: :inline do
        on(:grant) { |_, _| nil }
      end

      expect(entry_class.standard_ledger_projections_for(:async)).to eq([])
    end
  end
end
