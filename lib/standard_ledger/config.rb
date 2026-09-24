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

    def initialize
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
