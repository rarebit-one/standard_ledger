# rubocop:disable RSpec/DescribeClass, RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe "StandardLedger trigger mode (end-to-end)" do
  let(:scheme)  { VoucherScheme.create!(name: "Scheme A") }

  # The rebuild SQL the gem will run on `StandardLedger.rebuild!`. The
  # database trigger (host-owned, not under test here) would run
  # equivalent logic on every entry INSERT in production — for the gem's
  # responsibility, only the rebuild path is exercised end-to-end.
  let(:rebuild_scheme_counters_sql) do
    <<~SQL
      UPDATE voucher_schemes SET
        granted_vouchers_count     = (SELECT COUNT(*) FROM voucher_records WHERE voucher_scheme_id = :target_id AND action = 'grant'),
        redeemed_vouchers_count    = (SELECT COUNT(*) FROM voucher_records WHERE voucher_scheme_id = :target_id AND action = 'redeem'),
        consumed_vouchers_count    = (SELECT COUNT(*) FROM voucher_records WHERE voucher_scheme_id = :target_id AND action = 'consume'),
        clawed_back_vouchers_count = (SELECT COUNT(*) FROM voucher_records WHERE voucher_scheme_id = :target_id AND action = 'clawback')
      WHERE id = :target_id
    SQL
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
  end

  after do
    [ VoucherScheme, CustomerProfile ].each { |m| m.unscoped.delete_all }
    ActiveRecord::Base.connection.execute("DELETE FROM voucher_records")
  end

  def define_trigger_record(sql, trigger_name: "voucher_records_apply_to_schemes")
    captured_sql = sql
    captured_name = trigger_name
    stub_const("VoucherRecord", Class.new(ActiveRecord::Base) do
      self.table_name = "voucher_records"
      include StandardLedger::Entry
      include StandardLedger::Projector

      belongs_to :voucher_scheme, optional: true
      belongs_to :customer_profile, optional: true

      ledger_entry kind:            :action,
                   idempotency_key: :serial_no,
                   scope:           :organisation_id

      projects_onto :voucher_scheme, mode: :trigger,
                                     trigger_name: captured_name do
        rebuild_sql captured_sql
      end
    end)
  end

  describe "DSL registration" do
    it "stores a :trigger definition with the trigger_name and rebuild SQL captured" do
      define_trigger_record(rebuild_scheme_counters_sql)

      definition = VoucherRecord.standard_ledger_projections.first
      expect(definition.mode).to eq(:trigger)
      expect(definition.target_association).to eq(:voucher_scheme)
      expect(definition.projector_class).to be_nil
      expect(definition.handlers).to be_empty
      expect(definition.trigger_name).to eq("voucher_records_apply_to_schemes")
      expect(definition.recompute_sql).to eq(rebuild_scheme_counters_sql)
    end

    it "appears under standard_ledger_projections_for(:trigger)" do
      define_trigger_record(rebuild_scheme_counters_sql)

      defs = VoucherRecord.standard_ledger_projections_for(:trigger)
      expect(defs.size).to eq(1)
      expect(defs.first.trigger_name).to eq("voucher_records_apply_to_schemes")
    end

    it "raises ArgumentError when trigger_name: is omitted" do
      expect {
        Class.new(ActiveRecord::Base) do
          self.table_name = "voucher_records"
          include StandardLedger::Entry
          include StandardLedger::Projector
          belongs_to :voucher_scheme, optional: true
          ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id

          projects_onto :voucher_scheme, mode: :trigger do
            rebuild_sql "UPDATE voucher_schemes SET granted_vouchers_count = 0 WHERE id = :target_id"
          end
        end
      }.to raise_error(ArgumentError, /requires `trigger_name:/)
    end

    it "raises ArgumentError when trigger_name: is an empty string" do
      expect {
        Class.new(ActiveRecord::Base) do
          self.table_name = "voucher_records"
          include StandardLedger::Entry
          include StandardLedger::Projector
          belongs_to :voucher_scheme, optional: true
          ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id

          projects_onto :voucher_scheme, mode: :trigger, trigger_name: "" do
            rebuild_sql "UPDATE voucher_schemes SET granted_vouchers_count = 0 WHERE id = :target_id"
          end
        end
      }.to raise_error(ArgumentError, /requires `trigger_name:/)
    end

    it "raises ArgumentError when no block is given" do
      expect {
        Class.new(ActiveRecord::Base) do
          self.table_name = "voucher_records"
          include StandardLedger::Entry
          include StandardLedger::Projector
          belongs_to :voucher_scheme, optional: true
          ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id

          projects_onto :voucher_scheme, mode: :trigger, trigger_name: "x"
        end
      }.to raise_error(ArgumentError, /requires a block with `rebuild_sql/)
    end

    it "raises ArgumentError when the block declares no rebuild_sql clause" do
      expect {
        Class.new(ActiveRecord::Base) do
          self.table_name = "voucher_records"
          include StandardLedger::Entry
          include StandardLedger::Projector
          belongs_to :voucher_scheme, optional: true
          ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id

          projects_onto :voucher_scheme, mode: :trigger, trigger_name: "x" do
            # nothing
          end
        end
      }.to raise_error(ArgumentError, /requires a `rebuild_sql/)
    end

    it "raises ArgumentError when given via:" do
      projector_class = Class.new(StandardLedger::Projection)

      expect {
        Class.new(ActiveRecord::Base) do
          self.table_name = "voucher_records"
          include StandardLedger::Entry
          include StandardLedger::Projector
          belongs_to :voucher_scheme, optional: true
          ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id

          projects_onto :voucher_scheme, mode: :trigger, trigger_name: "x", via: projector_class
        end
      }.to raise_error(ArgumentError, /`via:` with mode: :trigger/)
    end

    it "raises ArgumentError when given lock:" do
      expect {
        Class.new(ActiveRecord::Base) do
          self.table_name = "voucher_records"
          include StandardLedger::Entry
          include StandardLedger::Projector
          belongs_to :voucher_scheme, optional: true
          ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id

          projects_onto :voucher_scheme, mode: :trigger, trigger_name: "x", lock: :pessimistic do
            rebuild_sql "UPDATE voucher_schemes SET granted_vouchers_count = 0 WHERE id = :target_id"
          end
        end
      }.to raise_error(ArgumentError, /`lock:` with mode: :trigger/)
    end

    it "raises ArgumentError when given permissive: true" do
      expect {
        Class.new(ActiveRecord::Base) do
          self.table_name = "voucher_records"
          include StandardLedger::Entry
          include StandardLedger::Projector
          belongs_to :voucher_scheme, optional: true
          ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id

          projects_onto :voucher_scheme, mode: :trigger, trigger_name: "x", permissive: true do
            rebuild_sql "UPDATE voucher_schemes SET granted_vouchers_count = 0 WHERE id = :target_id"
          end
        end
      }.to raise_error(ArgumentError, /`permissive:` with mode: :trigger/)
    end

    it "raises ArgumentError when rebuild_sql is called more than once in the same block" do
      expect {
        Class.new(ActiveRecord::Base) do
          self.table_name = "voucher_records"
          include StandardLedger::Entry
          include StandardLedger::Projector
          belongs_to :voucher_scheme, optional: true
          ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id

          projects_onto :voucher_scheme, mode: :trigger, trigger_name: "x" do
            rebuild_sql "UPDATE voucher_schemes SET granted_vouchers_count = 0 WHERE id = :target_id"
            rebuild_sql "UPDATE voucher_schemes SET granted_vouchers_count = 1 WHERE id = :target_id"
          end
        end
      }.to raise_error(ArgumentError, /rebuild_sql called more than once/)
    end

    it "raises ArgumentError when the rebuild SQL omits :target_id" do
      expect {
        Class.new(ActiveRecord::Base) do
          self.table_name = "voucher_records"
          include StandardLedger::Entry
          include StandardLedger::Projector
          belongs_to :voucher_scheme, optional: true
          ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id

          projects_onto :voucher_scheme, mode: :trigger, trigger_name: "x" do
            rebuild_sql "UPDATE voucher_schemes SET granted_vouchers_count = 0"
          end
        end
      }.to raise_error(ArgumentError, /:target_id/)
    end
  end

  describe "Modes::Trigger.install!" do
    it "does not install an after_create callback" do
      define_trigger_record(rebuild_scheme_counters_sql)

      # The trigger fires from the database. Unlike `:inline` and `:sql`,
      # no Ruby-side `after_create` callback should be wired by trigger
      # registration alone.
      expect(VoucherRecord.instance_variable_get(:@_standard_ledger_inline_installed)).to be_nil
      expect(VoucherRecord.instance_variable_get(:@_standard_ledger_sql_installed)).to be_nil
    end

    it "is a no-op (returns nil) and does not raise on a non-AR object" do
      # The strategy doesn't poke entry_class at all — it's a marker.
      expect { StandardLedger::Modes::Trigger.install!(Object.new) }.not_to raise_error
    end

    it "creating an entry does NOT mutate the target via Ruby — the trigger would in production" do
      define_trigger_record(rebuild_scheme_counters_sql)

      # Without a real Postgres trigger in this SQLite test environment,
      # creating an entry leaves the target untouched. This pins the
      # contract that the gem performs no Ruby-side projection for
      # `:trigger` mode — the trigger is the only thing that updates
      # the target on INSERT in production.
      VoucherRecord.create!(action: "grant", serial_no: "v-1", organisation_id: "org-1", voucher_scheme: scheme)

      expect(scheme.reload.granted_vouchers_count).to eq(0)
    end
  end

  describe "StandardLedger.rebuild!" do
    before { define_trigger_record(rebuild_scheme_counters_sql) }

    let(:scheme_b) { VoucherScheme.create!(name: "Scheme B") }

    def post_log(scheme:, prefix:)
      actions = %w[grant redeem consume clawback]
      actions.each_with_index do |action, i|
        VoucherRecord.create!(
          action: action,
          serial_no: "#{prefix}-#{i}",
          organisation_id: "org-1",
          voucher_scheme: scheme
        )
      end
    end

    it "replays the rebuild SQL for a single target" do
      post_log(scheme: scheme, prefix: "a")

      result = StandardLedger.rebuild!(VoucherRecord, target: scheme)

      expect(result).to be_success
      scheme.reload
      expect(scheme.granted_vouchers_count).to eq(1)
      expect(scheme.redeemed_vouchers_count).to eq(1)
      expect(scheme.consumed_vouchers_count).to eq(1)
      expect(scheme.clawed_back_vouchers_count).to eq(1)
      expect(result.projections[:rebuilt].first).to include(
        target_class: VoucherScheme, target_id: scheme.id, projection: :voucher_scheme
      )
    end

    it "walks every distinct FK in the log when no target: scope is given" do
      post_log(scheme: scheme,   prefix: "a")
      post_log(scheme: scheme_b, prefix: "b")

      result = StandardLedger.rebuild!(VoucherRecord)

      expect(result).to be_success
      expect(result.projections[:rebuilt].size).to eq(2)
      expect(scheme.reload.granted_vouchers_count).to eq(1)
      expect(scheme_b.reload.granted_vouchers_count).to eq(1)
      target_ids = result.projections[:rebuilt].map { |p| p[:target_id] }
      expect(target_ids).to contain_exactly(scheme.id, scheme_b.id)
    end

    it "fires <prefix>.projection.rebuilt with mode: :trigger" do
      post_log(scheme: scheme, prefix: "a")

      events = []
      sub = ActiveSupport::Notifications.subscribe("standard_ledger.projection.rebuilt") do |*args|
        events << ActiveSupport::Notifications::Event.new(*args).payload
      end

      StandardLedger.rebuild!(VoucherRecord, target: scheme)

      expect(events.size).to eq(1)
      expect(events.first[:mode]).to eq(:trigger)
      expect(events.first[:projection]).to eq(:voucher_scheme)
    ensure
      ActiveSupport::Notifications.unsubscribe(sub) if sub
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/ExampleLength, RSpec/MultipleExpectations
