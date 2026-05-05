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
      # before re-raising). The view name is validated against a SQL-identifier
      # regex at the boundary as a defence-in-depth check — the value normally
      # comes from a `view:` DSL keyword in source code, but a careless host
      # could pass through a config value or other untrusted string. Anything
      # that isn't a bare or schema-qualified identifier raises.
      #
      # The default `:concurrent` strategy (and `concurrently: true` per-call)
      # requires a unique index on the matview — Postgres rejects
      # `REFRESH MATERIALIZED VIEW CONCURRENTLY` otherwise. Hosts who haven't
      # added one should pass `concurrently: false` or set
      # `Config#matview_refresh_strategy = :blocking`.
      #
      # @param view_name [String, Symbol] the materialized view to refresh.
      #   Must match `/\A[a-zA-Z_][a-zA-Z0-9_.]*\z/` so a single dot is
      #   permitted for `schema.view` qualified names.
      # @param concurrently [Boolean] when true, adds `CONCURRENTLY` (which
      #   requires a unique index on the view).
      # @return [void]
      # @raise [ArgumentError] when `view_name` is not a valid SQL identifier.
      # @raise [StandardError] anything the connection raises while running
      #   the SQL — re-raised after the `failed` event fires.
      def self.refresh!(view_name, concurrently:)
        validate_view_name!(view_name)

        prefix = StandardLedger.config.notification_namespace
        sql = build_refresh_sql(view_name, concurrently: concurrently)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        ActiveRecord::Base.connection.execute(sql)

        duration_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0
        StandardLedger::EventEmitter.emit(
          "#{prefix}.projection.refreshed",
          view: view_name.to_s, concurrently: concurrently, duration_ms: duration_ms
        )
      rescue StandardError => e
        # ArgumentError from the validator should propagate without firing
        # the failed notification — the SQL was never issued.
        raise if e.is_a?(ArgumentError)

        StandardLedger::EventEmitter.emit(
          "#{prefix}.projection.failed",
          view: view_name.to_s, concurrently: concurrently, error: e
        )
        raise
      end

      # Reject anything that isn't a bare or schema-qualified SQL identifier
      # — the matching regex allows a leading letter/underscore followed by
      # alphanumerics, underscores, or a single dot for `schema.view`. Names
      # containing semicolons, quotes, comment markers (`--`), whitespace, or
      # other punctuation are rejected at the `refresh!` boundary so SQL
      # injection isn't possible even when a host carelessly pipes a config
      # value into the call.
      def self.validate_view_name!(view_name)
        return if view_name.to_s.match?(/\A[a-zA-Z_][a-zA-Z0-9_.]*\z/)

        raise ArgumentError,
              "view_name must be a valid SQL identifier; got #{view_name.inspect}"
      end
      private_class_method :validate_view_name!

      def self.build_refresh_sql(view_name, concurrently:)
        if concurrently
          "REFRESH MATERIALIZED VIEW CONCURRENTLY #{view_name}"
        else
          "REFRESH MATERIALIZED VIEW #{view_name}"
        end
      end
      private_class_method :build_refresh_sql
    end
  end
end
