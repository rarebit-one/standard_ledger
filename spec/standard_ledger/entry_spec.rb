RSpec.describe StandardLedger::Entry do
  before do
    stub_const("LedgerEntryModel", Class.new(ActiveRecord::Base) do
      self.table_name = "ledger_entries"
      include StandardLedger::Entry
      ledger_entry kind: :kind, idempotency_key: :idempotency_key, scope: :organisation_id
    end)

    stub_const("MutableEntryModel", Class.new(ActiveRecord::Base) do
      self.table_name = "mutable_entries"
      include StandardLedger::Entry
      ledger_entry kind: :kind, immutable: false
    end)

    stub_const("UnscopedEntryModel", Class.new(ActiveRecord::Base) do
      self.table_name = "unscoped_entries"
      include StandardLedger::Entry
      ledger_entry kind: :kind, idempotency_key: :idempotency_key
    end)

    stub_const("WideIndexEntryModel", Class.new(ActiveRecord::Base) do
      self.table_name = "wide_index_entries"
      include StandardLedger::Entry
      ledger_entry kind: :kind, idempotency_key: :idempotency_key, scope: :organisation_id
    end)

    stub_const("MissingIndexEntryModel", Class.new(ActiveRecord::Base) do
      self.table_name = "missing_index_entries"
      include StandardLedger::Entry
      ledger_entry kind: :kind, idempotency_key: :idempotency_key, scope: :organisation_id
    end)

    stub_const("NoIdempotencyEntryModel", Class.new(ActiveRecord::Base) do
      self.table_name = "no_idempotency_entries"
      include StandardLedger::Entry
      ledger_entry kind: :kind, idempotency_key: nil
    end)
  end

  after do
    [ "ledger_entries", "mutable_entries", "unscoped_entries",
      "wide_index_entries", "missing_index_entries", "no_idempotency_entries" ].each do |t|
      ActiveRecord::Base.connection.execute("DELETE FROM #{t}")
    end
  end

  describe "read-only enforcement" do
    let(:entry) { LedgerEntryModel.create!(organisation_id: "org-1", kind: "grant", idempotency_key: "k1") }

    it "raises ReadOnlyRecord on update!" do
      expect { entry.update!(payload: "x") }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end

    it "raises ReadOnlyRecord on save" do
      entry.payload = "x"
      expect { entry.save }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end

    it "raises ReadOnlyRecord on destroy!" do
      expect { entry.destroy! }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end

    it "lets the initial create persist" do
      expect(entry).to be_persisted
      expect(entry.idempotent?).to be(false)
    end
  end

  describe "immutable: false" do
    let(:entry) { MutableEntryModel.create!(kind: "grant", payload: "before") }

    it "allows updates" do
      expect { entry.update!(payload: "after") }.not_to raise_error
      expect(entry.reload.payload).to eq("after")
    end

    it "allows destroys" do
      expect { entry.destroy! }.not_to raise_error
    end
  end

  describe "idempotent create!" do
    it "returns the existing row on duplicate insert and marks idempotent? true" do
      first  = LedgerEntryModel.create!(organisation_id: "org-1", kind: "grant", idempotency_key: "dup")
      second = LedgerEntryModel.create!(organisation_id: "org-1", kind: "grant", idempotency_key: "dup")

      expect(second.id).to eq(first.id)
      expect(second.idempotent?).to be(true)
      expect(first.idempotent?).to be(false)
    end

    it "differentiates by scope" do
      a = LedgerEntryModel.create!(organisation_id: "org-1", kind: "grant", idempotency_key: "shared")
      b = LedgerEntryModel.create!(organisation_id: "org-2", kind: "grant", idempotency_key: "shared")

      expect(a.id).not_to eq(b.id)
      expect(a.idempotent?).to be(false)
      expect(b.idempotent?).to be(false)
    end

    it "works with no scope (single-column unique index)" do
      first  = UnscopedEntryModel.create!(kind: "grant", idempotency_key: "u1")
      second = UnscopedEntryModel.create!(kind: "redeem", idempotency_key: "u1")

      expect(second.id).to eq(first.id)
      expect(second.idempotent?).to be(true)
    end
  end

  describe "boot-time index validation" do
    it "raises MissingIdempotencyIndex when no matching unique index exists" do
      expect {
        MissingIndexEntryModel.create!(organisation_id: "org-1", kind: "grant", idempotency_key: "k")
      }.to raise_error(StandardLedger::MissingIdempotencyIndex, /missing_index_entries/)
    end

    it "raises MissingIdempotencyIndex when a unique index covers extra columns" do
      expect {
        WideIndexEntryModel.create!(organisation_id: "org-1", kind: "grant", idempotency_key: "k")
      }.to raise_error(StandardLedger::MissingIdempotencyIndex, /wide_index_entries/)
    end

    it "caches the validation so it runs only once per class" do
      LedgerEntryModel.create!(organisation_id: "org-1", kind: "grant", idempotency_key: "first")
      expect(LedgerEntryModel).not_to receive(:connection)
      LedgerEntryModel.create!(organisation_id: "org-1", kind: "grant", idempotency_key: "second")
    end
  end

  describe "idempotency_key: nil" do
    it "skips the index check and behaves like a regular create!" do
      a = NoIdempotencyEntryModel.create!(kind: "telemetry", payload: "a")
      b = NoIdempotencyEntryModel.create!(kind: "telemetry", payload: "a")

      expect(a.id).not_to eq(b.id)
      expect(a.idempotent?).to be(false)
      expect(b.idempotent?).to be(false)
    end
  end
end
