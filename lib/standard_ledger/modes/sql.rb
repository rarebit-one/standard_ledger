module StandardLedger
  module Modes
    # `:sql` mode: applies the projection by running a single recompute
    # `UPDATE` against the target table, inside the entry's `after_create`
    # callback. The recompute SQL is supplied via the block-DSL's
    # `recompute "..."` clause; the `:target_id` placeholder is bound to
    # the foreign-key value the entry holds for the target association.
    #
    # Lower-overhead than `:inline` for projections expressible as
    # `UPDATE target SET col = (SELECT aggregate(...) FROM entries WHERE
    # ...)` — there's no Ruby-side handler invocation, no per-counter
    # in-memory mutation, and no AR object load. Naturally rebuildable:
    # `StandardLedger.rebuild!` runs the same statement against each
    # target the log references, so the `after_create` and `rebuild!`
    # paths share the same recompute SQL.
    #
    # Like `:inline`, this fires from `after_create` (in the entry's
    # transaction), so failures roll the entry back alongside the
    # projection. The notification payload's `:target` field is `nil` for
    # `:sql` mode — loading the target object would defeat the point of
    # the mode (it's meant to avoid Ruby-side reads). Subscribers get
    # `entry`, the projection definition, and the timing.
    class Sql
      # Install the `after_create` callback on `entry_class` exactly once.
      # Subsequent calls (e.g. when a second `:sql` projection is added
      # later in the class body) are no-ops — the same callback handles
      # all `:sql` projections registered on the class.
      #
      # @param entry_class [Class] the host entry class.
      # @return [void]
      # @raise [ArgumentError] when `entry_class` is not ActiveRecord-backed
      #   (no `after_create` hook available). `:sql` mode requires an
      #   AR-backed entry class — the recompute SQL runs through
      #   `entry.class.connection.exec_update`.
      def self.install!(entry_class)
        return if entry_class.instance_variable_get(:@_standard_ledger_sql_installed)

        unless entry_class.respond_to?(:after_create)
          raise ArgumentError,
                "#{entry_class.name || entry_class.inspect} cannot use mode: :sql " \
                "because it does not respond to `after_create`. `:sql` mode requires " \
                "an ActiveRecord-backed entry class."
        end

        entry_class.after_create { StandardLedger::Modes::Sql.new.call(self) }
        entry_class.instance_variable_set(:@_standard_ledger_sql_installed, true)
      end

      # Apply every `:sql` projection registered on the entry's class.
      # Called from the `after_create` callback installed by `.install!`.
      #
      # For each definition: resolve the target's foreign key from the
      # entry, evaluate the optional `if:` guard, and run the recompute
      # SQL with `:target_id` bound to the FK value.
      #
      # A nil FK (target unset for this entry) is silently skipped — the
      # entry simply doesn't project onto a target this round. A guard
      # returning false is also silently skipped.
      #
      # Any exception raised by the SQL escapes — the entry's transaction
      # rolls back with the projection. The
      # `<prefix>.projection.failed` notification fires before the
      # re-raise so subscribers see the failure.
      #
      # @param entry [ActiveRecord::Base] the just-created entry.
      # @return [void]
      def call(entry)
        definitions = sql_definitions_for(entry.class)
        return if definitions.empty?

        definitions.each do |definition|
          next if definition.guard && !entry.instance_exec(&definition.guard)

          target_id = resolve_target_id(entry, definition)
          next if target_id.nil?

          run_recompute_sql(entry, definition, target_id)
        end
      end

      private

      def sql_definitions_for(entry_class)
        return [] unless entry_class.respond_to?(:standard_ledger_projections_for)

        entry_class.standard_ledger_projections_for(:sql)
      end

      # Pull the FK value off the entry without loading the target. The
      # reflection's `foreign_key` is the column name (e.g.
      # `"voucher_scheme_id"`); reading it via `public_send` avoids
      # triggering an AR association load.
      def resolve_target_id(entry, definition)
        reflection = entry.class.reflect_on_association(definition.target_association)
        return nil if reflection.nil?

        entry.public_send(reflection.foreign_key)
      end

      # Run the recompute statement, instrumenting success and failure
      # symmetrically with the inline mode's two-event split. The target
      # is intentionally `nil` in the payload — loading it would defeat
      # the mode's "no Ruby-side reads" contract; subscribers that want
      # the target should reload it themselves from the
      # `definition.target_association` + the entry.
      def run_recompute_sql(entry, definition, target_id)
        prefix = StandardLedger.config.notification_namespace
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        begin
          sql = ActiveRecord::Base.sanitize_sql_array([ definition.recompute_sql, { target_id: target_id } ])
          entry.class.connection.exec_update(sql)
        rescue StandardError => e
          duration_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0
          ActiveSupport::Notifications.instrument(
            "#{prefix}.projection.failed",
            entry: entry, target: nil, projection: definition, error: e, duration_ms: duration_ms
          )
          raise
        end

        duration_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0
        ActiveSupport::Notifications.instrument(
          "#{prefix}.projection.applied",
          entry: entry, target: nil, projection: definition,
          mode: :sql, duration_ms: duration_ms
        )
      end
    end
  end
end
