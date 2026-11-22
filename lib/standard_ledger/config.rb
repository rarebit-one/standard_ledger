module StandardLedger
  # Host-configurable settings, populated via `StandardLedger.configure { |c| ... }`
  # in an initializer. All attributes have sensible defaults; hosts only override
  # what they need.
  #
  # @see StandardLedger.configure
  class Config
    # Default for `StandardLedger.refresh!` calls that omit `concurrently:`.
    # One of:
    #
    # - `:concurrent` (default) — `REFRESH MATERIALIZED VIEW CONCURRENTLY`;
    #   requires a populated view with a unique index, outside a transaction.
    # - `:blocking` — plain `REFRESH MATERIALIZED VIEW`.
    # - `:auto` — concurrent when possible, plain otherwise (see
    #   `StandardLedger.refresh!`).
    attr_accessor :matview_refresh_strategy

    # Optional: the host application's Result class. When set together with
    # `result_adapter`, `StandardLedger.post` and `StandardLedger.refresh!`
    # return instances of this class instead of `StandardLedger::Result`.
    attr_accessor :result_class

    # Optional: a callable that translates the gem's result fields into the
    # host's Result type. Receives keyword args:
    # `success:, value:, errors:, entry:, idempotent:, projections:`.
    # Required when `result_class` is set.
    attr_accessor :result_adapter

    # Prefix for events emitted by the gem (via `Rails.event` on Rails 8.1+,
    # `ActiveSupport::Notifications` otherwise). Default: `"standard_ledger"`.
    # Events: `<prefix>.entry.created`, `<prefix>.projection.refreshed`,
    # `<prefix>.projection.failed`.
    attr_accessor :notification_namespace

    # Optional: where the gem sends the errors it reports — a failed
    # `refresh!` (re-raised after reporting) and a failing `:auto` catalog
    # probe (handled; the refresh runs plain). A callable taking
    # `(error, context)`. `context` is the site's Hash (`view:`, plus
    # `concurrently:` for a failed refresh) merged with
    # `source: "standard_ledger"`, `handled:` and `severity:`, so a reporter
    # can tell the re-raised refresh error from the handled probe failure.
    #
    # nil (the default) means `Rails.error.report` (or
    # `ActiveSupport.error_reporter` outside Rails) with `handled:`,
    # `severity:` and `source: "standard_ledger"` as keywords:
    #
    #   c.error_reporter = ->(error, context) { Sentry.capture_exception(error, extra: context) }
    #
    # It replaces the Rails.error call. Rails.error's dedupe (it skips an
    # exception it has already reported) does not apply to a custom reporter,
    # so a host that also reports the re-raised refresh error sees it twice.
    # A reporter that raises is swallowed and never masks the original error.
    attr_accessor :error_reporter

    def initialize
      @matview_refresh_strategy = :concurrent
      @result_class             = nil
      @result_adapter           = nil
      @notification_namespace   = "standard_ledger"
      @error_reporter           = nil
    end

    # True when the host has wired up its own Result type. When false, the gem
    # returns its built-in `StandardLedger::Result`.
    def custom_result?
      !result_class.nil? && !result_adapter.nil?
    end
  end
end
