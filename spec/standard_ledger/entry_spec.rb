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

    stub_const("NullableScopeEntryModel", Class.new(ActiveRecord::Base) do
      self.table_name = "nullable_scope_entries"
      include StandardLedger::Entry
      ledger_entry kind: :kind, idempotency_key: :idempotency_key, scope: :organisation_id
    end)

    stub_const("ExtraUniqueEntryModel", Class.new(ActiveRecord::Base) do
      self.table_name = "extra_unique_entries"
      include StandardLedger::Entry
      ledger_entry kind: :kind, idempotency_key: :idempotency_key, scope: :organisation_id
    end)

    stub_const("PlainModel", Class.new(ActiveRecord::Base) do
      self.table_name = "no_idempotency_entries"
      include StandardLedger::Entry
    end)
  end

  after do
    [ LedgerEntryModel, MutableEntryModel, UnscopedEntryModel,
      WideIndexEntryModel, MissingIndexEntryModel, NoIdempotencyEntryModel,
      NullableScopeEntryModel, ExtraUniqueEntryModel ].each do |model|
      model.unscoped.delete_all
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

  describe "immutable: true, allow_destroy: true" do
    # `allow_destroy` exists for entries whose owning record declares
    # `dependent: :destroy` (sandbox tear-down, GDPR erasure, test
    # cleanup paths). The journal contract — no app-code mutations to
    # persisted rows — still holds via the `readonly?` save/update path;
    # only the destroy guard is relaxed.
    before do
      stub_const("CascadableEntryModel", Class.new(ActiveRecord::Base) do
        self.table_name = "mutable_entries"
        include StandardLedger::Entry
        ledger_entry kind: :kind, immutable: true, allow_destroy: true
      end)
    end

    let(:entry) { CascadableEntryModel.create!(kind: "grant", payload: "x") }

    it "still raises ReadOnlyRecord on update! (save/update path is unchanged)" do
      expect { entry.update!(payload: "y") }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end

    it "still raises ReadOnlyRecord on save (save/update path is unchanged)" do
      entry.payload = "y"
      expect { entry.save }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end

    it "permits destroy! so dependent: :destroy cascades work" do
      expect { entry.destroy! }.not_to raise_error
      expect(CascadableEntryModel.find_by(id: entry.id)).to be_nil
    end

    it "stores allow_destroy in the entry config" do
      expect(CascadableEntryModel.standard_ledger_entry_config).to include(
        immutable: true,
        allow_destroy: true
      )
    end

    context "when destroyed via dependent: :destroy from a parent" do
      # The motivating use case for `allow_destroy: true` is a parent
      # record with `has_many :events, dependent: :destroy` that needs
      # to reap its children for sandbox tear-down or GDPR erasure.
      # This goes through AR's destroy callback wiring rather than the
      # direct `entry.destroy!` path — assert the cascade actually
      # works end-to-end.
      before do
        stub_const("CascadeParent", Class.new(ActiveRecord::Base) do
          self.table_name = "cascade_parents"
          has_many :children, class_name: "CascadeChildEntry",
                              foreign_key: :cascade_parent_id, dependent: :destroy
        end)

        stub_const("CascadeChildEntry", Class.new(ActiveRecord::Base) do
          self.table_name = "cascade_child_entries"
          include StandardLedger::Entry
          ledger_entry kind: :kind, immutable: true, allow_destroy: true

          belongs_to :cascade_parent
        end)
      end

      after do
        [ CascadeChildEntry, CascadeParent ].each { |m| m.unscoped.delete_all }
      end

      it "cascades the parent's destroy through to the immutable children" do
        parent = CascadeParent.create!(name: "p")
        CascadeChildEntry.create!(cascade_parent: parent, kind: "a")
        CascadeChildEntry.create!(cascade_parent: parent, kind: "b")
        expect(CascadeChildEntry.count).to eq(2)

        expect { parent.destroy! }.not_to raise_error

        expect(CascadeParent.count).to eq(0)
        expect(CascadeChildEntry.count).to eq(0)
      end
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

    it "re-raises RecordNotUnique when the violation is on a non-idempotency unique index" do
      ExtraUniqueEntryModel.create!(
        organisation_id: "org-1", kind: "grant",
        idempotency_key: "k1",    external_ref: "ref-shared"
      )

      # Same external_ref (other unique index), different idempotency_key —
      # the rescue must NOT swallow this; the conflict isn't on our index.
      expect {
        ExtraUniqueEntryModel.create!(
          organisation_id: "org-1", kind: "grant",
          idempotency_key: "k2",    external_ref: "ref-shared"
        )
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "raises RecordNotUnique on collision when create! is called with a block (no attributes hash)" do
      LedgerEntryModel.create!(organisation_id: "org-1", kind: "grant", idempotency_key: "blk")

      # Block-form `create!` passes `attributes = nil` to the override, so
      # we can't construct the find_by lookup — colliding inserts re-raise
      # like vanilla ActiveRecord rather than returning the existing row.
      expect {
        LedgerEntryModel.create! do |r|
          r.organisation_id = "org-1"
          r.kind = "grant"
          r.idempotency_key = "blk"
        end
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "does not match a row with NULL scope when the scope attribute is missing" do
      # Pre-seed a row where organisation_id is NULL (legal because the
      # column is nullable here). A subsequent insert that omits the scope
      # column entirely must NOT be treated as idempotent against this row.
      seeded = NullableScopeEntryModel.create!(kind: "grant", idempotency_key: "n1")
      expect(seeded.organisation_id).to be_nil

      # Now provoke a different unique-index collision on the same key but
      # for a real org — the find_by must not fall back to the NULL-scope
      # row. Insert the colliding row directly to bypass the rescue and
      # then check that find_existing_standard_ledger_entry guards nil.
      lookup = NullableScopeEntryModel.send(
        :find_existing_standard_ledger_entry,
        kind: "grant", idempotency_key: "n1"  # no organisation_id
      )
      expect(lookup).to be_nil
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

    describe "partial unique indexes" do
      # The gem accepts partial unique indexes whose predicate is the
      # canonical `<idempotency_key> IS NOT NULL` shape — common when an
      # event table has an optional unique key (e.g. inventory_records'
      # serial_no) and the host wants uniqueness enforced only on rows
      # where the key is present. Other predicate shapes are rejected
      # because the gem can't statically prove they preserve idempotency
      # for the host's intent.
      before do
        stub_const("PartialIndexEntryModel", Class.new(ActiveRecord::Base) do
          self.table_name = "partial_index_entries"
          include StandardLedger::Entry
          ledger_entry kind: :kind, idempotency_key: :idempotency_key, scope: :organisation_id
        end)

        stub_const("WeirdPartialEntryModel", Class.new(ActiveRecord::Base) do
          self.table_name = "weird_partial_entries"
          include StandardLedger::Entry
          ledger_entry kind: :kind, idempotency_key: :idempotency_key, scope: :organisation_id
        end)
      end

      after do
        [ PartialIndexEntryModel, WeirdPartialEntryModel ].each { |m| m.unscoped.delete_all }
      end

      it "accepts a partial index with WHERE <key> IS NOT NULL" do
        expect {
          PartialIndexEntryModel.create!(organisation_id: "org-1", kind: "grant", idempotency_key: "p1")
        }.not_to raise_error
      end

      it "still enforces uniqueness against the partial index for non-null keys" do
        first = PartialIndexEntryModel.create!(organisation_id: "org-1", kind: "grant", idempotency_key: "dup")
        second = PartialIndexEntryModel.create!(organisation_id: "org-1", kind: "grant", idempotency_key: "dup")
        expect(second.id).to eq(first.id)
        expect(second.idempotent?).to be(true)
      end

      it "rejects a partial index whose predicate is not <key> IS NOT NULL" do
        expect {
          WeirdPartialEntryModel.create!(organisation_id: "org-1", kind: "grant", idempotency_key: "k")
        }.to raise_error(StandardLedger::MissingIdempotencyIndex, /WHERE predicate must be/)
      end
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

  describe ".standard_ledger_entry?" do
    it "returns true on a class that has called ledger_entry" do
      expect(LedgerEntryModel.standard_ledger_entry?).to be(true)
    end

    it "returns false on a class that includes Entry but never called the macro" do
      expect(PlainModel.standard_ledger_entry?).to be(false)
    end
  end
end
