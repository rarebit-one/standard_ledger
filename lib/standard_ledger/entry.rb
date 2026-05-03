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
      def create!(attributes = nil, &block)
        config = standard_ledger_entry_config
        return super if config.nil? || config[:idempotency_key].nil?

        validate_standard_ledger_idempotency_index!

        super
      rescue ActiveRecord::RecordNotUnique
        existing = find_existing_standard_ledger_entry(attributes)
        raise if existing.nil?

        existing.instance_variable_set(:@_standard_ledger_idempotent, true)
        existing
      end

      # Verify that the table has a unique index covering exactly
      # `[*scope, idempotency_key]` (column set equality; order-insensitive).
      # Cached so the introspection runs once per class.
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

        find_by(lookup)
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
