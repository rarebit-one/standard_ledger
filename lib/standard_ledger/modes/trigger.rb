module StandardLedger
  module Modes
    # `:trigger` mode: the host owns a database trigger (created in a Rails
    # migration) that updates the projection target's columns on every
    # entry INSERT. The gem records the trigger's name and the equivalent
    # rebuild SQL, but does **not** create or manage the trigger itself —
    # giving a Ruby DSL the power to install/replace triggers is a deploy
    # footgun (silent re-creation on `db:schema:load` against a non-empty
    # DB), and triggers are versioned by `db/schema.rb` like any other DDL.
    #
    # Two consumers read the recorded metadata:
    #
    # - `StandardLedger.rebuild!` runs the rebuild SQL when invoked,
    #   binding `:target_id` to each target the log references. The same
    #   recompute path as `:sql` mode — the only difference is that the
    #   after-create application is performed by the database trigger
    #   rather than a Ruby callback.
    # - The `standard_ledger:doctor` rake task verifies that the named
    #   trigger exists in the connected schema. Migration drift (a missing
    #   or renamed trigger) is caught at deploy time, not at runtime.
    #
    # Unlike `:inline` and `:sql`, this strategy does NOT install an
    # `after_create` callback — the trigger fires from the database. The
    # `install!` no-op only marks the entry class as having at least one
    # `:trigger` projection registered (mirrors the `Modes::Matview` shape).
    #
    # See `standard_ledger-design.md` §5.3.4 for the full contract.
    class Trigger
      # Mark the entry class as having at least one `:trigger` projection
      # registered. The actual trigger metadata lives on the entry class's
      # `standard_ledger_projections` array; this method exists only to
      # mirror the `Modes::*.install!` shape so `Projector#install_mode_callbacks_for`
      # can dispatch uniformly across modes.
      #
      # No `after_create` callback is installed — the trigger runs in the
      # database, not Ruby. Idempotent across multiple `:trigger`
      # projections on the same entry class.
      #
      # @param entry_class [Class] the host entry class (unused — kept for
      #   parity with the other strategy classes).
      # @return [void]
      def self.install!(_entry_class)
        # Intentionally empty: trigger projections fire from the DB, so
        # there's no Ruby-side callback to wire. The DSL has already
        # captured `trigger_name` and `recompute_sql` on the Definition;
        # `rebuild!` and the `doctor` rake task consume those directly.
      end
    end
  end
end
