module StandardLedger
  module Modes
    # `:matview` mode: backs the projection with a host-owned PostgreSQL
    # materialized view. The host creates and owns the view (via a migration —
    # `scenic` or hand-rolled SQL); the gem owns the refresh schedule and the
    # ad-hoc refresh API.
    #
    # Unlike `:inline`, this strategy does NOT install a per-entry callback —
    # matview projections are scheduled, not entry-driven. The strategy's job
    # is to (a) record the matview registration on the entry class so callers
    # can enumerate `:matview` projections (used by `StandardLedger.rebuild!`
    # and the host's scheduler wiring), and (b) provide the `#refresh!`
    # primitive that issues the actual `REFRESH MATERIALIZED VIEW` SQL.
    #
    # Hosts wire their scheduler (SolidQueue Recurring Tasks, sidekiq-cron,
    # etc.) at `StandardLedger::MatviewRefreshJob` to drive scheduled
    # refreshes. Ad-hoc refreshes go through `StandardLedger.refresh!` for
    # read-your-write semantics after a critical write.
    #
    # See `standard_ledger-design.md` §5.3.5 for the full contract.
    class Matview
      # Mark the entry class as having at least one `:matview` projection
      # registered. The actual matview definition lives on the entry class's
      # `standard_ledger_projections` array; this method exists only to
      # mirror the `Modes::Inline.install!` shape and to mark the class so
      # repeated registrations are recognised as idempotent installs.
      #
      # Idempotent — multiple `:matview` projections on the same entry class
      # do not cause double registration. Unlike `:inline`, no `after_create`
      # callback is installed.
      #
      # @param entry_class [Class] the host entry class.
      # @return [void]
      def self.install!(entry_class)
        return if entry_class.instance_variable_get(:@_standard_ledger_matview_installed)

        entry_class.instance_variable_set(:@_standard_ledger_matview_installed, true)
      end

      # Issue `REFRESH MATERIALIZED VIEW [CONCURRENTLY] <view_name>` against
      # the active connection and emit the standard `<prefix>.projection.refreshed`
      # notification on success (or `<prefix>.projection.failed` on raise,
      # before re-raising). The view name is interpolated as-is — callers
      # are responsible for ensuring it's a trusted identifier (the gem
      # owns this only via host-supplied DSL keywords).
      #
      # @param view_name [String, Symbol] the materialized view to refresh.
      # @param concurrently [Boolean] when true, adds `CONCURRENTLY` (which
      #   requires a unique index on the view).
      # @return [void]
      # @raise [StandardError] anything the connection raises while running
      #   the SQL — re-raised after the `failed` event fires.
      def refresh!(view_name, concurrently:)
        prefix = StandardLedger.config.notification_namespace
        sql = build_refresh_sql(view_name, concurrently: concurrently)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        ActiveRecord::Base.connection.execute(sql)

        duration_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0
        ActiveSupport::Notifications.instrument(
          "#{prefix}.projection.refreshed",
          view: view_name.to_s, concurrently: concurrently, duration_ms: duration_ms
        )
      rescue StandardError => e
        ActiveSupport::Notifications.instrument(
          "#{prefix}.projection.failed",
          view: view_name.to_s, concurrently: concurrently, error: e
        )
        raise
      end

      private

      def build_refresh_sql(view_name, concurrently:)
        if concurrently
          "REFRESH MATERIALIZED VIEW CONCURRENTLY #{view_name}"
        else
          "REFRESH MATERIALIZED VIEW #{view_name}"
        end
      end
    end
  end
end
