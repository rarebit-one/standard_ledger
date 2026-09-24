module StandardLedger
  # Optional base class for host-side projector objects: plain Ruby classes
  # that update an aggregate from ledger entries. The gem does not invoke
  # projectors itself (the declarative `projects_onto` engine was removed in
  # 0.6.0) — the host calls `apply` / `rebuild` from its own operations.
  # Subclassing gives a shared shape and sensible failures for unimplemented
  # methods.
  #
  # @example
  #   class Validations::ProfileProjector < StandardLedger::Projection
  #     def apply(profile, validation)
  #       profile.increment!(:successful_loans_count) if validation.successful?
  #     end
  #
  #     def rebuild(profile)
  #       profile.update!(successful_loans_count: profile.validations.successful.count)
  #     end
  #   end
  #
  #   Validations::ProfileProjector.new.apply(profile, validation)
  class Projection
    # Apply a single entry's effect to the target.
    def apply(_target, _entry)
      raise NotImplementedError, "#{self.class}#apply must be implemented"
    end

    # Recompute the target from the full entry log. Projectors that cannot
    # be rebuilt (e.g. delta-only ones) leave this unimplemented and it
    # raises `StandardLedger::NotRebuildable`.
    def rebuild(_target)
      raise NotRebuildable, "#{self.class}#rebuild not implemented; this projector cannot be rebuilt from the entry log"
    end
  end
end
