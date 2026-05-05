require "rake"

# rubocop:disable RSpec/DescribeClass, RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe "rake standard_ledger:doctor" do
  # Build a fresh Rake application per example so task state doesn't
  # leak between specs. The task expects a Rails-style `:environment`
  # prerequisite — we stub that as a no-op so the task body runs
  # without trying to boot Rails. The actual `pg_trigger` query is
  # mocked per example, since SQLite (the test harness's DB) has no
  # `pg_trigger` system catalog.
  let(:task) { Rake::Task["standard_ledger:doctor"] }
  # The doctor uses each entry class's own `connection` (not
  # `ActiveRecord::Base.connection`) so multi-DB hosts query the
  # connection that owns the entry class's table. The shared SQLite
  # test connection has no `pg_trigger` system catalog, so we stub a
  # fake connection on every entry class the doctor walks. This
  # spec's local entry classes all share AR's base connection, so a
  # single fake serves them all.
  let(:fake_connection) { instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter) }

  before do
    Rake.application = Rake::Application.new
    Rake::Task.define_task(:environment)
    load File.expand_path("../../../lib/tasks/standard_ledger.rake", __dir__)

    stub_const("VoucherScheme", Class.new(ActiveRecord::Base) do
      self.table_name = "voucher_schemes"
    end)

    stub_const("DoctorRecord", Class.new(ActiveRecord::Base) do
      self.table_name = "voucher_records"
      include StandardLedger::Entry
      include StandardLedger::Projector

      belongs_to :voucher_scheme, optional: true

      ledger_entry kind:            :action,
                   idempotency_key: :serial_no,
                   scope:           :organisation_id

      projects_onto :voucher_scheme, mode: :trigger,
                                     trigger_name: "voucher_records_apply_to_schemes" do
        rebuild_sql "UPDATE voucher_schemes SET granted_vouchers_count = 0 WHERE id = :target_id"
      end
    end)

    # Stubbing `ActiveRecord::Base.connection` to return
    # `fake_connection` is intentional — `DoctorRecord.connection`
    # (and any sibling entry class's `.connection`) walks up to the
    # base connection in this single-DB test setup, so the stub flows
    # through wherever the doctor calls `klass.connection`.
    allow(ActiveRecord::Base).to receive(:connection).and_return(fake_connection)
  end

  it "prints the success message and exits 0 when every trigger is present" do
    fake_result = instance_double(ActiveRecord::Result, rows: [ [ 1 ] ])
    # The query joins `pg_trigger` against `pg_class` and binds both
    # the trigger name AND the entry class's table name, so the doctor
    # only flags presence on the *correct* table (trigger names are
    # per-table in Postgres — bare-name lookups admit false positives
    # across unrelated tables).
    allow(fake_connection).to receive(:exec_query)
      .with(/SELECT 1 FROM pg_trigger.*JOIN pg_class.*c\.relname/m, "standard_ledger:doctor",
            [ "voucher_records_apply_to_schemes", "voucher_records" ])
      .and_return(fake_result)

    expect { task.invoke }.to output(/All :trigger projections have their triggers present/).to_stdout
  end

  it "exits 1 and reports the missing trigger when pg_trigger has no row" do
    fake_result = instance_double(ActiveRecord::Result, rows: [])
    allow(fake_connection).to receive(:exec_query)
      .with(/SELECT 1 FROM pg_trigger.*JOIN pg_class.*c\.relname/m, "standard_ledger:doctor",
            [ "voucher_records_apply_to_schemes", "voucher_records" ])
      .and_return(fake_result)

    expect { task.invoke }.to raise_error(SystemExit) { |error|
      expect(error.status).to eq(1)
    }.and output(/Missing triggers detected.*voucher_records_apply_to_schemes/m).to_stderr
  end

  it "ignores entry classes without :trigger projections" do
    # Define a plain :inline entry class — it should NOT cause the doctor
    # to query pg_trigger about the inline class. Only `:trigger`
    # definitions get checked.
    stub_const("InlineOnlyRecord", Class.new(ActiveRecord::Base) do
      self.table_name = "voucher_records"
      include StandardLedger::Entry
      include StandardLedger::Projector
      belongs_to :voucher_scheme, optional: true
      ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id

      projects_onto :voucher_scheme, mode: :inline do
        on(:grant) { |scheme, _| scheme.increment(:granted_vouchers_count) }
      end
    end)

    queried_binds = []
    allow(fake_connection).to receive(:exec_query) do |_sql, _name, binds|
      queried_binds << binds
      instance_double(ActiveRecord::Result, rows: [ [ 1 ] ])
    end

    expect { task.invoke }.to output(/All :trigger projections have their triggers present/).to_stdout

    # The doctor only iterates `:trigger` projections, so an inline-only
    # class must not generate any pg_trigger query. Every observed bind
    # tuple must be the DoctorRecord trigger — never a nil/empty
    # placeholder, never a tuple inviting the inline class. (DoctorRecord
    # and InlineOnlyRecord coincidentally share a `table_name`, so the
    # table-name bind alone can't distinguish them; the assertion is
    # that *only* DoctorRecord's trigger-name bind appears.)
    expect(queried_binds).to all(eq([ "voucher_records_apply_to_schemes", "voucher_records" ]))
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/ExampleLength, RSpec/MultipleExpectations
