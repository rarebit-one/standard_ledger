require "active_support/concern"

module StandardLedger
  # Marks an ActiveRecord model as a ledger entry: an immutable, append-only
  # row that may project onto one or more aggregate targets.
  #
  # Including this concern installs:
  #   - the `ledger_entry` class macro (declares immutability + idempotency)
  #   - read-only behavior post-creation (when `immutable: true`, the default)
  #   - idempotency-by-unique-index (when `idempotency_key:` is non-nil)
  #
  # Projection registration happens via the separate `Projector` concern —
  # the two are decoupled so that an entry can be marked immutable without
  # also opting into projections, and vice versa.
  #
  # @example
  #   class VoucherRecord < ApplicationRecord
  #     include StandardLedger::Entry
  #
  #     ledger_entry kind:            :action,
  #                  idempotency_key: :serial_no,
  #                  scope:           :organisation_id
  #   end
  module Entry
    extend ActiveSupport::Concern

    class_methods do
      # Declare the entry's contract. Stores the configuration on the class
      # for later inspection by `StandardLedger.post`, `Projection.rebuild!`,
      # and the `standard_ledger:doctor` rake task.
      #
      # @param kind [Symbol] the column holding the entry's kind/action
      #   discriminator. Defaults to `:kind`.
      # @param idempotency_key [Symbol, nil] the column whose unique index
      #   guards against duplicate inserts. `nil` means the entry is not
      #   idempotent — explicitly opt-in to that.
      # @param scope [Symbol, Array<Symbol>, nil] additional columns the
      #   idempotency index is scoped by (e.g. `:organisation_id`).
      # @param immutable [Boolean] when true (default), `save`/`update`/
      #   `destroy` raise after the row is persisted.
      def ledger_entry(kind: :kind, idempotency_key: nil, scope: nil, immutable: true)
        self.standard_ledger_entry_config = {
          kind: kind,
          idempotency_key: idempotency_key,
          scope: Array(scope).compact,
          immutable: immutable
        }
        self.standard_ledger_idempotency_index_validated = false
      end

      def standard_ledger_entry?
        !standard_ledger_entry_config.nil?
      end

      # Override AR's `create!` to add idempotency-by-unique-index semantics.
      # When the configured unique constraint trips, look up and return the
      # existing row with `idempotent? == true` instead of raising.
      #
      # @note Block-form `create! { |r| r.field = val }` is not supported for
      #   the idempotent rescue: AR passes `attributes = nil` in that path so
      #   we can't construct the find_by lookup. The rescue still functions
      #   for the rest of the create — a colliding insert from a block-form
      #   call simply re-raises `RecordNotUnique` like vanilla ActiveRecord.
      def create!(attributes = nil, &block)
        config = standard_ledger_entry_config
        return super if config.nil? || config[:idempotency_key].nil?

        validate_standard_ledger_idempotency_index!

        super
      rescue ActiveRecord::RecordNotUnique => e
        raise unless standard_ledger_idempotency_violation?(e)

        existing = find_existing_standard_ledger_entry(attributes)
        raise if existing.nil?

        existing.instance_variable_set(:@_standard_ledger_idempotent, true)
        existing
      end

      # Verify that the table has a unique index covering exactly
      # `[*scope, idempotency_key]` (column set equality; order-insensitive).
      # Cached so the introspection runs once per class.
      #
      # The check-then-set on `standard_ledger_idempotency_index_validated`
      # has a benign race: two threads can both observe `false`, both run the
      # introspection, and both flip the flag to `true`. That's intentional
      # — the validation is pure and idempotent, so duplicate work is cheap
      # and the result is identical. No mutex needed; do not add one.
      def validate_standard_ledger_idempotency_index!
        return if standard_ledger_idempotency_index_validated

        config = standard_ledger_entry_config
        return if config.nil? || config[:idempotency_key].nil?

        required = (config[:scope] + [ config[:idempotency_key] ]).map(&:to_s).to_set
        indexes  = connection.indexes(table_name)

        match = indexes.any? do |index|
          index.unique && index.columns.map(&:to_s).to_set == required
        end

        unless match
          raise StandardLedger::MissingIdempotencyIndex,
                "#{name} declares idempotency_key: #{config[:idempotency_key].inspect} " \
                "with scope: #{config[:scope].inspect} but no matching unique index " \
                "covers exactly #{required.to_a.sort.inspect} on `#{table_name}`."
        end

        self.standard_ledger_idempotency_index_validated = true
      end

      private

      def find_existing_standard_ledger_entry(attributes)
        return nil if attributes.nil?

        config = standard_ledger_entry_config
        lookup_columns = config[:scope] + [ config[:idempotency_key] ]
        attrs = attributes.is_a?(Hash) ? attributes.transform_keys(&:to_sym) : {}
        lookup = lookup_columns.each_with_object({}) do |col, memo|
          memo[col] = attrs[col.to_sym]
        end

        # Bail if any lookup value is nil — `find_by` would emit
        # `WHERE col IS NULL` and could match an unrelated row whose column
        # legitimately holds NULL. We require all idempotency columns to be
        # present in `attributes` to make a confident match.
        return nil if lookup.any? { |_, value| value.nil? }

        find_by(lookup)
      end

      # Confirm the RecordNotUnique was raised by *our* idempotency index,
      # not some other unique constraint on the table (surrogate key,
      # business column, etc.). The wrapped DB exception's message usually
      # mentions the index name or the column list — a substring match on
      # each idempotency column name is good enough across PG/MySQL/SQLite
      # without parsing vendor-specific formats.
      def standard_ledger_idempotency_violation?(exception)
        config = standard_ledger_entry_config
        columns = (config[:scope] + [ config[:idempotency_key] ]).map(&:to_s)
        message = String(exception.message) + String(exception.cause&.message)

        columns.all? { |col| message.include?(col) }
      end
    end

    included do
      class_attribute :standard_ledger_entry_config, instance_writer: false
      class_attribute :standard_ledger_idempotency_index_validated, instance_writer: false
      self.standard_ledger_entry_config = nil
      self.standard_ledger_idempotency_index_validated = false

      before_destroy :standard_ledger_raise_readonly, if: :standard_ledger_immutable?
    end

    # Returns true when this row was returned from an idempotent `create!`
    # rescue — i.e. an existing row matched the unique constraint and was
    # returned instead of inserted.
    def idempotent?
      !!@_standard_ledger_idempotent
    end

    # AR consults `readonly?` from `save`/`update` paths; raising
    # ReadOnlyRecord here matches the ActiveRecord contract for persisted
    # immutable rows. New, unpersisted instances stay writable so the
    # initial INSERT can land.
    def readonly?
      return super unless standard_ledger_immutable?

      !new_record?
    end

    private

    def standard_ledger_immutable?
      config = self.class.standard_ledger_entry_config
      !config.nil? && config[:immutable]
    end

    def standard_ledger_raise_readonly
      raise ActiveRecord::ReadOnlyRecord
    end
  end
end
