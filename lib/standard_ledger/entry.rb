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

        # Read-only enforcement and RecordNotUnique rescue land in a
        # follow-up PR. The current scaffold records the configuration so
        # `Projector` and future `StandardLedger.post` can read it.
      end

      def standard_ledger_entry?
        !standard_ledger_entry_config.nil?
      end
    end

    included do
      class_attribute :standard_ledger_entry_config, instance_writer: false
      self.standard_ledger_entry_config = nil
    end
  end
end
