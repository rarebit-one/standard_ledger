require "active_job"

module StandardLedger
  # ActiveJob class that runs a single `:async`-mode projection after the
  # entry's outer transaction has committed. Enqueued by
  # `StandardLedger::Modes::Async` from an `after_create_commit` callback.
  #
  # The job resolves the projection definition by `target_association` (the
  # only stable handle — the Definition struct doesn't serialize cleanly
  # through ActiveJob), looks up the target via the entry's `belongs_to`
  # setter, and runs `target.with_lock { projector_class.new.apply(target,
  # entry) }`. The projector must be class-form (`via: ProjectorClass`) and
  # should recompute the aggregate from the log inside `apply` for retry
  # safety — async projections can run more than once when the job retries.
  #
  # Retries are configurable per-projection via subclassing this job and
  # overriding `retry_on`, or globally via `Config#default_async_retries`
  # (default 3). When retries are exhausted, ActiveJob's dead-letter behavior
  # takes over — the job still emits `<prefix>.projection.failed` on every
  # attempt so subscribers see the full retry history.
  #
  # Notification payloads include `attempt:` (drawn from ActiveJob's
  # `executions` accessor — 1 on first attempt, increments per retry) so
  # subscribers can distinguish first-try success from retry-success.
  class ProjectionJob < ::ActiveJob::Base
    # Hand-rolled retry path so the attempt cap reads
    # `Config#default_async_retries` at perform time. ActiveJob's
    # `retry_on attempts:` requires a constant Integer (or `:unlimited`)
    # and is captured at class-definition time — that's incompatible with
    # the gem's pattern of letting hosts reconfigure `default_async_retries`
    # in their initializer (or specs flipping it temporarily). We rescue
    # `StandardError` and re-enqueue manually until the cap is reached.
    rescue_from(StandardError) do |error|
      attempts = StandardLedger.config.default_async_retries
      if executions < attempts
        # Compute a polynomial backoff inline. Mirrors ActiveJob's
        # `:polynomially_longer` algorithm (`executions**4 + 2`) without
        # depending on its private `determine_delay` API.
        delay = (executions**4) + 2
        retry_job(wait: delay, error: error)
      else
        raise error
      end
    end

    # Discard programmer errors immediately — they're deterministic and
    # retrying just burns the budget. `StandardLedger::Error` is raised by
    # `#perform` on missing/renamed projection definitions and similar
    # bookkeeping mistakes; the next attempt would raise the same error.
    # Declared AFTER the `rescue_from(StandardError)` block above because
    # `ActiveSupport::Rescuable` searches handlers from the most-recently-
    # registered first — so this more-specific `StandardLedger::Error`
    # handler wins over the catch-all retry path for its matching errors.
    discard_on StandardLedger::Error

    def perform(entry, target_association)
      definition = entry.class.standard_ledger_projections.find { |d|
        d.mode == :async && d.target_association == target_association.to_sym
      }
      if definition.nil?
        raise StandardLedger::Error,
              "no :async projection #{target_association.inspect} on #{entry.class.name}"
      end

      target = entry.public_send(definition.target_association)
      return if target.nil?

      prefix = StandardLedger.config.notification_namespace
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      begin
        target.with_lock do
          definition.projector_class.new.apply(target, entry)
        end
      rescue StandardError => e
        duration_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0
        StandardLedger::EventEmitter.emit(
          "#{prefix}.projection.failed",
          entry: entry, target: target, projection: definition.target_association,
          mode: :async, error: e, duration_ms: duration_ms,
          attempt: executions
        )
        raise
      end

      duration_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0
      StandardLedger::EventEmitter.emit(
        "#{prefix}.projection.applied",
        entry: entry, target: target, projection: definition.target_association,
        mode: :async, duration_ms: duration_ms, attempt: executions
      )
    end
  end
end
