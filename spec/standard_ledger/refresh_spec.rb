# rubocop:disable RSpec/DescribeClass, RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe "StandardLedger.refresh!" do
  # SQLite has no `REFRESH MATERIALIZED VIEW` — these specs stub
  # `connection.execute` / `connection.select_one` to capture the SQL the gem
  # would issue in Postgres. The instrumentation, Result, and decision paths
  # run against the real gem code.
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

    it "rejects a name with a trailing dot" do
      # `reporting.` would round-trip to a Postgres syntax error at
      # connection.execute — catch it at the gem boundary instead.
      expect {
        StandardLedger.refresh!("reporting.", concurrently: false)
      }.to raise_error(ArgumentError, /valid SQL identifier/)
    end

    it "rejects a triple-qualified name (only schema.view is supported)" do
      expect {
        StandardLedger.refresh!("a.b.c", concurrently: false)
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

  describe "error reporting" do
    # A real reporter with a recording subscriber, so the dedupe behaviour
    # (ActiveSupport::ErrorReporter skips an exception it already reported)
    # is exercised rather than stubbed.
    let(:reports) { [] }
    let(:reporter) do
      recorded = reports
      ActiveSupport::ErrorReporter.new.tap do |r|
        r.subscribe(Class.new {
          define_method(:report) { |error, handled:, severity:, context:, source:| recorded << { error:, handled:, severity:, context:, source: } }
        }.new)
      end
    end

    before { allow(ActiveSupport).to receive(:error_reporter).and_return(reporter) }

    it "reports a failed refresh as unhandled, with view context, then re-raises" do
      error = StandardError.new("kaboom")
      allow(ActiveRecord::Base.connection).to receive(:execute).and_raise(error)

      expect {
        StandardLedger.refresh!("user_prompt_inventories", concurrently: true)
      }.to raise_error(error)

      expect(reports).to eq([
        { error: error, handled: false, severity: :error,
          context: { view: "user_prompt_inventories", concurrently: true }, source: "standard_ledger" }
      ])
    end

    it "does not double-report when the host also reports the re-raised error" do
      allow(ActiveRecord::Base.connection).to receive(:execute).and_raise(StandardError, "kaboom")

      expect {
        begin
          StandardLedger.refresh!("user_prompt_inventories", concurrently: false)
        rescue StandardError => e
          reporter.report(e, handled: true, context: { view: "host" })
          raise
        end
      }.to raise_error(StandardError, "kaboom")

      expect(reports.size).to eq(1)
      expect(reports.first[:source]).to eq("standard_ledger")
    end

    it "still re-raises the original error when the reporter itself raises" do
      allow(ActiveSupport).to receive(:error_reporter).and_return(
        instance_double(ActiveSupport::ErrorReporter).tap { |r| allow(r).to receive(:report).and_raise(RuntimeError, "reporter down") }
      )
      allow(ActiveRecord::Base.connection).to receive(:execute).and_raise(StandardError, "kaboom")

      expect {
        StandardLedger.refresh!("user_prompt_inventories", concurrently: false)
      }.to raise_error(StandardError, "kaboom")
    end

    it "does not report programming errors raised before any SQL runs" do
      expect { StandardLedger.refresh!("foo;bar", concurrently: false) }.to raise_error(ArgumentError)
      ActiveRecord::Base.transaction do
        expect {
          StandardLedger.refresh!("user_prompt_inventories", concurrently: true)
        }.to raise_error(StandardLedger::RefreshInsideTransaction)
      end

      expect(reports).to be_empty
    end

    it "reports nothing on success" do
      StandardLedger.refresh!("user_prompt_inventories", concurrently: false)
      expect(reports).to be_empty
    end
  end

  describe "transaction-state guard" do
    # Postgres rejects `REFRESH MATERIALIZED VIEW CONCURRENTLY` inside a
    # transaction block. The gem catches this at the boundary so callers
    # see a clear, gem-attributable error instead of a raw
    # `PG::ActiveSqlTransaction` from inside `connection.execute`.
    #
    # The non-concurrent form is permitted by Postgres inside transactions,
    # so the guard is concurrent-only.
    it "raises RefreshInsideTransaction when concurrently: true is called inside a transaction" do
      ActiveRecord::Base.transaction do
        expect {
          StandardLedger.refresh!("user_prompt_inventories", concurrently: true)
        }.to raise_error(StandardLedger::RefreshInsideTransaction, /cannot run inside a transaction/)
      end
    end

    it "permits concurrently: false inside a transaction (Postgres allows the blocking form)" do
      ActiveRecord::Base.transaction do
        expect {
          StandardLedger.refresh!("user_prompt_inventories", concurrently: false)
        }.not_to raise_error
      end
    end

    it "issues no SQL and emits no .refreshed/.failed event on the guard path" do
      sub_refreshed = ActiveSupport::Notifications.subscribe("standard_ledger.projection.refreshed") { |*| flunk("must not fire") }
      sub_failed    = ActiveSupport::Notifications.subscribe("standard_ledger.projection.failed")    { |*| flunk("must not fire") }
      allow(ActiveRecord::Base.connection).to receive(:execute).and_call_original
      ActiveRecord::Base.transaction do
        expect {
          StandardLedger.refresh!("user_prompt_inventories", concurrently: true)
        }.to raise_error(StandardLedger::RefreshInsideTransaction)
      end
      expect(ActiveRecord::Base.connection).not_to have_received(:execute).with(/REFRESH MATERIALIZED VIEW/)
    ensure
      ActiveSupport::Notifications.unsubscribe(sub_refreshed) if sub_refreshed
      ActiveSupport::Notifications.unsubscribe(sub_failed)    if sub_failed
    end
  end

  describe "concurrently: :auto" do
    let(:connection) { ActiveRecord::Base.connection }
    let(:probe_rows) { { "populated" => true, "unique_index" => true } }
    let(:probe_sql) { [] }

    before do
      allow(connection).to receive(:select_one) do |sql, *|
        probe_sql << sql
        probe_rows
      end
    end

    it "refreshes CONCURRENTLY when the view is populated and has a unique index" do
      result = StandardLedger.refresh!("user_prompt_inventories", concurrently: :auto)

      expect(executed_sql).to eq([ "REFRESH MATERIALIZED VIEW CONCURRENTLY user_prompt_inventories" ])
      expect(result.projections[:refreshed]).to eq([ { view: "user_prompt_inventories", concurrently: true } ])
    end

    it "probes the catalog with the view name bound as a quoted literal" do
      StandardLedger.refresh!("reporting.user_prompt_inventories", concurrently: :auto)

      expect(probe_sql.size).to eq(1)
      expect(probe_sql.first).to include("pg_class", "relispopulated", "indisunique", "to_regclass('reporting.user_prompt_inventories')")
    end

    it "accepts PG-style 't'/'f' strings from the probe" do
      probe_rows.replace("populated" => "t", "unique_index" => "t")
      StandardLedger.refresh!("user_prompt_inventories", concurrently: :auto)
      expect(executed_sql.first).to include("CONCURRENTLY")
    end

    it "falls back to a plain refresh when the view has never been populated" do
      probe_rows["populated"] = false
      StandardLedger.refresh!("user_prompt_inventories", concurrently: :auto)
      expect(executed_sql).to eq([ "REFRESH MATERIALIZED VIEW user_prompt_inventories" ])
    end

    it "falls back to a plain refresh when the view has no usable unique index" do
      probe_rows["unique_index"] = false
      StandardLedger.refresh!("user_prompt_inventories", concurrently: :auto)
      expect(executed_sql).to eq([ "REFRESH MATERIALIZED VIEW user_prompt_inventories" ])
    end

    it "falls back to a plain refresh when the relation is not a materialized view (probe returns no row)" do
      allow(connection).to receive(:select_one).and_return(nil)
      StandardLedger.refresh!("user_prompt_inventories", concurrently: :auto)
      expect(executed_sql).to eq([ "REFRESH MATERIALIZED VIEW user_prompt_inventories" ])
    end

    it "falls back to a plain refresh inside a transaction without probing or raising" do
      result = nil
      ActiveRecord::Base.transaction do
        result = StandardLedger.refresh!("user_prompt_inventories", concurrently: :auto)
      end

      expect(executed_sql).to eq([ "REFRESH MATERIALIZED VIEW user_prompt_inventories" ])
      expect(probe_sql).to be_empty
      expect(result.projections[:refreshed].first[:concurrently]).to be(false)
    end

    it "reports a failing probe via the error reporter and falls back to a plain refresh" do
      probe_error = StandardError.new("catalog unavailable")
      allow(connection).to receive(:select_one).and_raise(probe_error)
      allow(ActiveSupport.error_reporter).to receive(:report)

      StandardLedger.refresh!("user_prompt_inventories", concurrently: :auto)

      expect(executed_sql).to eq([ "REFRESH MATERIALIZED VIEW user_prompt_inventories" ])
      expect(ActiveSupport.error_reporter).to have_received(:report).with(
        probe_error,
        hash_including(handled: true, context: { view: "user_prompt_inventories" }, source: "standard_ledger")
      )
    end

    it "prefers Rails.error when Rails is loaded" do
      reporter = instance_double(ActiveSupport::ErrorReporter, report: nil)
      rails = Module.new
      rails.define_singleton_method(:error) { reporter }
      stub_const("Rails", rails)
      allow(connection).to receive(:select_one).and_raise(StandardError, "boom")

      StandardLedger.refresh!("user_prompt_inventories", concurrently: :auto)

      expect(reporter).to have_received(:report).with(an_instance_of(StandardError), hash_including(handled: true))
    end

    it "still validates the view name before probing" do
      expect {
        StandardLedger.refresh!("foo;bar", concurrently: :auto)
      }.to raise_error(ArgumentError, /valid SQL identifier/)
      expect(probe_sql).to be_empty
    end

    it "is used when Config#matview_refresh_strategy = :auto and concurrently: is omitted" do
      StandardLedger.configure { |c| c.matview_refresh_strategy = :auto }
      probe_rows["populated"] = false

      StandardLedger.refresh!("user_prompt_inventories")

      expect(probe_sql.size).to eq(1)
      expect(executed_sql.first).not_to include("CONCURRENTLY")
    ensure
      StandardLedger.reset!
    end
  end

  describe "argument validation" do
    after { StandardLedger.reset! }

    it "rejects an unknown concurrently: value" do
      expect {
        StandardLedger.refresh!("user_prompt_inventories", concurrently: :sometimes)
      }.to raise_error(ArgumentError, /concurrently: must be true, false, :auto, or nil/)
      expect(executed_sql).to be_empty
    end

    it "rejects an unknown Config#matview_refresh_strategy" do
      StandardLedger.configure { |c| c.matview_refresh_strategy = :eventually }
      expect {
        StandardLedger.refresh!("user_prompt_inventories")
      }.to raise_error(ArgumentError, /matview_refresh_strategy must be/)
    end
  end

  describe "Result interop" do
    after { StandardLedger.reset! }

    it "returns the host's Result type when an adapter is configured" do
      host_result = Struct.new(:success, :projections, keyword_init: true)
      StandardLedger.configure do |c|
        c.result_class   = host_result
        c.result_adapter = ->(success:, projections:, **) { host_result.new(success: success, projections: projections) }
      end

      result = StandardLedger.refresh!("user_prompt_inventories", concurrently: false)

      expect(result).to be_a(host_result)
      expect(result.projections).to eq(refreshed: [ { view: "user_prompt_inventories", concurrently: false } ])
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/ExampleLength, RSpec/MultipleExpectations
