# rubocop:disable RSpec/DescribeClass, RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe "StandardLedger sql mode (end-to-end)" do
  let(:scheme)  { VoucherScheme.create!(name: "Scheme A") }
  let(:profile) { CustomerProfile.create!(name: "Customer A") }

  let(:recompute_scheme_counters_sql) do
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
    # voucher_records is wiped via VoucherRecord-the-stub if it was stubbed;
    # otherwise reach the AR base directly through the connection.
    ActiveRecord::Base.connection.execute("DELETE FROM voucher_records")
  end

  def define_sql_record(sql)
    captured_sql = sql
    stub_const("VoucherRecord", Class.new(ActiveRecord::Base) do
      self.table_name = "voucher_records"
      include StandardLedger::Entry
      include StandardLedger::Projector

      belongs_to :voucher_scheme, optional: true
      belongs_to :customer_profile, optional: true

      ledger_entry kind:            :action,
                   idempotency_key: :serial_no,
                   scope:           :organisation_id

      projects_onto :voucher_scheme, mode: :sql do
        recompute captured_sql
      end
    end)
  end

  describe "DSL registration" do
    it "stores a :sql definition with the recompute SQL captured" do
      define_sql_record(recompute_scheme_counters_sql)

      definition = VoucherRecord.standard_ledger_projections.first
      expect(definition.mode).to eq(:sql)
      expect(definition.target_association).to eq(:voucher_scheme)
      expect(definition.projector_class).to be_nil
      expect(definition.handlers).to be_empty
      expect(definition.recompute_sql).to eq(recompute_scheme_counters_sql)
    end

    it "raises ArgumentError when the block declares no recompute clause" do
      expect {
        Class.new(ActiveRecord::Base) do
          self.table_name = "voucher_records"
          include StandardLedger::Entry
          include StandardLedger::Projector
          belongs_to :voucher_scheme, optional: true
          ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id

          projects_onto :voucher_scheme, mode: :sql do
            # nothing
          end
        end
      }.to raise_error(ArgumentError, /requires a `recompute/)
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

          projects_onto :voucher_scheme, mode: :sql, via: projector_class
        end
      }.to raise_error(ArgumentError, /`via:` with mode: :sql/)
    end

    it "raises ArgumentError when the recompute SQL omits :target_id" do
      expect {
        Class.new(ActiveRecord::Base) do
          self.table_name = "voucher_records"
          include StandardLedger::Entry
          include StandardLedger::Projector
          belongs_to :voucher_scheme, optional: true
          ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id

          projects_onto :voucher_scheme, mode: :sql do
            recompute "UPDATE voucher_schemes SET granted_vouchers_count = 0"
          end
        end
      }.to raise_error(ArgumentError, /:target_id/)
    end

    it "registers the after_create callback only once across multiple :sql declarations" do
      stub_const("DoubleSqlRecord", Class.new(ActiveRecord::Base) do
        self.table_name = "voucher_records"
        include StandardLedger::Entry
        include StandardLedger::Projector
        belongs_to :voucher_scheme, optional: true
        belongs_to :customer_profile, optional: true
        ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id

        projects_onto :voucher_scheme, mode: :sql do
          recompute "UPDATE voucher_schemes SET granted_vouchers_count = granted_vouchers_count WHERE id = :target_id"
        end
        projects_onto :customer_profile, mode: :sql do
          recompute "UPDATE customer_profiles SET granted_vouchers_count = granted_vouchers_count WHERE id = :target_id"
        end
      end)

      callbacks = DoubleSqlRecord._create_callbacks.select { |cb|
        cb.kind == :after && cb.filter.is_a?(Proc) && cb.filter.source_location&.first&.end_with?("modes/sql.rb")
      }
      expect(callbacks.size).to eq(1)
    end
  end

  describe "after_create execution" do
    before { define_sql_record(recompute_scheme_counters_sql) }

    it "runs the recompute SQL and updates the target's columns" do
      VoucherRecord.create!(action: "grant",   serial_no: "v-1", organisation_id: "org-1", voucher_scheme: scheme)
      VoucherRecord.create!(action: "grant",   serial_no: "v-2", organisation_id: "org-1", voucher_scheme: scheme)
      VoucherRecord.create!(action: "redeem",  serial_no: "v-3", organisation_id: "org-1", voucher_scheme: scheme)

      scheme.reload
      expect(scheme.granted_vouchers_count).to eq(2)
      expect(scheme.redeemed_vouchers_count).to eq(1)
    end

    it "skips silently when the foreign key is nil" do
      expect {
        VoucherRecord.create!(action: "grant", serial_no: "v-nofk", organisation_id: "org-1", voucher_scheme: nil)
      }.not_to raise_error

      scheme.reload
      expect(scheme.granted_vouchers_count).to eq(0)
    end

    it "honors the if: guard and skips the SQL when it returns false" do
      stub_const("GuardedSqlRecord", Class.new(ActiveRecord::Base) do
        self.table_name = "voucher_records"
        include StandardLedger::Entry
        include StandardLedger::Projector
        belongs_to :voucher_scheme, optional: true
        ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id

        projects_onto :voucher_scheme, mode: :sql, if: -> { false } do
          recompute "UPDATE voucher_schemes SET granted_vouchers_count = 999 WHERE id = :target_id"
        end
      end)

      GuardedSqlRecord.create!(action: "grant", serial_no: "v-guard", organisation_id: "org-1", voucher_scheme: scheme)

      expect(scheme.reload.granted_vouchers_count).to eq(0)
    end

    it "rolls back the entry and the target update when a sibling callback raises" do
      stub_const("BoomSqlRecord", Class.new(ActiveRecord::Base) do
        self.table_name = "voucher_records"
        include StandardLedger::Entry
        include StandardLedger::Projector
        belongs_to :voucher_scheme, optional: true
        ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id

        projects_onto :voucher_scheme, mode: :sql do
          recompute <<~SQL
            UPDATE voucher_schemes SET granted_vouchers_count = granted_vouchers_count + 1
            WHERE id = :target_id
          SQL
        end

        before_create { raise "kaboom" }
      end)

      expect {
        BoomSqlRecord.create!(action: "grant", serial_no: "v-boom", organisation_id: "org-1", voucher_scheme: scheme)
      }.to raise_error(RuntimeError, /kaboom/)

      expect(BoomSqlRecord.count).to eq(0)
      expect(scheme.reload.granted_vouchers_count).to eq(0)
    end
  end

  describe "ActiveSupport::Notifications" do
    let(:applied_events) { [] }
    let(:failed_events)  { [] }

    around do |example|
      applied_sub = ActiveSupport::Notifications.subscribe("standard_ledger.projection.applied") do |*args|
        applied_events << ActiveSupport::Notifications::Event.new(*args).payload
      end
      failed_sub = ActiveSupport::Notifications.subscribe("standard_ledger.projection.failed") do |*args|
        failed_events << ActiveSupport::Notifications::Event.new(*args).payload
      end
      example.run
    ensure
      [ applied_sub, failed_sub ].compact.each { |s| ActiveSupport::Notifications.unsubscribe(s) }
    end

    it "fires projection.applied with mode: :sql, target: nil, and a duration_ms" do
      define_sql_record(recompute_scheme_counters_sql)

      VoucherRecord.create!(action: "grant", serial_no: "v-evt", organisation_id: "org-1", voucher_scheme: scheme)

      expect(applied_events.size).to eq(1)
      payload = applied_events.first
      expect(payload[:mode]).to eq(:sql)
      expect(payload[:target]).to be_nil
      expect(payload[:projection].target_association).to eq(:voucher_scheme)
      expect(payload[:duration_ms]).to be_a(Float)
    end

    it "fires projection.failed and re-raises when the SQL errors" do
      stub_const("BadSqlRecord", Class.new(ActiveRecord::Base) do
        self.table_name = "voucher_records"
        include StandardLedger::Entry
        include StandardLedger::Projector
        belongs_to :voucher_scheme, optional: true
        ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id

        projects_onto :voucher_scheme, mode: :sql do
          recompute "UPDATE non_existent_table SET col = 1 WHERE id = :target_id"
        end
      end)

      expect {
        BadSqlRecord.create!(action: "grant", serial_no: "v-bad", organisation_id: "org-1", voucher_scheme: scheme)
      }.to raise_error(ActiveRecord::StatementInvalid)

      expect(failed_events.size).to eq(1)
      expect(failed_events.first[:error]).to be_a(ActiveRecord::StatementInvalid)
      expect(failed_events.first[:target]).to be_nil
    end
  end

  describe "StandardLedger.rebuild!" do
    before { define_sql_record(recompute_scheme_counters_sql) }

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

    it "replays the recompute SQL for a single target" do
      post_log(scheme: scheme, prefix: "a")

      scheme.update_columns(
        granted_vouchers_count: 0,
        redeemed_vouchers_count: 0,
        consumed_vouchers_count: 0,
        clawed_back_vouchers_count: 0
      )

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
      VoucherScheme.update_all(granted_vouchers_count: 0, redeemed_vouchers_count: 0)

      result = StandardLedger.rebuild!(VoucherRecord)

      expect(result).to be_success
      expect(result.projections[:rebuilt].size).to eq(2)
      expect(scheme.reload.granted_vouchers_count).to eq(1)
      expect(scheme_b.reload.granted_vouchers_count).to eq(1)
      target_ids = result.projections[:rebuilt].map { |p| p[:target_id] }
      expect(target_ids).to contain_exactly(scheme.id, scheme_b.id)
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/ExampleLength, RSpec/MultipleExpectations
