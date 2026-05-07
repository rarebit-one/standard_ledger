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

  # Entry with a *partial* unique index — its WHERE predicate constrains
  # uniqueness to rows where the idempotency key is non-null. The gem
  # accepts this shape: rows with a present key are deduped, rows without
  # one are opting out of idempotency. Used by the entry_spec partial-
  # index test.
  create_table :partial_index_entries, force: true do |t|
    t.string :organisation_id, null: false
    t.string :kind, null: false
    t.string :idempotency_key  # nullable
    t.timestamps
  end

  add_index :partial_index_entries,
            %i[organisation_id idempotency_key],
            unique: true,
            where: "idempotency_key IS NOT NULL",
            name: "index_partial_index_entries_partial"

  # Entry with a partial unique index whose predicate is *not* the
  # accepted `<col> IS NOT NULL` shape. The gem rejects this — the
  # predicate could exclude rows we'd expect to be deduped, and matching
  # arbitrary predicates would need a SQL parser.
  create_table :weird_partial_entries, force: true do |t|
    t.string :organisation_id, null: false
    t.string :kind, null: false
    t.string :idempotency_key, null: false
    t.boolean :archived, null: false, default: false
    t.timestamps
  end

  add_index :weird_partial_entries,
            %i[organisation_id idempotency_key],
            unique: true,
            where: "archived = false",
            name: "index_weird_partial_entries_only_active"

  # Parent + child tables exercising `allow_destroy: true` under a real
  # `dependent: :destroy` cascade, not just direct `entry.destroy!`. The
  # entry_spec uses these to assert that destroying the parent reaps the
  # children even when the entry is `immutable: true`.
  create_table :cascade_parents, force: true do |t|
    t.string :name
    t.timestamps
  end

  create_table :cascade_child_entries, force: true do |t|
    t.integer :cascade_parent_id, null: false
    t.string  :kind, null: false
    t.string  :payload
    t.timestamps
  end

  # ---------------------------------------------------------------------------
  # Tables exercised by spec/standard_ledger/inline_integration_spec.rb.
  #
  # Two projection-target tables (voucher_schemes, customer_profiles), each
  # with a counter the inline projection increments. The voucher_records
  # table is the entry, with belongs_to FKs to both targets and the
  # idempotency unique index expected by `Entry`.
  # ---------------------------------------------------------------------------

  create_table :voucher_schemes, force: true do |t|
    t.string  :name, null: false
    t.integer :granted_vouchers_count, null: false, default: 0
    t.integer :redeemed_vouchers_count, null: false, default: 0
    t.integer :consumed_vouchers_count, null: false, default: 0
    t.integer :clawed_back_vouchers_count, null: false, default: 0
    t.timestamps
  end

  create_table :customer_profiles, force: true do |t|
    t.string  :name, null: false
    t.integer :granted_vouchers_count, null: false, default: 0
    t.integer :redeemed_vouchers_count, null: false, default: 0
    t.integer :consumed_vouchers_count, null: false, default: 0
    t.integer :clawed_back_vouchers_count, null: false, default: 0
    t.timestamps
  end

  create_table :voucher_records, force: true do |t|
    t.string  :organisation_id, null: false
    t.string  :action, null: false
    t.string  :serial_no, null: false
    t.integer :voucher_scheme_id
    t.integer :customer_profile_id
    t.timestamps
  end

  add_index :voucher_records,
            %i[organisation_id serial_no],
            unique: true,
            name: "index_voucher_records_on_org_and_serial"
end
