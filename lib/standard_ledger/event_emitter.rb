module StandardLedger
  # Internal helper that emits StandardLedger lifecycle events through whichever
  # event reporter is live in the host process.
  #
  # - On Rails 8.1+, `Rails.event.notify(name, **payload)` is the canonical bus.
  # - On older Rails (or any host without the structured reporter), we fall back
  #   to `ActiveSupport::Notifications.instrument(name, payload)`.
  #
  # Detection is performed at *call time* — the gem is required before Rails has
  # finished booting, so we cannot cache the decision at load time.
  #
  # @api private
  module EventEmitter
    module_function

    # Emit a single event. Both backends are best-effort: any exception raised
    # by a subscriber is swallowed so ledger observability never takes down a
    # host's request path (the projection has already either succeeded or
    # been rolled back by the time we emit).
    def emit(event_name, payload)
      if (bus = rails_event_bus)
        bus.notify(event_name, **payload)
      else
        ::ActiveSupport::Notifications.instrument(event_name, payload)
      end
    rescue => e
      warn "[StandardLedger] event emit for #{event_name.inspect} failed: #{e.class}: #{e.message}"
    end

    # Returns the Rails 8.1+ structured event bus when available, or `nil`
    # to signal the AS::Notifications fallback. Single accessor so `emit`
    # invokes `Rails.event` only once per call.
    def rails_event_bus
      return nil unless defined?(::Rails) &&
                        ::Rails.respond_to?(:event) &&
                        ::Rails.event.respond_to?(:notify)

      ::Rails.event
    end

    # Boolean shorthand kept for callers (and specs) that just want to know
    # whether the modern bus is live.
    def rails_event_available?
      !rails_event_bus.nil?
    end

    # `rails_event_bus` is an implementation detail — only `emit` and
    # `rails_event_available?` should reach for it. `module_function`
    # exposes every method as a public module-level method by default,
    # so we mark this one private explicitly. `private_class_method`
    # privatises the singleton-method copy that `module_function`
    # generated, hiding it from `EventEmitter.rails_event_bus` callers.
    private_class_method :rails_event_bus
  end
end
