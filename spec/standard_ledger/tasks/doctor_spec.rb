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
  end

  it "prints the success message and exits 0 when every trigger is present" do
    fake_result = instance_double(ActiveRecord::Result, rows: [ [ 1 ] ])
    allow(ActiveRecord::Base.connection).to receive(:exec_query)
      .with(/SELECT 1 FROM pg_trigger/, "standard_ledger:doctor", [ "voucher_records_apply_to_schemes" ])
      .and_return(fake_result)

    expect { task.invoke }.to output(/All :trigger projections have their triggers present/).to_stdout
  end

  it "exits 1 and reports the missing trigger when pg_trigger has no row" do
    fake_result = instance_double(ActiveRecord::Result, rows: [])
    allow(ActiveRecord::Base.connection).to receive(:exec_query)
      .with(/SELECT 1 FROM pg_trigger/, "standard_ledger:doctor", [ "voucher_records_apply_to_schemes" ])
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

    queried_names = []
    allow(ActiveRecord::Base.connection).to receive(:exec_query) do |_sql, _name, binds|
      queried_names << binds.first
      instance_double(ActiveRecord::Result, rows: [ [ 1 ] ])
    end

    expect { task.invoke }.to output(/All :trigger projections have their triggers present/).to_stdout
    # InlineOnlyRecord declares no `:trigger` projection — its trigger
    # name (there is none) must never appear in the queried list. Other
    # `:trigger` projections from sibling specs may or may not appear
    # depending on AR's `descendants` retention; we only assert that
    # the inline class does NOT show up here.
    expect(queried_names).not_to include(nil, "")
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/ExampleLength, RSpec/MultipleExpectations
