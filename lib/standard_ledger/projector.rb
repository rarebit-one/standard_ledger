require "active_support/concern"

module StandardLedger
  # Adds the `projects_onto` DSL to an Entry class. Each `projects_onto`
  # declaration registers a single (target_association, mode, projector)
  # tuple; multi-target fan-out is two declarations.
  #
  # @example block form
  #   class VoucherRecord < ApplicationRecord
  #     include StandardLedger::Entry
  #     include StandardLedger::Projector
  #
  #     ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id
  #
  #     projects_onto :voucher_scheme, mode: :inline do
  #       on(:grant)    { |scheme, _| scheme.increment(:granted_vouchers_count) }
  #       on(:redeem)   { |scheme, _| scheme.increment(:redeemed_vouchers_count) }
  #       on(:consume)  { |scheme, _| scheme.increment(:consumed_vouchers_count) }
  #       on(:clawback) { |scheme, _| scheme.increment(:clawed_back_vouchers_count) }
  #     end
  #   end
  #
  # @example class form
  #   projects_onto :order, mode: :async, via: Orders::FulfillableProjector
  module Projector
    extend ActiveSupport::Concern

    # Captures the per-projection configuration declared by `projects_onto`.
    # Stored on the entry class so `StandardLedger.post` and
    # `StandardLedger.rebuild!` can iterate over them at runtime.
    Definition = Struct.new(
      :target_association, :mode, :projector_class, :handlers, :guard, :lock, :permissive, :options,
      keyword_init: true
    )

    class_methods do
      # Declare a projection from this entry onto a single target.
      #
      # @param target_association [Symbol] the `belongs_to` association name on
      #   this entry pointing at the projection target.
      # @param mode [Symbol] one of `:inline`, `:async`, `:sql`, `:trigger`,
      #   `:matview`. See the design doc §5.3 for selection guidance.
      # @param via [Class, nil] optional `Projection` subclass; required for
      #   `:async`/`:trigger`/`:sql` modes when the projector is non-trivial,
      #   optional for `:inline` when a block is given.
      # @param if [Proc, nil] optional guard; the projection is skipped when
      #   the proc (evaluated in the entry's instance context) returns false.
      # @param lock [Symbol, nil] `:pessimistic` to wrap inline updates in
      #   `target.with_lock { ... }`. Default: `nil` (optimistic).
      # @param permissive [Boolean] when true, an entry with a kind not
      #   handled by `on(:kind)` is silently skipped instead of raising
      #   `UnhandledKind`. Default: false.
      # @yield optional block-DSL form: register per-kind handlers via
      #   `on(:kind) { |target, entry| ... }`.
      # @return [Definition] the registered projection.
      def projects_onto(target_association, mode:, via: nil, if: nil, lock: nil, permissive: false, **options, &block)
        guard = binding.local_variable_get(:if) # `if:` is a reserved keyword

        handlers = {}
        if block
          dsl = HandlerDsl.new
          dsl.instance_eval(&block)
          handlers = dsl.handlers
        end

        definition = Definition.new(
          target_association: target_association,
          mode: mode,
          projector_class: via,
          handlers: handlers,
          guard: guard,
          lock: lock,
          permissive: permissive,
          options: options
        )

        self.standard_ledger_projections = standard_ledger_projections + [ definition ]
        definition
      end
    end

    included do
      class_attribute :standard_ledger_projections, instance_writer: false
      self.standard_ledger_projections = []
    end

    # Internal collector for the block-DSL form. Captures `on(:kind)` calls
    # into a hash keyed by kind. Wildcard `on(:_)` is reserved as a catch-all
    # — its handler runs only when no specific-kind handler matched.
    class HandlerDsl
      attr_reader :handlers

      def initialize
        @handlers = {}
      end

      def on(kind, &block)
        raise ArgumentError, "on(:#{kind}) requires a block" unless block
        @handlers[kind.to_sym] = block
      end
    end
  end
end
