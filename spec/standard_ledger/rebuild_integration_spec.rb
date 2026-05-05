# rubocop:disable RSpec/DescribeClass, RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe "StandardLedger.rebuild! (end-to-end)" do
  # A class-form projector that recomputes the four voucher counters
  # for a scheme by replaying the entry log. This is what hosts will
  # write when they want a projection to be rebuildable from the log.
  let(:scheme) { VoucherScheme.create!(name: "Scheme A") }

  let(:scheme_projector_class) do
    Class.new(StandardLedger::Projection) do
      def apply(scheme, entry)
        column = column_for(entry.action)
        scheme.increment(column) if column
        scheme.save!
      end

      def rebuild(scheme)
        records = VoucherRecord.where(voucher_scheme_id: scheme.id)
        scheme.update!(
          granted_vouchers_count:     records.where(action: "grant").count,
          redeemed_vouchers_count:    records.where(action: "redeem").count,
          consumed_vouchers_count:    records.where(action: "consume").count,
          clawed_back_vouchers_count: records.where(action: "clawback").count
        )
      end

      private

      def column_for(action)
        {
          "grant"    => :granted_vouchers_count,
          "redeem"   => :redeemed_vouchers_count,
          "consume"  => :consumed_vouchers_count,
          "clawback" => :clawed_back_vouchers_count
        }[action.to_s]
      end
    end
  end

  before do
    stub_const("VoucherScheme", Class.new(ActiveRecord::Base) do
      self.table_name = "voucher_schemes"
      has_many :voucher_records, dependent: nil
    end)

    stub_const("CustomerProfile", Class.new(ActiveRecord::Base) do
      self.table_name = "customer_profiles"
      has_many :voucher_records, dependent: nil
    end)

    stub_const("SchemeProjector", scheme_projector_class)

    stub_const("VoucherRecord", Class.new(ActiveRecord::Base) do
      self.table_name = "voucher_records"
      include StandardLedger::Entry
      include StandardLedger::Projector

      belongs_to :voucher_scheme
      belongs_to :customer_profile, optional: true

      ledger_entry kind:            :action,
                   idempotency_key: :serial_no,
                   scope:           :organisation_id

      projects_onto :voucher_scheme, mode: :inline, via: SchemeProjector
    end)
  end

  after do
    [ VoucherRecord, VoucherScheme, CustomerProfile ].each { |m| m.unscoped.delete_all }
  end

  # Insert N entries with action cycled across the four kinds. Each
  # post fires the inline projector, so counters are kept in sync.
  def post_voucher_log(count, scheme: nil, organisation_id: "org-1", prefix: "v")
    actions = %w[grant redeem consume clawback]
    count.times do |i|
      StandardLedger.post(
        VoucherRecord,
        kind:    actions[i % actions.size],
        targets: { voucher_scheme: scheme },
        attrs:   { organisation_id: organisation_id, serial_no: "#{prefix}-#{i}" }
      )
    end
  end

  describe "with a single target" do
    it "rebuilds counters from the entry log after they're truncated" do
      post_voucher_log(50, scheme: scheme)
      scheme.reload

      pre_truncate = scheme.attributes.slice(
        "granted_vouchers_count", "redeemed_vouchers_count",
        "consumed_vouchers_count", "clawed_back_vouchers_count"
      )

      # Sanity: the inline path kept counters in sync as we posted.
      expect(pre_truncate.values.sum).to eq(50)

      scheme.update_columns(
        granted_vouchers_count:     0,
        redeemed_vouchers_count:    0,
        consumed_vouchers_count:    0,
        clawed_back_vouchers_count: 0
      )

      result = StandardLedger.rebuild!(VoucherRecord, target: scheme)

      expect(result).to be_success
      expect(scheme.reload.attributes.slice(
        "granted_vouchers_count", "redeemed_vouchers_count",
        "consumed_vouchers_count", "clawed_back_vouchers_count"
      )).to eq(pre_truncate)

      expect(result.projections[:rebuilt].size).to eq(1)
      expect(result.projections[:rebuilt].first).to include(
        target_class: VoucherScheme, target_id: scheme.id, projection: :voucher_scheme
      )
    end

    it "fires <prefix>.projection.rebuilt once per (target, projection)" do
      post_voucher_log(8, scheme: scheme)
      scheme.update_columns(granted_vouchers_count: 0, redeemed_vouchers_count: 0)

      events = []
      sub = ActiveSupport::Notifications.subscribe("standard_ledger.projection.rebuilt") do |*args|
        events << ActiveSupport::Notifications::Event.new(*args).payload
      end

      StandardLedger.rebuild!(VoucherRecord, target: scheme)

      expect(events.size).to eq(1)
      payload = events.first
      expect(payload[:entry_class]).to eq(VoucherRecord)
      expect(payload[:target]).to eq(scheme)
      expect(payload[:projection]).to eq(:voucher_scheme)
      expect(payload[:mode]).to eq(:inline)
    ensure
      ActiveSupport::Notifications.unsubscribe(sub) if sub
    end
  end

  describe "scoping" do
    let(:scheme_b) { VoucherScheme.create!(name: "Scheme B") }

    it "rebuilds only the requested target when `target:` is given" do
      post_voucher_log(4, scheme: scheme,   prefix: "a")
      post_voucher_log(4, scheme: scheme_b, prefix: "b")

      scheme.update_columns(granted_vouchers_count: 0)
      scheme_b.update_columns(granted_vouchers_count: 0)

      StandardLedger.rebuild!(VoucherRecord, target: scheme)

      expect(scheme.reload.granted_vouchers_count).to eq(1)     # 1 of every 4 is grant
      expect(scheme_b.reload.granted_vouchers_count).to eq(0)   # untouched
    end

    it "rebuilds every row of the class when `target_class:` is given" do
      post_voucher_log(4, scheme: scheme,   prefix: "a")
      post_voucher_log(4, scheme: scheme_b, prefix: "b")

      VoucherScheme.update_all(granted_vouchers_count: 0, redeemed_vouchers_count: 0)

      result = StandardLedger.rebuild!(VoucherRecord, target_class: VoucherScheme)

      expect(result).to be_success
      expect(scheme.reload.granted_vouchers_count).to eq(1)
      expect(scheme_b.reload.granted_vouchers_count).to eq(1)
      target_ids = result.projections[:rebuilt].map { |p| p[:target_id] }
      expect(target_ids).to contain_exactly(scheme.id, scheme_b.id)
    end

    it "rebuilds every projection across every referenced target with no args" do
      post_voucher_log(4, scheme: scheme,   prefix: "a")
      post_voucher_log(4, scheme: scheme_b, prefix: "b")

      VoucherScheme.update_all(granted_vouchers_count: 0, redeemed_vouchers_count: 0)

      result = StandardLedger.rebuild!(VoucherRecord)

      expect(result).to be_success
      expect(result.projections[:rebuilt].size).to eq(2)
      expect(scheme.reload.granted_vouchers_count).to eq(1)
      expect(scheme_b.reload.granted_vouchers_count).to eq(1)
    end

    it "only walks targets whose ids appear in the log" do
      _orphan = VoucherScheme.create!(name: "Orphan, no entries")
      post_voucher_log(4, scheme: scheme, prefix: "a")
      VoucherScheme.update_all(granted_vouchers_count: 0)

      result = StandardLedger.rebuild!(VoucherRecord, target_class: VoucherScheme)

      target_ids = result.projections[:rebuilt].map { |p| p[:target_id] }
      expect(target_ids).to eq([ scheme.id ])
    end

    it "raises ArgumentError when both `target:` and `target_class:` are given" do
      expect {
        StandardLedger.rebuild!(VoucherRecord, target: scheme, target_class: VoucherScheme)
      }.to raise_error(ArgumentError, /at most one of/)
    end
  end

  describe "non-rebuildable projections" do
    it "raises NotRebuildable when the projection is block-form" do
      stub_const("BlockProjectedRecord", Class.new(ActiveRecord::Base) do
        self.table_name = "voucher_records"
        include StandardLedger::Entry
        include StandardLedger::Projector

        belongs_to :voucher_scheme

        ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id

        projects_onto :voucher_scheme, mode: :inline do
          on(:grant) { |s, _| s.increment(:granted_vouchers_count) }
        end
      end)

      expect {
        StandardLedger.rebuild!(BlockProjectedRecord, target: scheme)
      }.to raise_error(StandardLedger::NotRebuildable, /block-form projection/)
    end

    it "raises NotRebuildable when the projector class doesn't override `rebuild`" do
      stub_const("BareProjector", Class.new(StandardLedger::Projection) do
        def apply(target, _entry); target.save!; end
      end)

      stub_const("BareProjectedRecord", Class.new(ActiveRecord::Base) do
        self.table_name = "voucher_records"
        include StandardLedger::Entry
        include StandardLedger::Projector

        belongs_to :voucher_scheme

        ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id

        projects_onto :voucher_scheme, mode: :inline, via: BareProjector
      end)

      expect {
        StandardLedger.rebuild!(BareProjectedRecord, target: scheme)
      }.to raise_error(StandardLedger::NotRebuildable, /not implemented/)
    end

    it "raises Error for modes the rebuild path doesn't yet support" do
      # A projection registered with `mode: :trigger` is enough to
      # exercise the validation path even though :trigger itself isn't
      # wired up yet — `rebuild!` must refuse before invoking any
      # mode-specific machinery.
      definition = StandardLedger::Projector::Definition.new(
        target_association: :voucher_scheme,
        mode:               :trigger,
        projector_class:    SchemeProjector,
        handlers:           {},
        guard:              nil,
        lock:               nil,
        permissive:         false,
        options:            {}
      )

      stub_const("TriggerProjectedRecord", Class.new(ActiveRecord::Base) do
        self.table_name = "voucher_records"
        include StandardLedger::Entry
        include StandardLedger::Projector

        belongs_to :voucher_scheme

        ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id
      end)

      TriggerProjectedRecord.standard_ledger_projections = [ definition ]

      expect {
        StandardLedger.rebuild!(TriggerProjectedRecord, target: scheme)
      }.to raise_error(StandardLedger::Error, /does not yet support mode/)
    end

    it "raises ArgumentError for entry classes without Projector" do
      stub_const("BareEntry", Class.new(ActiveRecord::Base) do
        self.table_name = "voucher_records"
      end)

      expect {
        StandardLedger.rebuild!(BareEntry)
      }.to raise_error(ArgumentError, /does not include StandardLedger::Projector/)
    end

    it "raises ArgumentError when target_class: matches no registered projection" do
      # VoucherRecord projects onto :voucher_scheme — a target_class
      # of CustomerProfile resolves to zero applicable definitions.
      expect {
        StandardLedger.rebuild!(VoucherRecord, target_class: CustomerProfile)
      }.to raise_error(ArgumentError, /no projections matching CustomerProfile/)
    end

    it "raises ArgumentError when target: is an instance whose class isn't a projection target" do
      profile = CustomerProfile.create!(name: "P")
      expect {
        StandardLedger.rebuild!(VoucherRecord, target: profile)
      }.to raise_error(ArgumentError, /no projections matching CustomerProfile/)
    end

    it "raises ArgumentError when no scope is given and the entry class has zero projections" do
      stub_const("ProjectorlessRecord", Class.new(ActiveRecord::Base) do
        self.table_name = "voucher_records"
        include StandardLedger::Entry
        include StandardLedger::Projector

        belongs_to :voucher_scheme

        ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id
      end)

      expect {
        StandardLedger.rebuild!(ProjectorlessRecord)
      }.to raise_error(ArgumentError, /no projections registered/)
    end
  end

  describe "result interop" do
    # The auto-cleanup hook in `standard_ledger/rspec` only clears the
    # thread-local `with_modes` map; it deliberately leaves Config alone so a
    # host's initializer survives between examples. Specs that mutate Config
    # (the host-Result-adapter case below) restore it explicitly here.
    after { StandardLedger.reset! }

    it "returns StandardLedger::Result by default" do
      post_voucher_log(2, scheme: scheme)
      result = StandardLedger.rebuild!(VoucherRecord, target: scheme)
      expect(result).to be_a(StandardLedger::Result)
    end

    it "returns the host's Result type when an adapter is configured" do
      host_result_class = Struct.new(:success, :value, :errors, :projections, keyword_init: true) do
        def success?; success; end
      end

      StandardLedger.configure do |c|
        c.result_class   = host_result_class
        c.result_adapter = ->(success:, value:, errors:, entry:, idempotent:, projections:) {
          host_result_class.new(success: success, value: value || entry, errors: errors, projections: projections)
        }
      end

      post_voucher_log(2, scheme: scheme)
      result = StandardLedger.rebuild!(VoucherRecord, target: scheme)

      expect(result).to be_a(host_result_class)
      expect(result).to be_success
      expect(result.projections[:rebuilt].size).to eq(1)
    end

    it "returns Result.failure(errors:) when the projector raises mid-rebuild" do
      post_voucher_log(2, scheme: scheme)

      stub_const("BoomProjector", Class.new(StandardLedger::Projection) do
        def rebuild(_target); raise "boom from rebuild"; end
      end)

      stub_const("BoomRecord", Class.new(ActiveRecord::Base) do
        self.table_name = "voucher_records"
        include StandardLedger::Entry
        include StandardLedger::Projector

        belongs_to :voucher_scheme

        ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id

        projects_onto :voucher_scheme, mode: :inline, via: BoomProjector
      end)

      result = StandardLedger.rebuild!(BoomRecord, target: scheme)
      expect(result).to be_failure
      expect(result.errors).to include(/boom from rebuild/)
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/ExampleLength, RSpec/MultipleExpectations
