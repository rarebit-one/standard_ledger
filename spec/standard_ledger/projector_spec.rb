RSpec.describe StandardLedger::Projector do
  # The projector unit tests use plain Ruby classes (not ActiveRecord) so we
  # exercise the DSL surface and `apply_projection!` dispatch in isolation
  # from AR callbacks. Because `Modes::Inline.install!` requires an AR-backed
  # class, these tests register projections under `mode: :async`, which has
  # no install hook today — the registration path stays mode-agnostic, and
  # `apply_projection!` does not branch on mode either. Mode-specific
  # behavior (lock semantics, coalescing) is exercised in the integration
  # spec against the real AR harness.
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
      entry_class.projects_onto :voucher_scheme, mode: :async do
        on(:grant)  { |s, _| s.granted += 1 }
        on(:redeem) { |s, _| s.redeemed += 1 }
      end

      definition = entry_class.standard_ledger_projections.first
      expect(definition.target_association).to eq(:voucher_scheme)
      expect(definition.mode).to eq(:async)
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
                                mode: :async,
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
        entry_class.projects_onto :voucher_scheme, mode: :async do
          # nothing
        end
      }.to raise_error(ArgumentError, /at least one `on\(:kind\) \{ \.\.\. \}` handler/)
    end

    it "raises ArgumentError when neither a block nor via: is given" do
      expect {
        entry_class.projects_onto :voucher_scheme, mode: :async
      }.to raise_error(ArgumentError, /requires either a block .* or `via:/)
    end

    it "raises ArgumentError when permissive: true is combined with via:" do
      projector_class = Class.new(StandardLedger::Projection)

      expect {
        entry_class.projects_onto :order, mode: :async, via: projector_class, permissive: true
      }.to raise_error(ArgumentError, /permissive:.*only meaningful with the block form/)
    end
  end

  describe "#apply_projection!" do
    let(:target) { Struct.new(:granted, :redeemed, :touched, :balance).new(0, 0, false, 0) }

    it "dispatches to the right handler by kind and returns true" do
      entry_class.projects_onto :voucher_scheme, mode: :async do
        on(:grant)  { |s, _| s.granted += 1 }
        on(:redeem) { |s, _| s.redeemed += 1 }
      end

      entry = entry_class.new(action: :grant, voucher_scheme: target)
      definition = entry_class.standard_ledger_projections.first

      expect(entry.apply_projection!(definition)).to be(true)
      expect(target.granted).to eq(1)
      expect(target.redeemed).to eq(0)
    end

    it "dispatches correctly when kind is a String (as returned from a database column)" do
      entry_class.projects_onto :voucher_scheme, mode: :async do
        on(:grant) { |s, _| s.granted += 1 }
      end

      entry = entry_class.new(action: "grant", voucher_scheme: target)
      definition = entry_class.standard_ledger_projections.first

      entry.apply_projection!(definition)

      expect(target.granted).to eq(1)
    end

    it "raises UnhandledKind for unknown kinds when permissive: false" do
      entry_class.projects_onto :voucher_scheme, mode: :async do
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

      entry_class.projects_onto :voucher_scheme, mode: :async, permissive: true do
        on(:grant) { |s, _| s.granted += 1 }
        on(:_)     { |s, e| wildcard_calls << [ s, e.action ] }
      end

      entry = entry_class.new(action: :clawback, voucher_scheme: target)
      definition = entry_class.standard_ledger_projections.first

      entry.apply_projection!(definition)

      expect(wildcard_calls).to eq([ [ target, :clawback ] ])
    end

    it "skips silently and returns false when permissive: true but no wildcard registered" do
      entry_class.projects_onto :voucher_scheme, mode: :async, permissive: true do
        on(:grant) { |s, _| s.granted += 1 }
      end

      entry = entry_class.new(action: :clawback, voucher_scheme: target)
      definition = entry_class.standard_ledger_projections.first

      expect(entry.apply_projection!(definition)).to be(false)
      expect(target.granted).to eq(0)
    end

    it "skips and returns false when the if: guard returns false" do
      entry_class.projects_onto :voucher_scheme, mode: :async, if: -> { false } do
        on(:grant) { |s, _| s.granted += 1 }
      end

      entry = entry_class.new(action: :grant, voucher_scheme: target)
      definition = entry_class.standard_ledger_projections.first

      expect(entry.apply_projection!(definition)).to be(false)
      expect(target.granted).to eq(0)
    end

    it "evaluates the if: guard in the entry's instance context" do
      seen = []
      guard = -> { seen << action; true }

      entry_class.projects_onto :voucher_scheme, mode: :async, if: guard do
        on(:grant) { |s, _| s.granted += 1 }
      end

      entry = entry_class.new(action: :grant, voucher_scheme: target)
      definition = entry_class.standard_ledger_projections.first

      entry.apply_projection!(definition)

      expect(seen).to eq([ :grant ])
      expect(target.granted).to eq(1)
    end

    it "skips and returns false when the target is nil" do
      entry_class.projects_onto :customer_profile, mode: :async do
        on(:grant) { |p, _| p.granted += 1 }
      end

      entry = entry_class.new(action: :grant, customer_profile: nil)
      definition = entry_class.standard_ledger_projections.first

      expect(entry.apply_projection!(definition)).to be(false)
    end

    it "raises StandardLedger::Error when the kind column is nil" do
      entry_class.projects_onto :voucher_scheme, mode: :async do
        on(:grant) { |s, _| s.granted += 1 }
      end

      entry = entry_class.new(action: nil, voucher_scheme: target)
      definition = entry_class.standard_ledger_projections.first

      expect {
        entry.apply_projection!(definition)
      }.to raise_error(StandardLedger::Error, /nil kind/)
    end

    it "raises StandardLedger::Error when the class includes Projector but not Entry" do
      projector_only_class = Class.new do
        include StandardLedger::Projector
        attr_accessor :voucher_scheme, :kind
        def self.name = "ProjectorOnlyEntry"
        def initialize(kind:, voucher_scheme:); @kind = kind; @voucher_scheme = voucher_scheme; end
      end
      projector_only_class.projects_onto(:voucher_scheme, mode: :async) { on(:grant) { |s, _| s.granted += 1 } }

      entry = projector_only_class.new(kind: :grant, voucher_scheme: target)
      definition = projector_only_class.standard_ledger_projections.first

      expect { entry.apply_projection!(definition) }
        .to raise_error(StandardLedger::Error, /Entry/)
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

      expect(entry.apply_projection!(definition)).to be(true)
      expect(target.touched).to be(true)
      expect(target.balance).to eq(100)
    end

    # Lock semantics now live in `Modes::Inline` (not in `apply_projection!`)
    # so the projector itself never calls `with_lock`. The `:pessimistic` flag
    # is preserved on the Definition for the mode strategy to read; see
    # `spec/standard_ledger/inline_integration_spec.rb` for end-to-end lock
    # coverage including the lock-spans-save guarantee.
    it "does not call with_lock even when lock: :pessimistic is declared" do
      target_with_spy = double("target", granted: 0)
      allow(target_with_spy).to receive(:granted=)

      entry_class.projects_onto :voucher_scheme, mode: :async, lock: :pessimistic do
        on(:grant) { |s, _| s.granted = (s.granted || 0) + 1 }
      end

      entry = entry_class.new(action: :grant, voucher_scheme: target_with_spy)
      definition = entry_class.standard_ledger_projections.first

      expect(target_with_spy).not_to receive(:with_lock)

      entry.apply_projection!(definition)
    end
  end

  describe ".standard_ledger_projections_for" do
    it "filters projections by mode" do # rubocop:disable RSpec/ExampleLength
      noop = ->(_, _) { nil }
      # We can't use :inline here because Modes::Inline.install! requires
      # AR; :async has no install hook, and :sql's install hook also
      # requires AR — register a :sql definition manually to keep this
      # test plain-Ruby.
      entry_class.projects_onto(:voucher_scheme, mode: :async)    { on(:grant, &noop) }
      entry_class.projects_onto(:customer_profile, mode: :async)  { on(:grant, &noop) }
      entry_class.projects_onto(:order, mode: :async)             { on(:grant, &noop) }
      sql_definition = StandardLedger::Projector::Definition.new(
        target_association: :voucher_scheme,
        mode:               :sql,
        projector_class:    nil,
        handlers:           {},
        guard:              nil,
        lock:               nil,
        permissive:         false,
        recompute_sql:      "UPDATE voucher_schemes SET name = name WHERE id = :target_id",
        options:            {}
      )
      entry_class.standard_ledger_projections = entry_class.standard_ledger_projections + [ sql_definition ]

      async = entry_class.standard_ledger_projections_for(:async)
      sql   = entry_class.standard_ledger_projections_for(:sql)

      expect(async.map(&:target_association)).to eq([ :voucher_scheme, :customer_profile, :order ])
      expect(sql.map(&:target_association)).to eq([ :voucher_scheme ])
    end

    it "returns an empty array for a mode with no registered projections" do
      entry_class.projects_onto :voucher_scheme, mode: :async do
        on(:grant) { |_, _| nil }
      end

      expect(entry_class.standard_ledger_projections_for(:inline)).to eq([])
    end
  end

  describe "Modes::Inline.install! enforcement" do
    it "raises ArgumentError when mode: :inline is declared on a non-AR class" do
      expect {
        entry_class.projects_onto :voucher_scheme, mode: :inline do
          on(:grant) { |s, _| s.granted += 1 }
        end
      }.to raise_error(ArgumentError, /:inline.*ActiveRecord/m)
    end
  end
end
