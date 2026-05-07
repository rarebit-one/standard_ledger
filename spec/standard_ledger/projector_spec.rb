RSpec.describe StandardLedger::Projector do
  # The projector unit tests use plain Ruby classes (not ActiveRecord) so we
  # exercise the DSL surface and `apply_projection!` dispatch in isolation
  # from AR callbacks. Most modes' install hooks require AR — the fixture
  # class below stubs out `after_create` so `Modes::Inline.install!` (which
  # is the generic block-and-via-form mode) can wire its hook. The callback
  # never actually fires in these unit tests; they invoke `apply_projection!`
  # directly. We use `:inline` here because it's the only mode whose
  # registration path accepts both block- and `via:`-form projectors —
  # `:async` rejects blocks for retry-safety, `:sql` is recompute-only,
  # `:matview` is schedule-only, and `:trigger` lands in its own PR.
  def fresh_entry_class
    Class.new do
      include StandardLedger::Entry
      include StandardLedger::Projector

      # Stub the AR transactional callback so `Modes::Inline.install!` can
      # wire its hook without requiring a real AR connection. The callback
      # never actually fires in these unit tests.
      def self.after_create(*); end

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

      entry_class.projects_onto :order, mode: :inline, via: projector_class

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
        entry_class.projects_onto :order, mode: :inline, via: projector_class do
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

    it "raises ArgumentError when permissive: true is combined with via:" do
      projector_class = Class.new(StandardLedger::Projection)

      expect {
        entry_class.projects_onto :order, mode: :inline, via: projector_class, permissive: true
      }.to raise_error(ArgumentError, /permissive:.*only meaningful with the block form/)
    end
  end

  describe "#apply_projection!" do
    let(:target) { Struct.new(:granted, :redeemed, :touched, :balance).new(0, 0, false, 0) }

    it "dispatches to the right handler by kind and returns true" do
      entry_class.projects_onto :voucher_scheme, mode: :inline do
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
      entry_class.projects_onto :voucher_scheme, mode: :inline do
        on(:grant) { |s, _| s.granted += 1 }
      end

      entry = entry_class.new(action: "grant", voucher_scheme: target)
      definition = entry_class.standard_ledger_projections.first

      entry.apply_projection!(definition)

      expect(target.granted).to eq(1)
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

    it "skips silently and returns false when permissive: true but no wildcard registered" do
      entry_class.projects_onto :voucher_scheme, mode: :inline, permissive: true do
        on(:grant) { |s, _| s.granted += 1 }
      end

      entry = entry_class.new(action: :clawback, voucher_scheme: target)
      definition = entry_class.standard_ledger_projections.first

      expect(entry.apply_projection!(definition)).to be(false)
      expect(target.granted).to eq(0)
    end

    it "skips and returns false when the if: guard returns false" do
      entry_class.projects_onto :voucher_scheme, mode: :inline, if: -> { false } do
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

      entry_class.projects_onto :voucher_scheme, mode: :inline, if: guard do
        on(:grant) { |s, _| s.granted += 1 }
      end

      entry = entry_class.new(action: :grant, voucher_scheme: target)
      definition = entry_class.standard_ledger_projections.first

      entry.apply_projection!(definition)

      expect(seen).to eq([ :grant ])
      expect(target.granted).to eq(1)
    end

    it "skips and returns false when the target is nil" do
      entry_class.projects_onto :customer_profile, mode: :inline do
        on(:grant) { |p, _| p.granted += 1 }
      end

      entry = entry_class.new(action: :grant, customer_profile: nil)
      definition = entry_class.standard_ledger_projections.first

      expect(entry.apply_projection!(definition)).to be(false)
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

    it "raises StandardLedger::Error when the class includes Projector but not Entry" do
      projector_only_class = Class.new do
        include StandardLedger::Projector
        # Stub the AR transactional callback so install! doesn't bail.
        def self.after_create(*); end
        attr_accessor :voucher_scheme, :kind
        def self.name = "ProjectorOnlyEntry"
        def initialize(kind:, voucher_scheme:); @kind = kind; @voucher_scheme = voucher_scheme; end
      end
      projector_only_class.projects_onto(:voucher_scheme, mode: :inline) { on(:grant) { |s, _| s.granted += 1 } }

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

      entry_class.projects_onto :order, mode: :inline, via: projector_class

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

      entry_class.projects_onto :voucher_scheme, mode: :inline, lock: :pessimistic do
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
      # The fixture stubs `after_create` so :inline registrations install
      # without AR. :sql's install hook also requires AR; we register a
      # :sql definition manually to keep this test plain-Ruby.
      entry_class.projects_onto(:voucher_scheme, mode: :inline)    { on(:grant, &noop) }
      entry_class.projects_onto(:customer_profile, mode: :inline)  { on(:grant, &noop) }
      entry_class.projects_onto(:order, mode: :inline)             { on(:grant, &noop) }
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

      inline = entry_class.standard_ledger_projections_for(:inline)
      sql    = entry_class.standard_ledger_projections_for(:sql)

      expect(inline.map(&:target_association)).to eq([ :voucher_scheme, :customer_profile, :order ])
      expect(sql.map(&:target_association)).to eq([ :voucher_scheme ])
    end

    it "returns an empty array for a mode with no registered projections" do
      entry_class.projects_onto :voucher_scheme, mode: :inline do
        on(:grant) { |_, _| nil }
      end

      expect(entry_class.standard_ledger_projections_for(:async)).to eq([])
    end
  end

  describe "Modes::Inline.install! enforcement" do
    it "raises ArgumentError when mode: :inline is declared on a non-AR class" do
      # Local fixture without the `after_create` stub — bypass the
      # outer fresh_entry_class so install! sees a non-AR class.
      non_ar_class = Class.new do
        include StandardLedger::Entry
        include StandardLedger::Projector
        ledger_entry kind: :action
        attr_accessor :voucher_scheme, :action
      end
      expect {
        non_ar_class.projects_onto :voucher_scheme, mode: :inline do
          on(:grant) { |s, _| s.granted += 1 }
        end
      }.to raise_error(ArgumentError, /:inline.*ActiveRecord/m)
    end
  end

  describe "counters: shortcut for :inline" do
    # Sugar for the most common :inline shape — a kind => counter-column
    # mapping. The gem synthesises `on(kind) { |t, _| t.class.increment_counter(col, t.id) }`
    # per entry: direct UPDATE (the class-method form) so sibling-entry
    # creates within one transaction don't lose updates against stale
    # cached reads.
    it "synthesises one increment_counter handler per kind" do
      entry_class = fresh_entry_class
      definition = entry_class.projects_onto :voucher_scheme,
                                             mode: :inline,
                                             counters: {
                                               grant: :granted_count,
                                               redeem: :redeemed_count
                                             }

      expect(definition.handlers.keys).to contain_exactly(:grant, :redeem)
    end

    it "rejects `counters:` with a non-:inline mode" do
      entry_class = fresh_entry_class
      expect {
        entry_class.projects_onto :voucher_scheme,
                                  mode: :async,
                                  counters: { grant: :granted_count },
                                  via: Class.new(StandardLedger::Projection)
      }.to raise_error(ArgumentError, /counters:.*:inline-only/m)
    end

    it "rejects `counters:` together with a block" do
      entry_class = fresh_entry_class
      expect {
        entry_class.projects_onto(:voucher_scheme,
                                  mode: :inline,
                                  counters: { grant: :granted_count }) { on(:grant) { } }
      }.to raise_error(ArgumentError, /counters:.*block/m)
    end

    it "validates the counters hash shape" do
      entry_class = fresh_entry_class
      expect {
        entry_class.projects_onto :voucher_scheme,
                                  mode: :inline,
                                  counters: { "grant" => :granted_count }
      }.to raise_error(ArgumentError, /Symbol kind => Symbol column/)
    end
  end

  describe "rebuild_sql: keyword for :trigger" do
    it "accepts rebuild_sql as a keyword (no block needed)" do
      entry_class = fresh_entry_class
      definition = entry_class.projects_onto :voucher_scheme,
                                             mode: :trigger,
                                             trigger_name: "vr_after_insert_tr",
                                             rebuild_sql: "UPDATE schemes SET c = 1 WHERE id = :target_id"

      expect(definition.mode).to eq(:trigger)
      expect(definition.trigger_name).to eq("vr_after_insert_tr")
      expect(definition.recompute_sql).to include(":target_id")
    end

    it "rejects rebuild_sql: together with a block" do
      entry_class = fresh_entry_class
      expect {
        entry_class.projects_onto(:voucher_scheme,
                                  mode: :trigger,
                                  trigger_name: "tr",
                                  rebuild_sql: "UPDATE schemes SET c = 1 WHERE id = :target_id") do
          rebuild_sql "UPDATE schemes SET c = 2 WHERE id = :target_id"
        end
      }.to raise_error(ArgumentError, /both `rebuild_sql:` and a block/)
    end
  end

  describe "mode: :manual" do
    let(:projector_class) do
      Class.new(StandardLedger::Projection) do
        def apply(target, entry)
          target.granted += 1
        end

        def rebuild(target)
          target.granted = 0
        end
      end
    end

    it "registers the definition without installing any after_create callback" do
      entry_class = fresh_entry_class
      expect(entry_class).not_to receive(:after_create)

      definition = entry_class.projects_onto :voucher_scheme,
                                             mode: :manual,
                                             via: projector_class

      expect(definition.mode).to eq(:manual)
      expect(definition.projector_class).to eq(projector_class)
      expect(entry_class.standard_ledger_projections_for(:manual)).to contain_exactly(definition)
    end

    it "lets host code dispatch the projector via apply_projection!" do
      entry_class = fresh_entry_class
      definition = entry_class.projects_onto :voucher_scheme, mode: :manual, via: projector_class

      scheme = Struct.new(:granted).new(0)
      entry  = entry_class.new(action: :grant, voucher_scheme: scheme)

      expect(entry.apply_projection!(definition)).to be(true)
      expect(scheme.granted).to eq(1)
    end

    it "rejects a block (manual mode has no per-kind handlers)" do
      entry_class = fresh_entry_class
      expect {
        entry_class.projects_onto(:voucher_scheme, mode: :manual, via: projector_class) do
          on(:grant) { |_, _| nil }
        end
      }.to raise_error(ArgumentError, /:manual does not accept a block/)
    end

    it "requires `via: ProjectorClass`" do
      entry_class = fresh_entry_class
      expect {
        entry_class.projects_onto :voucher_scheme, mode: :manual
      }.to raise_error(ArgumentError, /:manual requires `via: ProjectorClass`/)
    end

    it "rejects `lock:` (host owns the dispatch boundary)" do
      entry_class = fresh_entry_class
      expect {
        entry_class.projects_onto :voucher_scheme,
                                  mode: :manual,
                                  via: projector_class,
                                  lock: :pessimistic
      }.to raise_error(ArgumentError, /lock:.*manual/m)
    end

    it "rejects `permissive: true` (no per-kind handlers to fall back from)" do
      entry_class = fresh_entry_class
      expect {
        entry_class.projects_onto :voucher_scheme,
                                  mode: :manual,
                                  via: projector_class,
                                  permissive: true
      }.to raise_error(ArgumentError, /permissive:.*manual/m)
    end

    it "honours an `if:` guard when host code dispatches via apply_projection!" do
      entry_class = fresh_entry_class
      definition = entry_class.projects_onto :voucher_scheme,
                                             mode: :manual,
                                             via: projector_class,
                                             if: -> { false }

      scheme = Struct.new(:granted).new(0)
      entry  = entry_class.new(action: :grant, voucher_scheme: scheme)

      expect(entry.apply_projection!(definition)).to be(false)
      expect(scheme.granted).to eq(0)
    end
  end

  describe "counters: shortcut handler invocation" do
    # Beyond the registration-shape tests above: the synthesised lambda must
    # actually call increment_counter with the right column + id when the
    # entry's after_create fires. Stub the AR-class side and verify the
    # call shape end-to-end.
    let(:scheme_class) do
      Class.new do
        def self.name = "FakeScheme"
        def initialize(id) = (@id = id)
        attr_reader :id

        # Track increment_counter invocations on the class.
        def self.calls = @calls ||= []
        def self.increment_counter(col, id) = calls << [ col, id ]
        def self.reset_calls = @calls = []
      end
    end

    it "synthesises handlers that invoke `increment_counter` with (column, target.id)" do
      entry_class = fresh_entry_class
      definition = entry_class.projects_onto :voucher_scheme,
                                             mode: :inline,
                                             counters: {
                                               grant:  :granted_count,
                                               redeem: :redeemed_count
                                             }

      target = scheme_class.new(42)
      scheme_class.reset_calls

      entry = entry_class.new(action: :grant, voucher_scheme: target)
      entry.apply_projection!(definition)

      expect(scheme_class.calls).to eq([ [ :granted_count, 42 ] ])
    end

    it "captures a fresh column binding per synthesised handler (no loop-variable aliasing)" do
      counters = { grant: :granted_count, redeem: :redeemed_count,
                   consume: :consumed_count, clawback: :clawed_back_count }
      entry_class = fresh_entry_class
      definition = entry_class.projects_onto :voucher_scheme, mode: :inline, counters: counters

      target = scheme_class.new(7)

      counters.each do |kind, expected_column|
        scheme_class.reset_calls
        entry_class.new(action: kind, voucher_scheme: target).apply_projection!(definition)
        expect(scheme_class.calls).to eq([ [ expected_column, 7 ] ])
      end
    end
  end
end
