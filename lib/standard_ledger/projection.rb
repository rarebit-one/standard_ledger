module StandardLedger
  # Base class for projector classes registered via
  # `projects_onto :target, via: ProjectorClass`. Subclasses implement
  # `apply` (and optionally `rebuild`) to mutate the target based on a new
  # entry.
  #
  # For projections expressible as block DSL (counter increments, simple
  # delta updates), prefer the block form on `Projector#projects_onto`
  # instead — extracting a class is for non-trivial projectors.
  #
  # @example
  #   class Orders::FulfillableProjector < StandardLedger::Projection
  #     # Called inside the async job, with target locked.
  #     def apply(order, _entry)
  #       order.update!(
  #         fulfillable_balance: order.fulfillment_records.group(:key).sum(:amount),
  #         fulfillable_status:  order.fulfillment_records.group(:key).sum(:amount).values.all?(&:zero?) ? :fulfilled : :pending
  #       )
  #     end
  #
  #     # Called by Projection.rebuild! to recompute from the full log.
  #     def rebuild(order)
  #       apply(order, nil)
  #     end
  #   end
  class Projection
    # Apply a single entry's effect to the target. Called inside the
    # transactional or async boundary of the chosen mode.
    def apply(_target, _entry)
      raise NotImplementedError, "#{self.class}#apply must be implemented"
    end

    # Recompute the target's projection from the full entry log. Called by
    # `StandardLedger.rebuild!`. Projectors that cannot be rebuilt (e.g.
    # delta-only `increment_counter` flavored ones) should raise
    # `StandardLedger::NotRebuildable`.
    def rebuild(_target)
      raise NotRebuildable, "#{self.class}#rebuild not implemented; this projector cannot be rebuilt from the entry log"
    end
  end
end
