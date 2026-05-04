require "active_job"

module StandardLedger
  # Thin ActiveJob wrapper that delegates to `StandardLedger.refresh!`. Hosts
  # point their scheduler (SolidQueue Recurring Tasks, sidekiq-cron, etc.) at
  # this job class with the view name as the argument. The gem deliberately
  # does not auto-schedule — schedule cadence and backend selection is a host
  # concern (the host's scheduler config has the wider context: queue routing,
  # recurring task DSL, etc.).
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
