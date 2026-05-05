module StandardLedger
  # Host-configurable settings, populated via `StandardLedger.configure { |c| ... }`
  # in an initializer. All attributes have sensible defaults; hosts only override
  # what they need.
  #
  # @see StandardLedger.configure
  class Config
    # The ActiveJob class used by `:async` mode projections. Defaults to
    # `StandardLedger::ProjectionJob`. Hosts can supply their own job class
    # (e.g. for custom queue routing or per-projection telemetry) via
    # `c.default_async_job = Orders::FulfillableProjectionJob`.
    attr_accessor :default_async_job

    # Total attempts (including the first) for an `:async` projection before
    # the failure is propagated. Default: 3 (one initial run + two retries).
    # Matches ActiveJob's `retry_on attempts:` semantics.
    attr_accessor :default_async_retries

    # Scheduler backend for `:matview` refresh jobs. One of
    # `:solid_queue`, `:sidekiq_cron`, `:custom`. Default: `:solid_queue`
    # (matches all four consuming apps).
    attr_accessor :scheduler

    # Default refresh strategy for `:matview` projections. Either
    # `:concurrent` (REFRESH MATERIALIZED VIEW CONCURRENTLY — requires a
    # unique index on the view) or `:blocking`. Default: `:concurrent`.
    attr_accessor :matview_refresh_strategy

    # Optional: the host application's Result class. When set together with
    # `result_adapter`, `StandardLedger.post` returns instances of this class
    # instead of `StandardLedger::Result`.
    attr_accessor :result_class

    # Optional: a callable that translates the gem's result fields into the
    # host's Result type. Receives keyword args:
    # `success:, value:, errors:, entry:, idempotent:, projections:`.
    # Required when `result_class` is set.
    attr_accessor :result_adapter

    # Prefix for `ActiveSupport::Notifications` events emitted by the gem.
    # Default: `"standard_ledger"`. Events:
    # `<prefix>.entry.created`, `<prefix>.projection.applied`,
    # `<prefix>.projection.failed`, `<prefix>.projection.refreshed`,
    # `<prefix>.projection.rebuilt`.
    attr_accessor :notification_namespace

    def initialize
      @default_async_job        = nil   # resolved lazily to avoid loading the job constant before Rails boots
      @default_async_retries    = 3
      @scheduler                = :solid_queue
      @matview_refresh_strategy = :concurrent
      @result_class             = nil
      @result_adapter           = nil
      @notification_namespace   = "standard_ledger"
    end

    # True when the host has wired up its own Result type. When false, the gem
    # returns its built-in `StandardLedger::Result`.
    def custom_result?
      !result_class.nil? && !result_adapter.nil?
    end
  end
end
