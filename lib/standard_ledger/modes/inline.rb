module StandardLedger
  module Modes
    # `:inline` mode: applies the projection inside the entry's `after_create`
    # callback, which fires while the host's outer transaction is still open.
    # If the host's transaction rolls back, the projection rolls back too.
    #
    # This is the default for delta-based counter updates. For complex
    # projectors (jsonb shape, multi-row aggregates), use `:async` instead.
    #
    # The strategy is invoked from a single `after_create` callback installed
    # once per entry class (see `.install!`). The callback walks every
    # `:inline`-mode projection registered on the class and runs each via
    # `entry.apply_projection!(definition)`.
    #
    # ## Multi-counter coalescing
    #
    # A single host might register four `on(:grant)`/`on(:redeem)`/... handlers
    # against the same target, each calling `target.increment(:some_count)`.
    # ActiveRecord's `#increment` (vs. `#increment!`) only mutates the
    # in-memory attribute — no SQL is issued — so the strategy persists with
    # a single `target.save!` per (entry, target) pair after all handlers for
    # that target have run. This collapses N handlers into one UPDATE.
    #
    # Definitions targeting different associations get their own
    # apply-then-save cycle, executed in the order the projections were
    # declared.
    #
    # ## Lock semantics
    #
    # When any projection in a per-target group declares `lock: :pessimistic`,
    # the strategy wraps the **entire** apply-then-save cycle for that target
    # in `target.with_lock { ... }`. The lock spans both handler invocation
    # and the coalesced `save!`, so concurrent posts to the same target
    # serialize end-to-end — closing the lost-update window that an
    # inner-only lock would leave open between the lock release and the save.
    # See `standard_ledger-design.md` §5.3.1.
    class Inline
      # Install the `after_create` callback on `entry_class` exactly once.
      # Subsequent calls (e.g. when a second `:inline` projection is added
      # later in the class body) are no-ops — the same callback handles all
      # `:inline` projections registered on the class.
      #
      # @param entry_class [Class] the host entry class.
      # @return [void]
      # @raise [ArgumentError] when `entry_class` is not ActiveRecord-backed
      #   (no `after_create` hook available). `:inline` mode requires AR
      #   transactional callbacks; non-AR entry classes must use a different
      #   mode (or refrain from declaring `:inline` projections).
      def self.install!(entry_class)
        return if entry_class.instance_variable_get(:@_standard_ledger_inline_installed)

        unless entry_class.respond_to?(:after_create)
          raise ArgumentError,
                "#{entry_class.name || entry_class.inspect} cannot use mode: :inline " \
                "because it does not respond to `after_create`. `:inline` mode requires " \
                "an ActiveRecord-backed entry class — use `:async` (or another mode) for " \
                "non-AR includers."
        end

        entry_class.after_create { StandardLedger::Modes::Inline.new.call(self) }
        entry_class.instance_variable_set(:@_standard_ledger_inline_installed, true)
      end

      # Apply every `:inline` projection registered on the entry's class.
      # Called from the `after_create` callback installed by `.install!`.
      #
      # Projections targeting the same association coalesce: all handlers
      # for that target run, then the target is saved once. Different
      # targets get their own apply+save cycle, in declared order. When any
      # definition in a per-target group sets `lock: :pessimistic`, the
      # cycle (apply + save) is wrapped in `target.with_lock`.
      #
      # Records the names of projections that actually ran (after `if:`
      # guards filter) on the entry instance under
      # `@_standard_ledger_applied_projections`, so `StandardLedger.post`
      # can surface an accurate `result.projections[:inline]`.
      #
      # Any projector exception escapes — the entry's transaction rolls
      # back along with every counter mutation that ran before the failure.
      # The `standard_ledger.projection.failed` notification fires before
      # the re-raise so subscribers see the failed projection in payload.
      #
      # @param entry [ActiveRecord::Base] the just-created entry.
      # @return [void]
      def call(entry)
        definitions = inline_definitions_for(entry.class)
        return if definitions.empty?

        applied = []
        entry.instance_variable_set(:@_standard_ledger_applied_projections, applied)

        # group_by preserves insertion order on Ruby >= 1.9, so declared
        # projection order is preserved across targets. Within a target
        # group, handlers run in declared order as well.
        definitions.group_by(&:target_association).each_value do |group|
          target = entry.public_send(group.first.target_association)
          locked = group.any? { |definition| definition.lock == :pessimistic }

          run_group = lambda do
            group.each do |definition|
              ran = instrument_projection(entry, target, definition) do
                entry.apply_projection!(definition)
              end
              applied << definition.target_association if ran && !applied.include?(definition.target_association)
            end

            # Coalesce: if any handler called `target.increment(col)` (which
            # mutates in-memory only), persist the accumulated changes with a
            # single UPDATE. Skipped when the target is nil (apply_projection!
            # short-circuits) or when no handler dirtied the record. The
            # `target` here always responds to AR's `changed?`/`save!` because
            # it's resolved from a `belongs_to` reflection.
            target.save! if target && target.changed?
          end

          if locked && target.respond_to?(:with_lock)
            target.with_lock(&run_group)
          else
            run_group.call
          end
        end
      end

      private

      def inline_definitions_for(entry_class)
        return [] unless entry_class.respond_to?(:standard_ledger_projections_for)

        entry_class.standard_ledger_projections_for(:inline)
      end

      # Wrap each handler invocation so subscribers see exactly one
      # `applied` event per projection on success or one `failed` event on
      # raise. Two distinct events (rather than letting `instrument`
      # package success-or-failure into a single event) because the design
      # splits the two outcomes — see §5.7.
      #
      # When the wrapped `apply_projection!` short-circuits (returns false
      # because of a guard, nil target, or no-handler permissive miss), no
      # `applied` event fires — there's no work to report. The exception
      # path always fires `failed` so observability of failures isn't
      # contingent on guard logic.
      #
      # The exception is re-raised so the entry's transaction rolls back —
      # the notification's payload carries the error for observers
      # regardless of whether the listener swallows or re-raises.
      #
      # @return [Boolean] the truthy/falsy result of the wrapped block —
      #   used by the caller to decide whether to record this projection
      #   in the entry's `applied` list.
      def instrument_projection(entry, target, definition)
        prefix = StandardLedger.config.notification_namespace
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        ran =
          begin
            yield
          rescue StandardError => e
            duration_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0
            StandardLedger::EventEmitter.emit(
              "#{prefix}.projection.failed",
              entry: entry, target: target, projection: definition.target_association,
              error: e, duration_ms: duration_ms
            )
            raise
          end

        return false unless ran

        duration_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0
        StandardLedger::EventEmitter.emit(
          "#{prefix}.projection.applied",
          entry: entry, target: target, projection: definition.target_association,
          mode: :inline, duration_ms: duration_ms
        )
        true
      end
    end
  end
end
