ActiveRecord::Schema.define do
  # Entry shape with idempotency_key + scope. Mirrors the canonical
  # voucher_records table just enough to exercise the unique-index check
  # and RecordNotUnique rescue.
  create_table :ledger_entries, force: true do |t|
    t.string :organisation_id, null: false
    t.string :kind, null: false
    t.string :idempotency_key, null: false
    t.string :payload
    t.timestamps
  end

  add_index :ledger_entries,
            %i[organisation_id idempotency_key],
            unique: true,
            name: "index_ledger_entries_on_org_and_key"

  # Mutable entry — same shape but no unique index needed because we
  # opt out of immutability via `immutable: false`.
  create_table :mutable_entries, force: true do |t|
    t.string :kind, null: false
    t.string :payload
    t.timestamps
  end

  # Entry with no scope — exercises idempotency on a single column.
  create_table :unscoped_entries, force: true do |t|
    t.string :kind, null: false
    t.string :idempotency_key, null: false
    t.timestamps
  end

  add_index :unscoped_entries, :idempotency_key, unique: true

  # Entry whose unique index covers EXTRA columns beyond the configured
  # scope+idempotency_key set — should fail the boot-time check.
  create_table :wide_index_entries, force: true do |t|
    t.string :organisation_id, null: false
    t.string :kind, null: false
    t.string :idempotency_key, null: false
    t.timestamps
  end

  add_index :wide_index_entries,
            %i[organisation_id kind idempotency_key],
            unique: true,
            name: "index_wide_index_entries_extra"

  # Entry that declares idempotency_key but has NO matching unique index.
  create_table :missing_index_entries, force: true do |t|
    t.string :organisation_id, null: false
    t.string :kind, null: false
    t.string :idempotency_key, null: false
    t.timestamps
  end

  # Entry with idempotency_key: nil — no index requirement.
  create_table :no_idempotency_entries, force: true do |t|
    t.string :kind, null: false
    t.string :payload
    t.timestamps
  end
end
