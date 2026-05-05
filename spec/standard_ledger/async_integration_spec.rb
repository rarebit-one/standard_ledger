require "active_job/test_helper"
require "minitest/assertions"

# rubocop:disable RSpec/DescribeClass, RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/MultipleMemoizedHelpers, RSpec/AnyInstance
RSpec.describe "StandardLedger async mode (end-to-end)" do
  # ActiveJob::TestHelper's `perform_enqueued_jobs` block form delegates
  # through `_assert_nothing_raised_or_warn`, which lives in
  # `ActiveSupport::Testing::Assertions` and ultimately calls Minitest's
  # `assert_nothing_raised`. RSpec doesn't ship Minitest assertions, so
  # we mix `Minitest::Assertions` in here. This is the same pattern
  # rspec-rails uses to bridge the two.
  include Minitest::Assertions
  include ActiveJob::TestHelper

  # `assert_nothing_raised` reads `assertions` (a counter) and bumps it.
  # Minitest tracks this on the test instance; provide a no-op accessor
  # so RSpec example instances don't blow up on the missing method.
  attr_accessor :assertions

  # Class-form projector that recomputes the granted_vouchers_count by
  # replaying the entry log inside `apply` — the canonical idempotent-
  # under-retry shape for `:async` projectors.
  let(:scheme_projector_class) do
    Class.new(StandardLedger::Projection) do
      def apply(scheme, _entry)
        records = VoucherRecord.where(voucher_scheme_id: scheme.id)
        scheme.update!(
          granted_vouchers_count:     records.where(action: "grant").count,
          redeemed_vouchers_count:    records.where(action: "redeem").count,
          consumed_vouchers_count:    records.where(action: "consume").count,
          clawed_back_vouchers_count: records.where(action: "clawback").count
        )
      end

      def rebuild(scheme)
        apply(scheme, nil)
      end
    end
  end

  # Companion projector for the multi-target fan-out spec — same shape,
  # different target table.
  let(:profile_projector_class) do
    Class.new(StandardLedger::Projection) do
      def apply(profile, _entry)
        records = VoucherRecord.where(customer_profile_id: profile.id)
        profile.update!(
          granted_vouchers_count: records.where(action: "grant").count
        )
      end
    end
  end

  let(:scheme)  { VoucherScheme.create!(name: "Scheme A") }
  let(:profile) { CustomerProfile.create!(name: "Customer A") }

  # Quiet ActiveJob's per-perform logger noise — the integration specs
  # exercise enqueue + perform paths and the default logger spams stdout.
  # Also force the test queue adapter so jobs don't run inline.
  around do |example|
    prior = ActiveJob::Base.logger
    ActiveJob::Base.logger = Logger.new(IO::NULL)
    queue_adapter_was = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    example.run
  ensure
    ActiveJob::Base.queue_adapter = queue_adapter_was
    ActiveJob::Base.logger = prior
  end

  before do
    self.assertions = 0

    stub_const("VoucherScheme", Class.new(ActiveRecord::Base) do
      self.table_name = "voucher_schemes"
      has_many :voucher_records, dependent: nil
    end)

    stub_const("CustomerProfile", Class.new(ActiveRecord::Base) do
      self.table_name = "customer_profiles"
      has_many :voucher_records, dependent: nil
    end)

    stub_const("Async::VoucherSchemeProjector", scheme_projector_class)
    stub_const("Async::CustomerProfileProjector", profile_projector_class)

    stub_const("VoucherRecord", Class.new(ActiveRecord::Base) do
      self.table_name = "voucher_records"
      include StandardLedger::Entry
      include StandardLedger::Projector

      belongs_to :voucher_scheme, optional: true
      belongs_to :customer_profile, optional: true

      ledger_entry kind:            :action,
                   idempotency_key: :serial_no,
                   scope:           :organisation_id

      projects_onto :voucher_scheme, mode: :async, via: Async::VoucherSchemeProjector
    end)
  end

  after do
    [ VoucherRecord, VoucherScheme, CustomerProfile ].each { |m| m.unscoped.delete_all }
    clear_enqueued_jobs
    clear_performed_jobs
  end

  describe "DSL registration" do
    it "stores an :async definition with via: captured and no handlers" do
      definition = VoucherRecord.standard_ledger_projections.first

      expect(definition.mode).to eq(:async)
      expect(definition.target_association).to eq(:voucher_scheme)
      expect(definition.projector_class).to eq(Async::VoucherSchemeProjector)
      expect(definition.handlers).to be_empty
      expect(definition.recompute_sql).to be_nil
      expect(definition.view).to be_nil
    end

    it "raises ArgumentError when given a block" do
      expect {
        Class.new(ActiveRecord::Base) do
          self.table_name = "voucher_records"
          include StandardLedger::Entry
          include StandardLedger::Projector
          belongs_to :voucher_scheme, optional: true
          ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id

          projects_onto :voucher_scheme, mode: :async do
            on(:grant) { |s, _| s.increment(:granted_vouchers_count) }
          end
        end
      }.to raise_error(ArgumentError, /:async mode does not accept a block|does not accept a block/)
    end

    it "raises ArgumentError when via: is missing" do
      expect {
        Class.new(ActiveRecord::Base) do
          self.table_name = "voucher_records"
          include StandardLedger::Entry
          include StandardLedger::Projector
          belongs_to :voucher_scheme, optional: true
          ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id

          projects_onto :voucher_scheme, mode: :async
        end
      }.to raise_error(ArgumentError, /requires `via: ProjectorClass`/)
    end

    it "raises ArgumentError when permissive: true is supplied" do
      projector = scheme_projector_class
      expect {
        Class.new(ActiveRecord::Base) do
          self.table_name = "voucher_records"
          include StandardLedger::Entry
          include StandardLedger::Projector
          belongs_to :voucher_scheme, optional: true
          ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id

          projects_onto :voucher_scheme, mode: :async, via: projector, permissive: true
        end
      }.to raise_error(ArgumentError, /permissive/)
    end
  end

  describe "after_create_commit enqueue" do
    it "enqueues ProjectionJob with the entry and target_association string" do
      StandardLedger.post(
        VoucherRecord,
        kind:    "grant",
        targets: { voucher_scheme: scheme },
        attrs:   { organisation_id: "org-1", serial_no: "v-async-1" }
      )

      expect(enqueued_jobs.size).to eq(1)
      job = enqueued_jobs.first
      expect(job["job_class"]).to eq("StandardLedger::ProjectionJob")
      # Args[0] is the GlobalID-serialized entry, args[1] is the target_association string.
      expect(job["arguments"][1]).to eq("voucher_scheme")
    end

    it "fans out to one job per (entry, target_association) for multi-target async projections" do
      stub_const("MultiTargetRecord", Class.new(ActiveRecord::Base) do
        self.table_name = "voucher_records"
        include StandardLedger::Entry
        include StandardLedger::Projector

        belongs_to :voucher_scheme
        belongs_to :customer_profile

        ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id

        projects_onto :voucher_scheme, mode: :async, via: Async::VoucherSchemeProjector
        projects_onto :customer_profile, mode: :async, via: Async::CustomerProfileProjector
      end)

      StandardLedger.post(
        MultiTargetRecord,
        kind:    "grant",
        targets: { voucher_scheme: scheme, customer_profile: profile },
        attrs:   { organisation_id: "org-1", serial_no: "v-async-multi" }
      )

      expect(enqueued_jobs.size).to eq(2)
      target_assocs = enqueued_jobs.map { |j| j["arguments"][1] }
      expect(target_assocs).to contain_exactly("voucher_scheme", "customer_profile")
    end

    it "skips enqueue when the target FK is nil at post time" do
      stub_const("NilTargetRecord", Class.new(ActiveRecord::Base) do
        self.table_name = "voucher_records"
        include StandardLedger::Entry
        include StandardLedger::Projector

        belongs_to :voucher_scheme, optional: true

        ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id

        projects_onto :voucher_scheme, mode: :async, via: Async::VoucherSchemeProjector
      end)

      StandardLedger.post(
        NilTargetRecord,
        kind:  "grant",
        attrs: { organisation_id: "org-1", serial_no: "v-async-nil" }
      )

      expect(enqueued_jobs).to be_empty
    end
  end

  describe "ProjectionJob#perform" do
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

    it "runs the projector inside with_lock and updates the target" do
      with_lock_calls = 0
      allow_any_instance_of(VoucherScheme).to receive(:with_lock).and_wrap_original do |original, &block|
        with_lock_calls += 1
        original.call(&block)
      end

      perform_enqueued_jobs do
        StandardLedger.post(
          VoucherRecord,
          kind:    "grant",
          targets: { voucher_scheme: scheme },
          attrs:   { organisation_id: "org-1", serial_no: "v-async-perform" }
        )
      end

      expect(with_lock_calls).to be >= 1
      expect(scheme.reload.granted_vouchers_count).to eq(1)
    end

    it "fires <prefix>.projection.applied with mode: :async, attempt: 1 on success" do
      perform_enqueued_jobs do
        StandardLedger.post(
          VoucherRecord,
          kind:    "grant",
          targets: { voucher_scheme: scheme },
          attrs:   { organisation_id: "org-1", serial_no: "v-async-evt" }
        )
      end

      expect(applied_events.size).to eq(1)
      payload = applied_events.first
      expect(payload[:mode]).to eq(:async)
      expect(payload[:projection]).to eq(:voucher_scheme)
      expect(payload[:attempt]).to eq(1)
      expect(payload[:duration_ms]).to be_a(Float)
    end

    it "fires projection.failed with attempt counter, then ActiveJob retries up to default_async_retries" do
      stub_const("FailingProjector", Class.new(StandardLedger::Projection) do
        def apply(_target, _entry)
          raise "kaboom"
        end
      end)

      stub_const("FailingRecord", Class.new(ActiveRecord::Base) do
        self.table_name = "voucher_records"
        include StandardLedger::Entry
        include StandardLedger::Projector

        belongs_to :voucher_scheme

        ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id

        projects_onto :voucher_scheme, mode: :async, via: FailingProjector
      end)

      # Cap retries low so the test runs fast; ProjectionJob reads the
      # config at perform time so this takes effect immediately.
      StandardLedger.config.default_async_retries = 2
      begin
        StandardLedger.post(
          FailingRecord,
          kind:    "grant",
          targets: { voucher_scheme: scheme },
          attrs:   { organisation_id: "org-1", serial_no: "v-async-fail" }
        )

        # Manually drain the queue until empty. Each call to
        # `perform_enqueued_jobs` only flushes the snapshot present at
        # call time — when the job re-enqueues itself for retry, the
        # next iteration picks that up. After `default_async_retries`
        # attempts the rescue handler re-raises and propagates out.
        last_error = nil
        loop do
          break if enqueued_jobs.empty?
          begin
            perform_enqueued_jobs
          rescue RuntimeError => e
            last_error = e
            break
          end
        end

        expect(last_error).to be_a(RuntimeError)
        expect(last_error.message).to match(/kaboom/)

        expect(failed_events).not_to be_empty
        expect(failed_events.first[:mode]).to eq(:async)
        expect(failed_events.first[:projection]).to eq(:voucher_scheme)
        expect(failed_events.first[:error]).to be_a(RuntimeError)
        expect(failed_events.first[:attempt]).to be >= 1
        expect(failed_events.first[:duration_ms]).to be_a(Float)
        # Each failure attempt fires its own event; we should see one
        # per attempt (up to the configured cap).
        expect(failed_events.size).to be >= 2
        expect(failed_events.last[:attempt]).to be > failed_events.first[:attempt]
      ensure
        StandardLedger.config.default_async_retries = 3
      end
    end

    it "skips silently inside the job when the target FK becomes nil before perform" do
      # First, post + perform a normal job to seed the projector path so
      # the applied subscriber sees baseline behavior.
      result = nil
      perform_enqueued_jobs do
        result = StandardLedger.post(
          VoucherRecord,
          kind:    "grant",
          targets: { voucher_scheme: scheme },
          attrs:   { organisation_id: "org-1", serial_no: "v-async-niljob" }
        )
      end
      expect(applied_events.size).to eq(1)
      applied_events.clear

      # Now: simulate the entry's FK being unset between commit and
      # dequeue. The job's `target = entry.public_send(...)` returns nil
      # and the job returns early without raising or emitting `applied`.
      entry = result.entry
      entry.class.where(id: entry.id).update_all(voucher_scheme_id: nil)
      entry.reload

      StandardLedger::ProjectionJob.perform_now(entry, "voucher_scheme")

      expect(applied_events).to be_empty
      expect(failed_events).to be_empty
    end
  end

  describe "with_modes(EntryClass => :inline) override" do
    it "runs the projection synchronously without enqueuing a job" do
      with_modes(VoucherRecord => :inline) do
        StandardLedger.post(
          VoucherRecord,
          kind:    "grant",
          targets: { voucher_scheme: scheme },
          attrs:   { organisation_id: "org-1", serial_no: "v-override" }
        )

        # No job was enqueued.
        expect(enqueued_jobs).to be_empty

        # Side effect ran inline — the projection updated the counter
        # before with_modes returned.
        expect(scheme.reload.granted_vouchers_count).to eq(1)
      end
    end

    it "fires projection.applied with mode: :async, attempt: 1 in the inline override path" do
      events = []
      sub = ActiveSupport::Notifications.subscribe("standard_ledger.projection.applied") do |*args|
        events << ActiveSupport::Notifications::Event.new(*args).payload
      end

      with_modes(VoucherRecord => :inline) do
        StandardLedger.post(
          VoucherRecord,
          kind:    "grant",
          targets: { voucher_scheme: scheme },
          attrs:   { organisation_id: "org-1", serial_no: "v-override-evt" }
        )
      end

      expect(events.size).to eq(1)
      expect(events.first[:mode]).to eq(:async)
      expect(events.first[:attempt]).to eq(1)
    ensure
      ActiveSupport::Notifications.unsubscribe(sub) if sub
    end
  end

  describe "rebuild! support" do
    it "rebuilds an :async projection by calling projector_class.new.rebuild(target)" do
      perform_enqueued_jobs do
        4.times do |i|
          StandardLedger.post(
            VoucherRecord,
            kind:    "grant",
            targets: { voucher_scheme: scheme },
            attrs:   { organisation_id: "org-1", serial_no: "v-rb-#{i}" }
          )
        end
      end

      expect(scheme.reload.granted_vouchers_count).to eq(4)

      # Drift the counters; verify rebuild! restores them via the
      # projector's `rebuild(target)` path.
      scheme.update_columns(granted_vouchers_count: 0)

      result = StandardLedger.rebuild!(VoucherRecord, target: scheme)

      expect(result).to be_success
      expect(scheme.reload.granted_vouchers_count).to eq(4)
      expect(result.projections[:rebuilt].size).to eq(1)
      expect(result.projections[:rebuilt].first).to include(
        target_class: VoucherScheme, target_id: scheme.id, projection: :voucher_scheme
      )
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/MultipleMemoizedHelpers, RSpec/AnyInstance
