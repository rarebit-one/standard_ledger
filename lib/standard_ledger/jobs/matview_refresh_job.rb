require "active_job"

module StandardLedger
  # Thin ActiveJob wrapper that delegates to `StandardLedger.refresh!`. Hosts
  # point their scheduler (SolidQueue Recurring Tasks, sidekiq-cron, etc.) at
  # this job class with the view name as the argument. The gem deliberately
  # does not auto-schedule — schedule cadence and backend selection is a host
  # concern (the host's scheduler config has the wider context: queue routing,
  # recurring task DSL, etc.).
  #
  # The job runs on ActiveJob's `:default` queue. Hosts running high-frequency
  # refreshes (e.g. every minute) on a shared `:default` queue may want to
  # isolate matview refreshes onto a dedicated queue so a slow refresh doesn't
  # starve other latency-sensitive jobs — subclass and override `queue_as`
  # (e.g. `queue_as :standard_ledger`) and point the scheduler at the
  # subclass.
  #
  # @example SolidQueue Recurring Tasks (config/recurring.yml)
  #   refresh_user_prompt_inventories:
  #     class: StandardLedger::MatviewRefreshJob
  #     args: ["user_prompt_inventories", { concurrently: true }]
  #     schedule: "every 5 minutes"
  class MatviewRefreshJob < ::ActiveJob::Base
    def perform(view_name, concurrently: nil)
      StandardLedger.refresh!(view_name, concurrently: concurrently)
    end
  end
end
