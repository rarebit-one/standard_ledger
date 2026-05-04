# rubocop:disable RSpec/DescribeClass, RSpec/ExampleLength
RSpec.describe "StandardLedger inline mode (end-to-end)" do
  before do
    stub_const("VoucherScheme", Class.new(ActiveRecord::Base) do
      self.table_name = "voucher_schemes"
      has_many :voucher_records, dependent: nil
    end)

    stub_const("CustomerProfile", Class.new(ActiveRecord::Base) do
      self.table_name = "customer_profiles"
      has_many :voucher_records, dependent: nil
    end)

    stub_const("VoucherRecord", Class.new(ActiveRecord::Base) do
      self.table_name = "voucher_records"
      include StandardLedger::Entry
      include StandardLedger::Projector

      belongs_to :voucher_scheme
      belongs_to :customer_profile

      ledger_entry kind:            :action,
                   idempotency_key: :serial_no,
                   scope:           :organisation_id

      projects_onto :voucher_scheme, mode: :inline do
        on(:grant)  { |s, _| s.increment(:granted_vouchers_count) }
        on(:redeem) { |s, _| s.increment(:redeemed_vouchers_count) }
      end

      projects_onto :customer_profile, mode: :inline do
        on(:grant)  { |p, _| p.increment(:granted_vouchers_count) }
        on(:redeem) { |p, _| p.increment(:redeemed_vouchers_count) }
      end
    end)
  end

  after do
    [ VoucherRecord, VoucherScheme, CustomerProfile ].each { |m| m.unscoped.delete_all }
  end

  let(:scheme)  { VoucherScheme.create!(name: "Scheme A") }
  let(:profile) { CustomerProfile.create!(name: "Customer A") }

  describe "StandardLedger.post" do
    it "increments counters on every inline target in one create" do
      result = StandardLedger.post(
        VoucherRecord,
        kind:    "grant",
        targets: { voucher_scheme: scheme, customer_profile: profile },
        attrs:   { organisation_id: "org-1", serial_no: "v-1" }
      )

      expect(result).to be_success
      expect(scheme.reload.granted_vouchers_count).to eq(1)
      expect(profile.reload.granted_vouchers_count).to eq(1)
      expect(result.projections[:inline]).to contain_exactly(:voucher_scheme, :customer_profile)
    end

    it "rolls back the entry and all counter writes when a projection raises" do
      stub_const("ExplodingRecord", Class.new(ActiveRecord::Base) do
        self.table_name = "voucher_records"
        include StandardLedger::Entry
        include StandardLedger::Projector

        belongs_to :voucher_scheme
        belongs_to :customer_profile

        ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id

        projects_onto :voucher_scheme, mode: :inline do
          on(:grant) { |s, _| s.increment(:granted_vouchers_count) }
        end

        projects_onto :customer_profile, mode: :inline do
          on(:grant) { |_, _| raise "kaboom" }
        end
      end)

      expect {
        StandardLedger.post(
          ExplodingRecord,
          kind:    "grant",
          targets: { voucher_scheme: scheme, customer_profile: profile },
          attrs:   { organisation_id: "org-1", serial_no: "v-explode" }
        )
      }.to raise_error(RuntimeError, /kaboom/)

      expect(ExplodingRecord.count).to eq(0)
      expect(scheme.reload.granted_vouchers_count).to eq(0)
      expect(profile.reload.granted_vouchers_count).to eq(0)
    end

    it "returns the original entry on idempotent retry without re-applying projections" do
      applied = []
      sub = ActiveSupport::Notifications.subscribe("standard_ledger.projection.applied") do |*args|
        event = ActiveSupport::Notifications::Event.new(*args)
        applied << event.payload[:projection].target_association
      end

      first = StandardLedger.post(
        VoucherRecord,
        kind: "grant", targets: { voucher_scheme: scheme, customer_profile: profile },
        attrs: { organisation_id: "org-1", serial_no: "v-dup" }
      )
      second = StandardLedger.post(
        VoucherRecord,
        kind: "grant", targets: { voucher_scheme: scheme, customer_profile: profile },
        attrs: { organisation_id: "org-1", serial_no: "v-dup" }
      )

      expect(first.entry.id).to eq(second.entry.id)
      expect(second).to be_idempotent
      expect(scheme.reload.granted_vouchers_count).to eq(1)
      expect(profile.reload.granted_vouchers_count).to eq(1)
      expect(applied).to contain_exactly(:voucher_scheme, :customer_profile)
    ensure
      ActiveSupport::Notifications.unsubscribe(sub) if sub
    end

    it "returns projections[:inline] = [] on idempotent retry" do
      first = StandardLedger.post(
        VoucherRecord,
        kind: "grant", targets: { voucher_scheme: scheme, customer_profile: profile },
        attrs: { organisation_id: "org-1", serial_no: "v-idem-proj" }
      )
      second = StandardLedger.post(
        VoucherRecord,
        kind: "grant", targets: { voucher_scheme: scheme, customer_profile: profile },
        attrs: { organisation_id: "org-1", serial_no: "v-idem-proj" }
      )

      # First call ran both inline projections.
      expect(first.projections[:inline]).to contain_exactly(:voucher_scheme, :customer_profile)

      # Second call hit the idempotent rescue: no after_create fired, so
      # nothing was projected this time around. The result must reflect that.
      expect(second).to be_idempotent
      expect(second.projections[:inline]).to eq([])
    end

    it "excludes guarded projections that skipped from result.projections[:inline]" do
      stub_const("GuardedRecord", Class.new(ActiveRecord::Base) do
        self.table_name = "voucher_records"
        include StandardLedger::Entry
        include StandardLedger::Projector

        belongs_to :voucher_scheme
        belongs_to :customer_profile

        ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id

        # Always-fires projection
        projects_onto :voucher_scheme, mode: :inline do
          on(:grant) { |s, _| s.increment(:granted_vouchers_count) }
        end

        # Guard returns false → projection should be skipped
        projects_onto :customer_profile, mode: :inline, if: -> { false } do
          on(:grant) { |p, _| p.increment(:granted_vouchers_count) }
        end
      end)

      result = StandardLedger.post(
        GuardedRecord,
        kind:    "grant",
        targets: { voucher_scheme: scheme, customer_profile: profile },
        attrs:   { organisation_id: "org-1", serial_no: "v-guarded" }
      )

      expect(result).to be_success
      # Only the unguarded projection ran — the guarded one is absent.
      expect(result.projections[:inline]).to contain_exactly(:voucher_scheme)
      expect(scheme.reload.granted_vouchers_count).to eq(1)
      expect(profile.reload.granted_vouchers_count).to eq(0)
    end
  end

  describe "ActiveSupport::Notifications" do
    let(:created_events) { [] }
    let(:applied_events) { [] }
    let(:failed_events)  { [] }

    around do |example|
      created_sub = ActiveSupport::Notifications.subscribe("standard_ledger.entry.created") do |*args|
        created_events << ActiveSupport::Notifications::Event.new(*args).payload
      end
      applied_sub = ActiveSupport::Notifications.subscribe("standard_ledger.projection.applied") do |*args|
        applied_events << ActiveSupport::Notifications::Event.new(*args).payload
      end
      failed_sub = ActiveSupport::Notifications.subscribe("standard_ledger.projection.failed") do |*args|
        failed_events << ActiveSupport::Notifications::Event.new(*args).payload
      end
      example.run
    ensure
      [ created_sub, applied_sub, failed_sub ].compact.each { |s| ActiveSupport::Notifications.unsubscribe(s) }
    end

    it "fires entry.created with the entry, kind, and targets after commit" do
      StandardLedger.post(
        VoucherRecord,
        kind:    "grant",
        targets: { voucher_scheme: scheme, customer_profile: profile },
        attrs:   { organisation_id: "org-1", serial_no: "v-evt" }
      )

      expect(created_events.size).to eq(1)
      payload = created_events.first
      expect(payload[:entry]).to be_a(VoucherRecord)
      expect(payload[:kind]).to eq("grant")
      expect(payload[:targets]).to include(voucher_scheme: scheme, customer_profile: profile)
    end

    it "fires projection.applied once per inline projection" do
      StandardLedger.post(
        VoucherRecord,
        kind:    "grant",
        targets: { voucher_scheme: scheme, customer_profile: profile },
        attrs:   { organisation_id: "org-1", serial_no: "v-apl" }
      )

      assocs = applied_events.map { |p| p[:projection].target_association }
      expect(assocs).to contain_exactly(:voucher_scheme, :customer_profile)
      expect(applied_events).to all(include(mode: :inline))
      expect(applied_events.first[:duration_ms]).to be_a(Float)
    end

    it "fires projection.failed and rolls back when a handler raises" do
      stub_const("FailingRecord", Class.new(ActiveRecord::Base) do
        self.table_name = "voucher_records"
        include StandardLedger::Entry
        include StandardLedger::Projector

        belongs_to :voucher_scheme
        belongs_to :customer_profile

        ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id

        projects_onto :voucher_scheme, mode: :inline do
          on(:grant) { |_, _| raise "kaboom" }
        end
      end)

      expect {
        StandardLedger.post(
          FailingRecord,
          kind:    "grant",
          targets: { voucher_scheme: scheme, customer_profile: profile },
          attrs:   { organisation_id: "org-1", serial_no: "v-bust" }
        )
      }.to raise_error(RuntimeError, /kaboom/)

      expect(failed_events.size).to eq(1)
      expect(failed_events.first[:error]).to be_a(RuntimeError)
      expect(FailingRecord.count).to eq(0)
    end
  end

  describe "lock: :pessimistic" do
    before do
      stub_const("LockingScheme", Class.new(VoucherScheme) do
        self.table_name = "voucher_schemes"
      end)

      stub_const("LockedRecord", Class.new(ActiveRecord::Base) do
        self.table_name = "voucher_records"
        include StandardLedger::Entry
        include StandardLedger::Projector

        belongs_to :voucher_scheme, class_name: "LockingScheme"

        ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id

        projects_onto :voucher_scheme, mode: :inline, lock: :pessimistic do
          on(:grant) { |s, _| s.increment(:granted_vouchers_count) }
        end
      end)
    end

    it "wraps the projection in target.with_lock" do
      locking_scheme = LockingScheme.create!(name: "Locked")
      with_lock_calls = 0

      allow(locking_scheme).to receive(:with_lock).and_wrap_original do |original, &block|
        with_lock_calls += 1
        original.call(&block)
      end

      # Use the real persisted scheme but route the find through the stub
      allow(LockingScheme).to receive(:find).with(locking_scheme.id).and_return(locking_scheme)

      LockedRecord.create!(
        organisation_id: "org-1",
        action:          "grant",
        serial_no:       "v-lock",
        voucher_scheme:  locking_scheme
      )

      expect(with_lock_calls).to be >= 1
      expect(locking_scheme.reload.granted_vouchers_count).to eq(1)
    end

    # The lock must span both the handler invocation AND the coalesced
    # `target.save!`. An earlier implementation wrapped only
    # `apply_projection!`, releasing the row lock before the save —
    # leaving a window where a concurrent post could read the pre-save
    # row, causing a lost update. This test captures the order of
    # operations and asserts the save lands while inside `with_lock`.
    it "holds the lock through the coalesced save (lock spans save)" do
      locking_scheme = LockingScheme.create!(name: "Locked-Save")

      # Reset and re-instrument: capture the inside_lock state at the
      # moment `save!` is invoked on the target.
      events = []
      allow(locking_scheme).to receive(:with_lock).and_wrap_original do |original, &block|
        events << :with_lock_start
        result = original.call(&block)
        events << :with_lock_end
        result
      end
      allow(locking_scheme).to receive(:save!).and_wrap_original do |original|
        events << :save_called
        original.call
      end
      allow(LockingScheme).to receive(:find).with(locking_scheme.id).and_return(locking_scheme)

      LockedRecord.create!(
        organisation_id: "org-1",
        action:          "grant",
        serial_no:       "v-lock-save",
        voucher_scheme:  locking_scheme
      )

      # The save must land between with_lock_start and with_lock_end.
      start_idx = events.index(:with_lock_start)
      save_idx  = events.index(:save_called)
      end_idx   = events.index(:with_lock_end)

      expect(start_idx).not_to be_nil, "expected with_lock to be entered"
      expect(save_idx).not_to be_nil,  "expected save! to be called for the coalesced UPDATE"
      expect(end_idx).not_to be_nil,   "expected with_lock to exit"
      expect(save_idx).to be > start_idx
      expect(save_idx).to be < end_idx
    end
  end

  describe "multi-counter coalescing" do
    before do
      stub_const("CoalesceScheme", Class.new(ActiveRecord::Base) do
        self.table_name = "voucher_schemes"
      end)

      stub_const("CoalesceRecord", Class.new(ActiveRecord::Base) do
        self.table_name = "voucher_records"
        include StandardLedger::Entry
        include StandardLedger::Projector

        belongs_to :voucher_scheme, class_name: "CoalesceScheme"

        ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id

        projects_onto :voucher_scheme, mode: :inline do
          on(:grant) do |s, _|
            s.increment(:granted_vouchers_count)
            s.increment(:redeemed_vouchers_count)
          end
        end
      end)
    end

    it "issues a single UPDATE for multiple counter increments on the same target" do
      coalesce_scheme = CoalesceScheme.create!(name: "Coalesce")
      update_count = 0

      callback = lambda do |_name, _start, _finish, _id, payload|
        sql = payload[:sql]
        update_count += 1 if sql =~ /UPDATE\s+"voucher_schemes"/i
      end

      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        CoalesceRecord.create!(
          organisation_id: "org-1",
          action:          "grant",
          serial_no:       "v-coal",
          voucher_scheme:  coalesce_scheme
        )
      end

      expect(update_count).to eq(1)
      expect(coalesce_scheme.reload.granted_vouchers_count).to eq(1)
      expect(coalesce_scheme.reload.redeemed_vouchers_count).to eq(1)
    end
  end

  describe "Result interop" do
    # Wipe any host result adapter installed by these examples so it doesn't
    # leak into other examples. The `standard_ledger/rspec` auto-cleanup hook
    # deliberately preserves `Config` between examples (so host initializer
    # configs survive), so specs that *mutate* config in-test must clean up
    # after themselves.
    after { StandardLedger.reset! }

    it "returns StandardLedger::Result by default" do
      result = StandardLedger.post(
        VoucherRecord,
        kind: "grant", targets: { voucher_scheme: scheme, customer_profile: profile },
        attrs: { organisation_id: "org-1", serial_no: "v-default-res" }
      )

      expect(result).to be_a(StandardLedger::Result)
    end

    it "returns the host's Result type when an adapter is configured" do
      host_result_class = Struct.new(:success, :value, :errors, :idempotent, keyword_init: true) do
        def success?; success; end
        def idempotent?; idempotent; end
      end

      StandardLedger.configure do |c|
        c.result_class   = host_result_class
        c.result_adapter = ->(success:, value:, errors:, entry:, idempotent:, projections:) {
          host_result_class.new(success: success, value: value || entry, errors: errors, idempotent: idempotent)
        }
      end

      result = StandardLedger.post(
        VoucherRecord,
        kind: "grant", targets: { voucher_scheme: scheme, customer_profile: profile },
        attrs: { organisation_id: "org-1", serial_no: "v-host-res" }
      )

      expect(result).to be_a(host_result_class)
      expect(result).to be_success
      expect(result).not_to be_idempotent
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/ExampleLength
