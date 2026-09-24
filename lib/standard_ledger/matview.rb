require "active_support/core_ext/string/filters"

module StandardLedger
  # Materialized-view refresh primitive behind `StandardLedger.refresh!`.
  # The host creates and owns the view (via a `scenic` or hand-rolled
  # migration) and schedules refreshes itself; this module only issues the
  # `REFRESH MATERIALIZED VIEW` SQL, decides whether `CONCURRENTLY` is safe
  # when asked to (`concurrently: :auto`), and emits notifications.
  #
  # PostgreSQL only.
  #
  # @api private — call `StandardLedger.refresh!` instead.
  module Matview
    IDENTIFIER = /\A[a-zA-Z_][a-zA-Z0-9_]*(\.[a-zA-Z_][a-zA-Z0-9_]*)?\z/

    # `REFRESH ... CONCURRENTLY` needs a populated view and at least one
    # valid UNIQUE index that uses only column names and covers all rows (no
    # expressions, no WHERE clause). `to_regclass` returns NULL for a
    # missing relation, so a missing view yields no row.
    CONCURRENCY_PROBE_SQL = <<~SQL.squish.freeze
      SELECT c.relispopulated AS populated,
             EXISTS (
               SELECT 1 FROM pg_index i
               WHERE i.indrelid = c.oid
                 AND i.indisunique
                 AND i.indisvalid
                 AND i.indpred IS NULL
                 AND i.indexprs IS NULL
             ) AS unique_index
      FROM pg_class c
      WHERE c.oid = to_regclass(?) AND c.relkind = 'm'
    SQL

    class << self
      # Resolve a requested `concurrently` value (`true`, `false`, `:auto`)
      # to the Boolean actually used for the refresh.
      #
      # @return [Boolean]
      def resolve_concurrently(view_name, requested)
        return requested unless requested == :auto

        validate_view_name!(view_name)
        concurrent_refresh_possible?(view_name)
      end

      # Issue `REFRESH MATERIALIZED VIEW [CONCURRENTLY] <view_name>` and emit
      # `<prefix>.projection.refreshed` on success, or
      # `<prefix>.projection.failed` before re-raising on SQL failure.
      #
      # The view name is validated against a SQL-identifier regex at the
      # boundary as defence in depth — a careless host could pass through a
      # config value or other untrusted string.
      #
      # @param view_name [String, Symbol] bare or `schema.view` identifier.
      # @param concurrently [Boolean]
      # @return [void]
      # @raise [ArgumentError] when `view_name` is not a valid SQL identifier.
      # @raise [StandardLedger::RefreshInsideTransaction] for a concurrent
      #   refresh inside an open transaction.
      def refresh!(view_name, concurrently:)
        validate_view_name!(view_name)
        check_transaction_state!(view_name, concurrently: concurrently)

        prefix = StandardLedger.config.notification_namespace
        sql = build_refresh_sql(view_name, concurrently: concurrently)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        begin
          connection.execute(sql)
        rescue StandardError => e
          StandardLedger::EventEmitter.emit(
            "#{prefix}.projection.failed",
            view: view_name.to_s, concurrently: concurrently, mode: :matview, error: e
          )
          raise
        end

        duration_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0
        StandardLedger::EventEmitter.emit(
          "#{prefix}.projection.refreshed",
          view: view_name.to_s, concurrently: concurrently, duration_ms: duration_ms
        )
      end

      private

      def connection
        ActiveRecord::Base.connection
      end

      # Bare identifier OR exactly one `schema.view` qualification. Names
      # containing semicolons, quotes, comment markers, whitespace, trailing
      # dots or extra qualification are rejected before any SQL is issued.
      def validate_view_name!(view_name)
        return if view_name.to_s.match?(IDENTIFIER)

        raise ArgumentError,
              "view_name must be a valid SQL identifier; got #{view_name.inspect}"
      end

      # `view_name` has already passed `validate_view_name!`. It is left
      # unquoted on purpose: quoting would make the name case-sensitive and
      # change which relation a mixed-case name resolves to.
      def build_refresh_sql(view_name, concurrently:)
        if concurrently
          "REFRESH MATERIALIZED VIEW CONCURRENTLY #{view_name}"
        else
          "REFRESH MATERIALIZED VIEW #{view_name}"
        end
      end

      # Postgres rejects `REFRESH MATERIALIZED VIEW CONCURRENTLY` inside a
      # transaction block; catch it at the gem boundary so the failure is
      # attributable instead of a raw `PG::ActiveSqlTransaction`. The plain
      # form is allowed inside transactions, so only the concurrent path is
      # guarded.
      def check_transaction_state!(view_name, concurrently:)
        return unless concurrently
        return unless connection.transaction_open?

        raise StandardLedger::RefreshInsideTransaction,
              "StandardLedger.refresh!(#{view_name.inspect}) cannot run inside a transaction with " \
              "concurrently: true — Postgres rejects `REFRESH MATERIALIZED VIEW CONCURRENTLY` inside " \
              "transaction blocks. Move the call outside the transaction, defer it via " \
              "`connection.add_transaction_record { ... }`, or pass `concurrently: :auto`."
      end

      # `:auto` decision. A missing view returns false so the plain refresh
      # raises Postgres's own "relation does not exist" error. A failing probe
      # is reported (handled) and degrades to a plain refresh, which is
      # always valid.
      def concurrent_refresh_possible?(view_name)
        return false if connection.transaction_open?

        row = connection.select_one(
          ActiveRecord::Base.sanitize_sql_array([ CONCURRENCY_PROBE_SQL, view_name.to_s ]),
          "StandardLedger refresh probe"
        )
        return false if row.nil?

        boolean(row["populated"]) && boolean(row["unique_index"])
      rescue StandardError => e
        report_error(e, view: view_name.to_s)
        false
      end

      def boolean(value)
        ActiveModel::Type::Boolean.new.cast(value) == true
      end

      def report_error(error, context)
        reporter =
          if defined?(::Rails) && ::Rails.respond_to?(:error)
            ::Rails.error
          elsif ActiveSupport.respond_to?(:error_reporter)
            ActiveSupport.error_reporter
          end
        reporter&.report(error, handled: true, severity: :warning, context: context, source: "standard_ledger")
      end
    end
  end
end
