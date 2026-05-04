require "active_support/concern"
require "active_support/core_ext/class/attribute"

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
      :target_association, :mode, :projector_class, :handlers, :guard, :lock, :permissive,
      :recompute_sql, :options,
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

        if mode == :sql
          if via
            raise ArgumentError,
                  "projects_onto :#{target_association} got `via:` with mode: :sql; " \
                  "`:sql` mode's contract is the recompute SQL itself, declared via `recompute \"...\"` " \
                  "in the block — use a different mode if you want a `via:` projector class"
          end

          unless block
            raise ArgumentError,
                  "projects_onto :#{target_association} requires a block with `recompute \"...\"` for mode: :sql"
          end

          dsl = SqlDsl.new
          dsl.instance_eval(&block)

          if dsl.recompute_sql.nil?
            raise ArgumentError,
                  "projects_onto :#{target_association} block is empty; mode: :sql requires a `recompute \"...\"` clause"
          end

          unless dsl.recompute_sql.include?(":target_id")
            raise ArgumentError,
                  "projects_onto :#{target_association} recompute SQL must include the `:target_id` placeholder; " \
                  "it's bound to the entry's foreign key for this projection's target"
          end

          definition = Definition.new(
            target_association: target_association,
            mode: mode,
            projector_class: nil,
            handlers: {},
            guard: guard,
            lock: lock,
            permissive: permissive,
            recompute_sql: dsl.recompute_sql,
            options: options
          )

          self.standard_ledger_projections = standard_ledger_projections + [ definition ]
          install_mode_callbacks_for(definition)
          return definition
        end

        if block && via
          raise ArgumentError,
                "projects_onto :#{target_association} got both a block and `via:`; the two forms are mutually exclusive"
        end

        unless block || via
          raise ArgumentError,
                "projects_onto :#{target_association} requires either a block of `on(:kind) { ... }` handlers or `via: ProjectorClass`"
        end

        if via && permissive
          raise ArgumentError,
                "projects_onto :#{target_association} got `permissive: true` with `via:`; " \
                "`permissive:` is only meaningful with the block form, since the class form has " \
                "no per-kind handlers and runs unconditionally"
        end

        handlers = {}
        if block
          dsl = HandlerDsl.new
          dsl.instance_eval(&block)
          handlers = dsl.handlers

          if handlers.empty?
            raise ArgumentError,
                  "projects_onto :#{target_association} block is empty; at least one `on(:kind) { ... }` handler is required"
          end
        end

        definition = Definition.new(
          target_association: target_association,
          mode: mode,
          projector_class: via,
          handlers: handlers,
          guard: guard,
          lock: lock,
          permissive: permissive,
          recompute_sql: nil,
          options: options
        )

        self.standard_ledger_projections = standard_ledger_projections + [ definition ]
        install_mode_callbacks_for(definition)
        definition
      end

      # Delegate per-mode callback installation to the matching strategy
      # class. Keeps `Modes::*` from reaching into `Projector`'s internals
      # — each strategy gets a chance to wire up `after_create`,
      # `after_create_commit`, or whatever lifecycle hook it needs the first
      # time a projection of its mode is registered on this class.
      #
      # @param definition [Definition]
      # @return [void]
      def install_mode_callbacks_for(definition)
        case definition.mode
        when :inline
          StandardLedger::Modes::Inline.install!(self)
        when :sql
          StandardLedger::Modes::Sql.install!(self)
        end
      end

      # Filter the registered projections by mode. Used by the per-mode
      # strategy classes (`Modes::Inline`, `Modes::Async`, ...) to discover
      # which projections they own for a given entry class.
      #
      # @param mode [Symbol] one of `:inline`, `:async`, `:sql`, `:trigger`,
      #   `:matview`.
      # @return [Array<Definition>] the matching definitions, in declared order.
      def standard_ledger_projections_for(mode)
        standard_ledger_projections.select { |definition| definition.mode == mode }
      end
    end

    included do
      class_attribute :standard_ledger_projections, instance_writer: false
      self.standard_ledger_projections = []
    end

    # Apply a single projection definition to this entry. Resolves the
    # target association, evaluates the optional `if:` guard, looks up the
    # per-kind handler (or falls back to the projector class), and invokes
    # it.
    #
    # `lock:` is interpreted by the mode strategies (`Modes::Inline`, ...)
    # — not here. The inline strategy needs the lock to span both the
    # handler invocation *and* the coalesced `target.save!`, so it wraps
    # an entire per-target group rather than a single `apply_projection!`
    # call. See `Modes::Inline#call` for the lock-spans-save guarantee.
    #
    # The mode strategies call this method; hosts typically do not call it
    # directly.
    #
    # @param definition [Definition] one of the entry class's registered
    #   projections.
    # @return [Boolean] `true` when the handler (or projector class) ran;
    #   `false` when the projection short-circuited (guard returned false,
    #   target was nil, or permissive mode found no matching handler).
    # @raise [StandardLedger::Error] when the entry's kind column is nil.
    # @raise [StandardLedger::UnhandledKind] when no handler matches and
    #   `permissive: false`.
    def apply_projection!(definition)
      if definition.mode == :sql
        raise Error,
              "apply_projection! is not supported for mode: :sql; " \
              "the recompute SQL runs through `Modes::Sql#call` directly with no per-kind dispatch"
      end

      return false if definition.guard && !instance_exec(&definition.guard)

      target = public_send(definition.target_association)
      return false if target.nil?

      if definition.projector_class
        definition.projector_class.new.apply(target, self)
        return true
      end

      kind = resolve_kind!
      handler = definition.handlers[kind.to_sym]

      if handler.nil?
        if definition.permissive
          handler = definition.handlers[:_]
          return false if handler.nil?
        else
          raise UnhandledKind,
                "#{self.class.name} has no handler for kind=#{kind.inspect} on projection :#{definition.target_association}"
        end
      end

      handler.call(target, self)
      true
    end

    private

    def resolve_kind!
      unless self.class.respond_to?(:standard_ledger_entry_config)
        raise Error,
              "#{self.class.name} includes Projector but not Entry; " \
              "`ledger_entry` must be called before apply_projection! can dispatch"
      end

      kind_column = self.class.standard_ledger_entry_config&.[](:kind) || :kind
      kind = public_send(kind_column)
      if kind.nil?
        raise Error,
              "#{self.class.name} entry has nil kind (column #{kind_column.inspect}); cannot dispatch projection"
      end
      kind
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

    # Internal collector for the `:sql`-mode block-DSL form. Captures the
    # `recompute "..."` clause's SQL string. Unlike `HandlerDsl` there are
    # no per-kind handlers — the recompute SQL is the entire contract: it
    # must be expressible as a single statement with `:target_id` bound
    # from the entry's foreign key, and it serves both the after-create
    # path and `StandardLedger.rebuild!`.
    class SqlDsl
      attr_reader :recompute_sql

      def recompute(sql)
        unless sql.is_a?(String)
          raise ArgumentError, "recompute requires a SQL string; got #{sql.class}"
        end
        @recompute_sql = sql
      end
    end
  end
end
