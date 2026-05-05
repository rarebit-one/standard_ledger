module StandardLedger
  # The gem's default result type, returned by `StandardLedger.post` and
  # `StandardLedger.rebuild!` when the host has not configured an adapter
  # for its own Result class.
  #
  # Hosts with their own Result type (e.g. `ApplicationOperation::Result`)
  # register a translator via `StandardLedger.config.result_adapter` so the
  # gem returns the host's type instead — see `Config#result_adapter`.
  class Result
    attr_reader :value, :errors, :entry, :projections

    # @param success [Boolean]
    # @param value [Object, nil] typically the persisted entry, or whatever the
    #   host operation wishes to surface.
    # @param errors [Array<String>] human-readable error messages.
    # @param entry [ActiveRecord::Base, nil] the persisted entry record.
    # @param idempotent [Boolean] true when the create was a no-op because an
    #   existing row already satisfied the idempotency key.
    # @param projections [Hash] split by mode: `{ inline: [...], async: [...], matview: [...] }`.
    def initialize(success:, value: nil, errors: [], entry: nil, idempotent: false, projections: {})
      @success = success
      @value = value
      @errors = errors
      @entry = entry
      @idempotent = idempotent
      @projections = projections
    end

    def success?
      @success
    end

    def failure?
      !@success
    end

    def idempotent?
      @idempotent
    end

    # Build a successful result. Convenience for `StandardLedger.post` and
    # internal callers; not intended as the host's primary construction path.
    def self.success(entry:, idempotent: false, projections: {})
      new(success: true, value: entry, entry: entry, idempotent: idempotent, projections: projections)
    end

    def self.failure(errors:, entry: nil, projections: {})
      new(success: false, errors: Array(errors), entry: entry, projections: projections)
    end
  end
end
