module StandardLedger
  module Modes
    # `:async` mode: applies the projection in a background job enqueued
    # from the entry's `after_create_commit` callback. The job runs after
    # the outer transaction has committed, so the entry is durable before
    # the projection runs — and a job failure does NOT roll back the entry.
    #
    # Used when the projection is too expensive or stateful for the entry's
    # transaction (jsonb rebuild, multi-row aggregate). The canonical
    # example is nutripod's `Order#payable_balance` / `Order#fulfillable_balance`
    # jsonb columns, which need to be recomputed from every PaymentRecord /
    # FulfillmentRecord against the order — work that's safe to defer past
    # the originating transaction.
    #
    # Class-form only: `:async` projections must declare `via: ProjectorClass`,
    # whose `apply(target, entry)` should recompute from the log inside
    # `with_lock` rather than apply a delta. Block-form per-kind handlers
    # aren't safe under retry — incrementing a counter twice on retry is a
    # silent data corruption bug — so block-form is rejected at registration
    # time (see `Projector#projects_onto`).
    #
    # The strategy installs an `after_create_commit` callback once per entry
    # class. The callback walks every `:async`-mode projection registered on
    # the class and enqueues `StandardLedger::ProjectionJob` per (entry,
    # projection) pair, honoring the optional `if:` guard.
    #
    # ## with_modes interop
    #
    # `StandardLedger.with_modes(EntryClass => :inline) { ... }` forces async
    # projections to run synchronously inside the block — useful in unit
    # specs that want end-to-end coverage without standing up a job runner.
    # Inline-override mode skips the enqueue and runs `target.with_lock {
    # projector.apply(target, entry) }` directly. The override is read in
    # `#call`; specs can capture the empty job queue via `have_enqueued_job`
    # / `perform_enqueued_jobs` and still observe the projection's effects.
    class Async
      # Install the `after_create_commit` callback on `entry_class` exactly
      # once. Subsequent calls (e.g. when a second `:async` projection is
      # added later in the class body) are no-ops — the same callback
      # handles all `:async` projections registered on the class.
      #
      # @param entry_class [Class] the host entry class.
      # @return [void]
      # @raise [ArgumentError] when `entry_class` is not ActiveRecord-backed
      #   (no `after_create_commit` hook available). `:async` mode requires
      #   AR transactional callbacks; non-AR entry classes can't dispatch
      #   the post-commit enqueue.
      def self.install!(entry_class)
        return if entry_class.instance_variable_get(:@_standard_ledger_async_installed)

        unless entry_class.respond_to?(:after_create_commit)
          raise ArgumentError,
                "Modes::Async requires an ActiveRecord-backed entry class on " \
                "#{entry_class.name || entry_class.inspect} — add `belongs_to :entry_class` " \
                "lookups via AR; use :inline mode for plain Ruby"
        end

        entry_class.after_create_commit { StandardLedger::Modes::Async.new.call(self) }
        entry_class.instance_variable_set(:@_standard_ledger_async_installed, true)
      end

      # Enqueue `ProjectionJob` for every `:async` projection registered on
      # the entry's class. Called from the `after_create_commit` callback
      # installed by `.install!`.
      #
      # Honors the optional `if:` guard (skips enqueue when guard returns
      # false) and `StandardLedger.mode_override_for(entry_class)` (when set
      # to `:inline`, runs the projection synchronously inside `with_lock`
      # instead of enqueueing).
      #
      # A nil target at enqueue time skips silently — the entry's FK was
      # unset for this projection's association, so there's nothing to
      # project onto. (The job has its own nil-target guard; this short-
      # circuit just avoids the wasted enqueue.)
      #
      # @param entry [ActiveRecord::Base] the just-committed entry.
      # @return [void]
      def call(entry)
        definitions = async_definitions_for(entry.class)
        return if definitions.empty?

        override = StandardLedger.mode_override_for(entry.class)

        definitions.each do |definition|
          next if definition.guard && !entry.instance_exec(&definition.guard)

          if override == :inline
            run_inline(entry, definition)
          else
            target = entry.public_send(definition.target_association)
            next if target.nil?

            StandardLedger::ProjectionJob.perform_later(entry, definition.target_association.to_s)
          end
        end
      end

      private

      def async_definitions_for(entry_class)
        return [] unless entry_class.respond_to?(:standard_ledger_projections_for)

        entry_class.standard_ledger_projections_for(:async)
      end

      # `with_modes(EntryClass => :inline)` short-circuit: run the projector
      # synchronously inside `with_lock`, mirroring the job's behavior
      # without the enqueue. Skips silently when the target is nil so the
      # nil-FK contract matches the enqueue path.
      def run_inline(entry, definition)
        target = entry.public_send(definition.target_association)
        return if target.nil?

        prefix = StandardLedger.config.notification_namespace
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        begin
          target.with_lock do
            definition.projector_class.new.apply(target, entry)
          end
        rescue StandardError => e
          duration_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0
          StandardLedger::EventEmitter.emit(
            "#{prefix}.projection.failed",
            entry: entry, target: target, projection: definition.target_association,
            mode: :async, error: e, duration_ms: duration_ms, attempt: 1
          )
          raise
        end

        duration_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0
        StandardLedger::EventEmitter.emit(
          "#{prefix}.projection.applied",
          entry: entry, target: target, projection: definition.target_association,
          mode: :async, duration_ms: duration_ms, attempt: 1
        )
      end
    end
  end
end
