RSpec.describe StandardLedger::Result do
  describe ".success" do
    let(:entry) { Object.new }
    let(:result) { described_class.success(entry: entry, projections: { inline: [ :voucher_scheme ] }) }

    it "is successful, not a failure" do
      expect(result).to be_success
      expect(result).not_to be_failure
    end

    it "exposes the entry as both #entry and #value" do
      expect(result.entry).to equal(entry)
      expect(result.value).to equal(entry)
    end

    it "exposes the projections by mode" do
      expect(result.projections).to eq(inline: [ :voucher_scheme ])
    end

    it "is non-idempotent by default" do
      expect(result).not_to be_idempotent
    end

    it "marks idempotent: true when requested" do
      result = described_class.success(entry: Object.new, idempotent: true)
      expect(result).to be_idempotent
    end
  end

  describe ".failure" do
    it "wraps a single error message into an array" do
      result = described_class.failure(errors: "boom")
      expect(result).to be_failure
      expect(result.errors).to eq([ "boom" ])
    end

    it "preserves an array of errors" do
      result = described_class.failure(errors: [ "a", "b" ])
      expect(result.errors).to eq([ "a", "b" ])
    end
  end
end
