require "standard_ledger/rspec/helpers"

# rubocop:disable RSpec/DescribeClass, RSpec/ExampleLength, RSpec/MultipleDescribes
RSpec.describe "StandardLedger.with_modes" do
  before do
    stub_const("VoucherScheme", Class.new(ActiveRecord::Base) do
      self.table_name = "voucher_schemes"
    end)

    stub_const("VoucherRecord", Class.new(ActiveRecord::Base) do
      self.table_name = "voucher_records"
      include StandardLedger::Entry
      ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id
    end)

    stub_const("PaymentRecord", Class.new(ActiveRecord::Base) do
      self.table_name = "voucher_records"
      include StandardLedger::Entry
      ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id
    end)
  end

  it "stores the override during the block and clears it after" do
    expect(StandardLedger.mode_override_for(VoucherRecord)).to be_nil

    captured = nil
    StandardLedger.with_modes(VoucherRecord => :inline) do
      captured = StandardLedger.mode_override_for(VoucherRecord)
    end

    expect(captured).to eq(:inline)
    expect(StandardLedger.mode_override_for(VoucherRecord)).to be_nil
  end

  it "restores the prior state even when the block raises" do
    expect {
      StandardLedger.with_modes(VoucherRecord => :inline) do
        raise "boom"
      end
    }.to raise_error(RuntimeError, /boom/)

    expect(StandardLedger.mode_override_for(VoucherRecord)).to be_nil
  end

  it "merges nested overrides — inner wins for same keys, outer keys persist" do
    inner_voucher = inner_payment = outer_voucher_after = outer_payment_after = nil

    StandardLedger.with_modes(VoucherRecord => :async) do
      outer_voucher = StandardLedger.mode_override_for(VoucherRecord)
      expect(outer_voucher).to eq(:async)

      StandardLedger.with_modes(VoucherRecord => :inline, PaymentRecord => :inline) do
        inner_voucher = StandardLedger.mode_override_for(VoucherRecord)
        inner_payment = StandardLedger.mode_override_for(PaymentRecord)
      end

      outer_voucher_after = StandardLedger.mode_override_for(VoucherRecord)
      outer_payment_after = StandardLedger.mode_override_for(PaymentRecord)
    end

    expect(inner_voucher).to eq(:inline)
    expect(inner_payment).to eq(:inline)
    expect(outer_voucher_after).to eq(:async)
    expect(outer_payment_after).to be_nil
  end

  it "accepts symbolic keys that resolve via const_get" do
    captured = nil
    StandardLedger.with_modes(voucher_record: :inline) do
      captured = StandardLedger.mode_override_for(VoucherRecord)
    end

    expect(captured).to eq(:inline)
  end

  it "accepts string keys that resolve via const_get" do
    captured = nil
    StandardLedger.with_modes("VoucherRecord" => :inline) do
      captured = StandardLedger.mode_override_for(VoucherRecord)
    end

    expect(captured).to eq(:inline)
  end

  it "raises when given an unrecognised key type" do
    expect {
      StandardLedger.with_modes(123 => :inline) { }
    }.to raise_error(ArgumentError, /Class, String, or Symbol/)
  end

  it "isolates overrides between threads" do
    outer_thread_captured = nil
    other_thread_captured = nil

    StandardLedger.with_modes(VoucherRecord => :inline) do
      outer_thread_captured = StandardLedger.mode_override_for(VoucherRecord)

      thread = Thread.new do
        other_thread_captured = StandardLedger.mode_override_for(VoucherRecord)
      end
      thread.join
    end

    expect(outer_thread_captured).to eq(:inline)
    expect(other_thread_captured).to be_nil
  end

  it "is wiped by StandardLedger.reset!" do
    Thread.current[:standard_ledger_mode_overrides] = { VoucherRecord => :inline }

    StandardLedger.reset!

    expect(StandardLedger.mode_override_for(VoucherRecord)).to be_nil
  end
end

RSpec.describe "StandardLedger::RSpec::Helpers" do
  it "exposes with_modes as an instance method on the includer" do
    klass = Class.new { include StandardLedger::RSpec::Helpers }

    stub_const("WidgetRecord", Class.new(ActiveRecord::Base) do
      self.table_name = "voucher_records"
      include StandardLedger::Entry
      ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id
    end)

    captured = nil
    klass.new.with_modes(WidgetRecord => :inline) do
      captured = StandardLedger.mode_override_for(WidgetRecord)
    end

    expect(captured).to eq(:inline)
    expect(StandardLedger.mode_override_for(WidgetRecord)).to be_nil
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/ExampleLength, RSpec/MultipleDescribes
