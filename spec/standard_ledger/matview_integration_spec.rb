# rubocop:disable RSpec/DescribeClass, RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe "StandardLedger matview mode (end-to-end)" do
  # SQLite has no `REFRESH MATERIALIZED VIEW` — these specs mock
  # `connection.execute` to capture the SQL the gem would have issued in
  # Postgres, then assert it matches the expected `REFRESH MATERIALIZED
  # VIEW [CONCURRENTLY]` form. The instrumentation, Result, and DSL
  # paths are exercised against the real gem code.

  # Silence ActiveJob's per-perform logger noise during MatviewRefreshJob specs.
  around do |example|
    prior = ActiveJob::Base.logger
    ActiveJob::Base.logger = Logger.new(IO::NULL)
    example.run
  ensure
    ActiveJob::Base.logger = prior
  end

  before do
    stub_const("UserProfile", Class.new(ActiveRecord::Base) do
      self.table_name = "voucher_schemes"
      has_many :prompt_txns, dependent: nil
    end)

    stub_const("PromptTxn", Class.new(ActiveRecord::Base) do
      self.table_name = "voucher_records"
      include StandardLedger::Entry
      include StandardLedger::Projector

      belongs_to :user_profile, class_name: "UserProfile",
                                foreign_key: "voucher_scheme_id"

      ledger_entry kind:            :action,
                   idempotency_key: :serial_no,
                   scope:           :organisation_id

      projects_onto :user_profile,
                    mode:    :matview,
                    view:    "user_prompt_inventories",
                    refresh: { every: 5.minutes, concurrently: true }
    end)
  end

  after do
    [ PromptTxn, UserProfile ].each { |m| m.unscoped.delete_all }
  end

  describe "DSL registration" do
    it "stores the matview definition on the entry class with view + refresh metadata" do
      definition = PromptTxn.standard_ledger_projections.first
      expect(definition.target_association).to eq(:user_profile)
      expect(definition.mode).to eq(:matview)
      expect(definition.view).to eq("user_prompt_inventories")
      expect(definition.refresh_options[:every]).to eq(5.minutes)
      expect(definition.refresh_options[:concurrently]).to be(true)
    end

    it "appears under standard_ledger_projections_for(:matview)" do
      defs = PromptTxn.standard_ledger_projections_for(:matview)
      expect(defs.size).to eq(1)
      expect(defs.first.view).to eq("user_prompt_inventories")
    end

    it "raises ArgumentError when mode: :matview is declared without view:" do
      expect {
        Class.new(ActiveRecord::Base) do
          self.table_name = "voucher_records"
          include StandardLedger::Entry
          include StandardLedger::Projector

          belongs_to :user_profile, class_name: "UserProfile",
                                    foreign_key: "voucher_scheme_id"

          ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id

          projects_onto :user_profile, mode: :matview, refresh: { every: 5.minutes }
        end
      }.to raise_error(ArgumentError, /requires `view:/)
    end

    it "raises ArgumentError when mode: :matview is declared with a block" do
      expect {
        Class.new(ActiveRecord::Base) do
          self.table_name = "voucher_records"
          include StandardLedger::Entry
          include StandardLedger::Projector

          belongs_to :user_profile, class_name: "UserProfile",
                                    foreign_key: "voucher_scheme_id"

          ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id

          projects_onto :user_profile, mode: :matview, view: "x" do
            on(:grant) { |_, _| nil }
          end
        end
      }.to raise_error(ArgumentError, /does not accept a block/)
    end

    it "accepts mode: :matview without refresh: (host may schedule manually)" do
      klass = Class.new(ActiveRecord::Base) do
        self.table_name = "voucher_records"
        include StandardLedger::Entry
        include StandardLedger::Projector

        belongs_to :user_profile, class_name: "UserProfile",
                                  foreign_key: "voucher_scheme_id"

        ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id

        projects_onto :user_profile, mode: :matview, view: "x"
      end

      definition = klass.standard_ledger_projections.first
      expect(definition.refresh_options).to eq({})
    end

    it "is idempotent — repeated matview registrations don't double-install" do
      # The class created in `before` already declared one matview. Add a
      # second matview projection on the same class and verify
      # `Modes::Matview.install!` is treated as a no-op the second time.
      class_already_installed = PromptTxn.instance_variable_get(:@_standard_ledger_matview_installed)
      expect(class_already_installed).to be(true)

      # Calling install! again should not raise.
      expect { StandardLedger::Modes::Matview.install!(PromptTxn) }.not_to raise_error
    end

    it "does not install an after_create callback on the entry class" do
      # If matview mode installed an after_create callback, every
      # PromptTxn.create! would attempt to refresh — which is wrong.
      # We assert there's no inline-style ivar set; the install! method
      # records its own marker, but no AR callback should be attached.
      expect(PromptTxn.instance_variable_get(:@_standard_ledger_inline_installed)).to be_nil

      executed_sql = []
      allow(ActiveRecord::Base.connection).to receive(:execute).and_wrap_original do |original, sql|
        executed_sql << sql.to_s
        original.call(sql) unless sql.to_s.start_with?("REFRESH MATERIALIZED VIEW")
      end

      profile = UserProfile.create!(name: "P")
      PromptTxn.create!(
        organisation_id: "org-1",
        action:          "grant",
        serial_no:       "v-noop",
        user_profile:    profile
      )

      expect(executed_sql.grep(/REFRESH MATERIALIZED VIEW/)).to be_empty
    end
  end

  describe "StandardLedger.refresh!" do
    let(:executed_sql) { [] }

    before do
      allow(ActiveRecord::Base.connection).to receive(:execute) do |sql|
        executed_sql << sql.to_s
        nil
      end
    end

    it "issues `REFRESH MATERIALIZED VIEW <name>` when concurrently is false" do
      StandardLedger.refresh!("user_prompt_inventories", concurrently: false)
      expect(executed_sql).to eq([ "REFRESH MATERIALIZED VIEW user_prompt_inventories" ])
    end

    it "issues `REFRESH MATERIALIZED VIEW CONCURRENTLY <name>` when concurrently is true" do
      StandardLedger.refresh!("user_prompt_inventories", concurrently: true)
      expect(executed_sql).to eq([ "REFRESH MATERIALIZED VIEW CONCURRENTLY user_prompt_inventories" ])
    end

    it "accepts a Symbol view name and stringifies it in the SQL" do
      StandardLedger.refresh!(:user_prompt_inventories, concurrently: false)
      expect(executed_sql.first).to include("user_prompt_inventories")
    end

    describe "default concurrently behavior" do
      after { StandardLedger.reset! }

      it "uses Config#matview_refresh_strategy = :concurrent (default)" do
        StandardLedger.refresh!("user_prompt_inventories")
        expect(executed_sql.first).to include("CONCURRENTLY")
      end

      it "honors Config#matview_refresh_strategy = :blocking" do
        StandardLedger.configure { |c| c.matview_refresh_strategy = :blocking }
        StandardLedger.refresh!("user_prompt_inventories")
        expect(executed_sql.first).not_to include("CONCURRENTLY")
      end
    end

    it "returns a Result.success" do
      result = StandardLedger.refresh!("user_prompt_inventories", concurrently: true)
      expect(result).to be_success
      expect(result.projections[:refreshed]).to eq([
        { view: "user_prompt_inventories", concurrently: true }
      ])
    end

    describe "view_name validation" do
      it "accepts a valid bare identifier" do
        expect {
          StandardLedger.refresh!("user_prompt_inventories", concurrently: false)
        }.not_to raise_error
      end

      it "accepts a schema-qualified identifier (schema.view)" do
        expect {
          StandardLedger.refresh!("reporting.user_prompt_inventories", concurrently: false)
        }.not_to raise_error
      end

      it "rejects a name containing a semicolon" do
        expect {
          StandardLedger.refresh!("user_prompt_inventories; DROP TABLE users", concurrently: false)
        }.to raise_error(ArgumentError, /valid SQL identifier/)
      end

      it "rejects a name containing a double quote" do
        expect {
          StandardLedger.refresh!('user"_inventories', concurrently: false)
        }.to raise_error(ArgumentError, /valid SQL identifier/)
      end

      it "rejects a name containing a single quote" do
        expect {
          StandardLedger.refresh!("user'_inventories", concurrently: false)
        }.to raise_error(ArgumentError, /valid SQL identifier/)
      end

      it "rejects a name containing -- (SQL comment marker)" do
        expect {
          StandardLedger.refresh!("foo--bar", concurrently: false)
        }.to raise_error(ArgumentError, /valid SQL identifier/)
      end

      it "does not fire the failed notification when validation rejects the name" do
        events = []
        sub = ActiveSupport::Notifications.subscribe("standard_ledger.projection.failed") do |*args|
          events << ActiveSupport::Notifications::Event.new(*args).payload
        end

        expect {
          StandardLedger.refresh!("foo;bar", concurrently: false)
        }.to raise_error(ArgumentError)

        expect(events).to be_empty
      ensure
        ActiveSupport::Notifications.unsubscribe(sub) if sub
      end
    end

    describe "instrumentation" do
      it "fires <prefix>.projection.refreshed with view + duration on success" do
        events = []
        sub = ActiveSupport::Notifications.subscribe("standard_ledger.projection.refreshed") do |*args|
          events << ActiveSupport::Notifications::Event.new(*args).payload
        end

        StandardLedger.refresh!("user_prompt_inventories", concurrently: true)

        expect(events.size).to eq(1)
        payload = events.first
        expect(payload[:view]).to eq("user_prompt_inventories")
        expect(payload[:concurrently]).to be(true)
        expect(payload[:duration_ms]).to be_a(Float)
      ensure
        ActiveSupport::Notifications.unsubscribe(sub) if sub
      end

      it "fires <prefix>.projection.failed and re-raises when execute raises" do
        allow(ActiveRecord::Base.connection).to receive(:execute).and_raise(StandardError, "kaboom")

        events = []
        sub = ActiveSupport::Notifications.subscribe("standard_ledger.projection.failed") do |*args|
          events << ActiveSupport::Notifications::Event.new(*args).payload
        end

        expect {
          StandardLedger.refresh!("user_prompt_inventories", concurrently: true)
        }.to raise_error(StandardError, /kaboom/)

        expect(events.size).to eq(1)
        expect(events.first[:view]).to eq("user_prompt_inventories")
        expect(events.first[:error]).to be_a(StandardError)
      ensure
        ActiveSupport::Notifications.unsubscribe(sub) if sub
      end
    end
  end

  describe "StandardLedger::MatviewRefreshJob" do
    it "delegates to StandardLedger.refresh! with the supplied arguments" do
      expect(StandardLedger).to receive(:refresh!).with("user_prompt_inventories", concurrently: true)
      StandardLedger::MatviewRefreshJob.perform_now("user_prompt_inventories", concurrently: true)
    end

    it "passes through nil concurrently when not supplied" do
      expect(StandardLedger).to receive(:refresh!).with("user_prompt_inventories", concurrently: nil)
      StandardLedger::MatviewRefreshJob.perform_now("user_prompt_inventories")
    end
  end

  describe "StandardLedger.rebuild! for :matview projections" do
    let(:executed_sql) { [] }

    before do
      allow(ActiveRecord::Base.connection).to receive(:execute) do |sql|
        executed_sql << sql.to_s
        nil
      end
    end

    it "triggers refresh! for every :matview projection on the entry class" do
      result = StandardLedger.rebuild!(PromptTxn)

      expect(executed_sql).to eq([ "REFRESH MATERIALIZED VIEW CONCURRENTLY user_prompt_inventories" ])
      expect(result).to be_success
      expect(result.projections[:rebuilt]).to eq([
        {
          target_class: nil,
          target_id:    nil,
          projection:   :user_profile,
          view:         "user_prompt_inventories"
        }
      ])
    end

    it "honors the projection's refresh_options[:concurrently] = false" do
      stub_const("BlockingTxn", Class.new(ActiveRecord::Base) do
        self.table_name = "voucher_records"
        include StandardLedger::Entry
        include StandardLedger::Projector

        belongs_to :user_profile, class_name: "UserProfile",
                                  foreign_key: "voucher_scheme_id"

        ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id

        projects_onto :user_profile,
                      mode:    :matview,
                      view:    "blocking_view",
                      refresh: { every: 5.minutes, concurrently: false }
      end)

      StandardLedger.rebuild!(BlockingTxn)
      expect(executed_sql).to eq([ "REFRESH MATERIALIZED VIEW blocking_view" ])
    end

    it "fires the refreshed notification for each rebuilt matview" do
      events = []
      sub = ActiveSupport::Notifications.subscribe("standard_ledger.projection.refreshed") do |*args|
        events << ActiveSupport::Notifications::Event.new(*args).payload
      end

      StandardLedger.rebuild!(PromptTxn)

      expect(events.size).to eq(1)
      expect(events.first[:view]).to eq("user_prompt_inventories")
    ensure
      ActiveSupport::Notifications.unsubscribe(sub) if sub
    end

    describe "scope arguments are ignored for :matview projections" do
      # Postgres has no partial-refresh primitive — passing target: or
      # target_class: cannot narrow the refresh, so we always issue the
      # full REFRESH MATERIALIZED VIEW. These specs lock that contract.

      it "ignores target: and still issues the full REFRESH for the view" do
        profile = UserProfile.create!(name: "P-scope")

        result = StandardLedger.rebuild!(PromptTxn, target: profile)

        expect(executed_sql).to eq([ "REFRESH MATERIALIZED VIEW CONCURRENTLY user_prompt_inventories" ])
        expect(result).to be_success
      end

      it "ignores target_class: and still issues the full REFRESH for the view" do
        result = StandardLedger.rebuild!(PromptTxn, target_class: UserProfile)

        expect(executed_sql).to eq([ "REFRESH MATERIALIZED VIEW CONCURRENTLY user_prompt_inventories" ])
        expect(result).to be_success
      end
    end

    describe "failure path when refresh raises" do
      it "returns Result.failure with the error message in errors" do
        allow(ActiveRecord::Base.connection).to receive(:execute).and_raise(StandardError, "matview boom")

        result = StandardLedger.rebuild!(PromptTxn)

        expect(result).to be_failure
        expect(result.errors).to include(/matview boom/)
      end
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/ExampleLength, RSpec/MultipleExpectations
