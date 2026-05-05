module StandardLedger
  # Boot hook for Rails apps. The engine registers no routes and provides no
  # tables — its only role is to ensure the gem's notification subscribers
  # (if any are registered by the host) are wired up after the host's
  # initializers have finished running.
  #
  # We hook `after: :load_config_initializers` so any host-side
  # `StandardLedger.configure` block in `config/initializers/*` has finished
  # before subscribers are attached.
  class Engine < ::Rails::Engine
    isolate_namespace StandardLedger

    initializer "standard_ledger.notifications", after: :load_config_initializers do
      # Notification wiring lands here in a follow-up PR. Today this is a
      # no-op — the gem emits events but ships no internal subscribers; hosts
      # subscribe directly via ActiveSupport::Notifications.subscribe.
    end

    # Engines auto-discover `lib/tasks/*.rake` in most Rails versions, but
    # we register explicitly for defence-in-depth. Hosts get
    # `standard_ledger:doctor` available under `bin/rails -T standard_ledger`.
    rake_tasks do
      load File.expand_path("../tasks/standard_ledger.rake", __dir__)
    end
  end
end
