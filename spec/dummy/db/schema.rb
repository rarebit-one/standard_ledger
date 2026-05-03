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

  # Entry whose scope column allows NULLs. Used to assert that an attribute
  # hash missing the scope column does NOT match a row where the scope
  # column is null (avoids `WHERE col IS NULL` matching the wrong row).
  create_table :nullable_scope_entries, force: true do |t|
    t.string :organisation_id  # nullable on purpose
    t.string :kind, null: false
    t.string :idempotency_key, null: false
    t.timestamps
  end

  add_index :nullable_scope_entries,
            %i[organisation_id idempotency_key],
            unique: true,
            name: "index_nullable_scope_entries_on_org_and_key"

  # Entry with an additional unique index on a non-idempotency column —
  # used to confirm the rescue narrows to the configured idempotency
  # index and re-raises violations from other unique constraints.
  create_table :extra_unique_entries, force: true do |t|
    t.string :organisation_id, null: false
    t.string :kind, null: false
    t.string :idempotency_key, null: false
    t.string :external_ref, null: false
    t.timestamps
  end

  add_index :extra_unique_entries,
            %i[organisation_id idempotency_key],
            unique: true,
            name: "index_extra_unique_entries_on_org_and_key"

  add_index :extra_unique_entries,
            :external_ref,
            unique: true,
            name: "index_extra_unique_entries_on_external_ref"
end
