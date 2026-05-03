RSpec.describe StandardLedger do
  it "exposes a VERSION constant" do
    expect(StandardLedger::VERSION).to be_a(String)
    expect(StandardLedger::VERSION).to match(/\A\d+\.\d+\.\d+/)
  end

  describe ".configure" do
    it "yields the Config instance and returns it" do
      yielded = nil
      result = described_class.configure { |c| yielded = c }

      expect(yielded).to be_a(StandardLedger::Config)
      expect(result).to equal(yielded)
      expect(described_class.config).to equal(yielded)
    end

    it "is memoized across calls" do
      a = described_class.config
      b = described_class.config
      expect(a).to equal(b)
    end
  end

  describe ".reset!" do
    it "clears the cached config" do
      original = described_class.config
      described_class.reset!
      expect(described_class.config).not_to equal(original)
    end
  end
end
