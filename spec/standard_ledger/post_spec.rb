# rubocop:disable RSpec/DescribeClass, RSpec/MultipleExpectations
RSpec.describe "StandardLedger.post" do
  before do
    stub_const("VoucherScheme", Class.new(ActiveRecord::Base) do
      self.table_name = "voucher_schemes"
    end)

    stub_const("VoucherRecord", Class.new(ActiveRecord::Base) do
      self.table_name = "voucher_records"
      include StandardLedger::Entry

      belongs_to :voucher_scheme, optional: true

      ledger_entry kind:            :action,
                   idempotency_key: :serial_no,
                   scope:           :organisation_id
    end)
  end

  after do
    VoucherRecord.unscoped.delete_all
    VoucherScheme.unscoped.delete_all
    StandardLedger.reset!
  end

  let(:scheme) { VoucherScheme.create!(name: "Welcome") }

  it "creates the entry, writing kind to the configured column and assigning targets" do
    result = StandardLedger.post(VoucherRecord,
                                 kind:    :grant,
                                 targets: { voucher_scheme: scheme },
                                 attrs:   { serial_no: "v-1", organisation_id: "org-1" })

    expect(result).to be_success
    expect(result).not_to be_idempotent
    expect(result.entry).to be_persisted
    expect(result.entry.action).to eq("grant")
    expect(result.entry.voucher_scheme_id).to eq(scheme.id)
    expect(result.projections).to eq({})
  end

  it "returns the existing row with idempotent? on a duplicate idempotency key" do
    first = StandardLedger.post(VoucherRecord, kind: :grant, attrs: { serial_no: "v-1", organisation_id: "org-1" })
    second = StandardLedger.post(VoucherRecord, kind: :grant, attrs: { serial_no: "v-1", organisation_id: "org-1" })

    expect(second).to be_success
    expect(second).to be_idempotent
    expect(second.entry.id).to eq(first.entry.id)
    expect(VoucherRecord.count).to eq(1)
  end

  it "raises ArgumentError when a targets: key is not an association" do
    expect {
      StandardLedger.post(VoucherRecord, kind: :grant, targets: { nope: scheme },
                                         attrs: { serial_no: "v-1", organisation_id: "org-1" })
    }.to raise_error(ArgumentError, /has no association :nope/)
  end

  it "returns a failure Result carrying validation errors" do
    VoucherRecord.validates :serial_no, format: { with: /\Av-/ }

    result = StandardLedger.post(VoucherRecord, kind: :grant, attrs: { serial_no: "bad", organisation_id: "org-1" })

    expect(result).to be_failure
    expect(result.errors).to include(/Serial no is invalid/)
    expect(result.entry).not_to be_persisted
  end

  it "emits <prefix>.entry.created with the entry, kind and targets" do
    events = []
    sub = ActiveSupport::Notifications.subscribe("standard_ledger.entry.created") do |*args|
      events << ActiveSupport::Notifications::Event.new(*args).payload
    end

    result = StandardLedger.post(VoucherRecord, kind: :grant, targets: { voucher_scheme: scheme },
                                                attrs: { serial_no: "v-1", organisation_id: "org-1" })

    expect(events.size).to eq(1)
    expect(events.first).to include(entry: result.entry, kind: "grant", targets: { voucher_scheme: scheme })
  ensure
    ActiveSupport::Notifications.unsubscribe(sub) if sub
  end

  it "returns the host's Result type via the configured adapter, passing all six keywords" do
    received = nil
    StandardLedger.configure do |c|
      c.result_class   = Hash
      c.result_adapter = ->(success:, value:, errors:, entry:, idempotent:, projections:) {
        received = { success:, value:, errors:, entry:, idempotent:, projections: }
      }
    end

    result = StandardLedger.post(VoucherRecord, kind: :grant, attrs: { serial_no: "v-1", organisation_id: "org-1" })

    expect(result).to equal(received)
    expect(received).to include(success: true, errors: [], idempotent: false, projections: {})
    expect(received[:entry]).to be_a(VoucherRecord)
    expect(received[:value]).to equal(received[:entry])
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleExpectations
