require "active_support/concern"

module StandardLedger
  # Marks an ActiveRecord model as a ledger entry: an immutable, append-only
  # row that may project onto one or more aggregate targets.
  #
  # Including this concern installs:
  #   - the `ledger_entry` class macro (declares immutability + idempotency)
  #   - read-only behavior post-creation (when `immutable: true`, the default)
  #   - idempotency-by-unique-index (when `idempotency_key:` is non-nil)
  #
  # Projection registration happens via the separate `Projector` concern —
  # the two are decoupled so that an entry can be marked immutable without
  # also opting into projections, and vice versa.
  #
  # @example
  #   class VoucherRecord < ApplicationRecord
  #     include StandardLedger::Entry
  #
  #     ledger_entry kind:            :action,
  #                  idempotency_key: :serial_no,
  #                  scope:           :organisation_id
  #   end
  module Entry
    extend ActiveSupport::Concern

    class_methods do
      # Declare the entry's contract. Stores the configuration on the class
      # for later inspection by `StandardLedger.post`, `Projection.rebuild!`,
      # and the `standard_ledger:doctor` rake task.
      #
      # @param kind [Symbol] the column holding the entry's kind/action
      #   discriminator. Defaults to `:kind`.
      # @param idempotency_key [Symbol, nil] the column whose unique index
      #   guards against duplicate inserts. `nil` means the entry is not
      #   idempotent — explicitly opt-in to that.
      # @param scope [Symbol, Array<Symbol>, nil] additional columns the
      #   idempotency index is scoped by (e.g. `:organisation_id`). Always
      #   normalised to a flat array on the stored config so downstream
      #   reads don't need to handle both shapes — assertions in host specs
      #   should compare against `[:foo]`, not `:foo`.
      # @param immutable [Boolean] when true (default), `save`/`update`
      #   raise after the row is persisted. Also blocks `destroy` unless
      #   `allow_destroy: true` is set.
      # @param allow_destroy [Boolean] when true, `destroy` (including
      #   `dependent: :destroy` cascades from a parent record) is permitted
      #   even on `immutable: true` entries. Use this when an owning record
      #   declares `has_many :events, dependent: :destroy` and you want the
      #   cascade to work for cleanup paths (sandbox tear-down, GDPR
      #   erasure, etc.) while still blocking app-code mutations to
      #   persisted entries. Defaults to `false` — keeping the strict
      #   journal contract.
      def ledger_entry(kind: :kind, idempotency_key: nil, scope: nil,
                       immutable: true, allow_destroy: false)
        self.standard_ledger_entry_config = {
          kind: kind,
          idempotency_key: idempotency_key,
          scope: Array(scope).compact,
          immutable: immutable,
          allow_destroy: allow_destroy
        }
        self.standard_ledger_idempotency_index_validated = false
      end

      def standard_ledger_entry?
        !standard_ledger_entry_config.nil?
      end

      # Override AR's `create!` to add idempotency-by-unique-index semantics.
      # When the configured unique constraint trips, look up and return the
      # existing row with `idempotent? == true` instead of raising.
      #
      # @note Block-form `create! { |r| r.field = val }` is not supported for
      #   the idempotent rescue: AR passes `attributes = nil` in that path so
      #   we can't construct the find_by lookup. The rescue still functions
      #   for the rest of the create — a colliding insert from a block-form
      #   call simply re-raises `RecordNotUnique` like vanilla ActiveRecord.
      def create!(attributes = nil, &block)
        config = standard_ledger_entry_config
        return super if config.nil? || config[:idempotency_key].nil?

        validate_standard_ledger_idempotency_index!

        super
      rescue ActiveRecord::RecordNotUnique => e
        raise unless standard_ledger_idempotency_violation?(e)

        existing = find_existing_standard_ledger_entry(attributes)
        raise if existing.nil?

        existing.instance_variable_set(:@_standard_ledger_idempotent, true)
        existing
      end

      # Verify that the table has a unique index covering exactly
      # `[*scope, idempotency_key]` (column set equality; order-insensitive).
      # Cached so the introspection runs once per class.
      #
      # The check-then-set on `standard_ledger_idempotency_index_validated`
      # has a benign race: two threads can both observe `false`, both run the
      # introspection, and both flip the flag to `true`. That's intentional
      # — the validation is pure and idempotent, so duplicate work is cheap
      # and the result is identical. No mutex needed; do not add one.
      def validate_standard_ledger_idempotency_index!
        return if standard_ledger_idempotency_index_validated

        config = standard_ledger_entry_config
        return if config.nil? || config[:idempotency_key].nil?

        required = (config[:scope] + [ config[:idempotency_key] ]).map(&:to_s).to_set
        indexes  = connection.indexes(table_name)

        match = indexes.any? do |index|
          next false unless index.unique
          next false unless index.columns.map(&:to_s).to_set == required

          # Full-table unique indexes are always valid. Partial indexes are
          # accepted only when the predicate is the canonical
          # `<idempotency_key> IS NOT NULL` shape — that's the common
          # real-world pattern (e.g. an event table whose serial number is
          # optional but unique-per-scope when present), and it preserves
          # the gem's idempotency contract: rows with a non-null key are
          # deduped; rows without one are explicitly opting out.
          standard_ledger_index_predicate_acceptable?(index, config[:idempotency_key])
        end

        unless match
          raise StandardLedger::MissingIdempotencyIndex,
                "#{name} declares idempotency_key: #{config[:idempotency_key].inspect} " \
                "with scope: #{config[:scope].inspect} but no matching unique index " \
                "covers exactly #{required.to_a.sort.inspect} on `#{table_name}`. " \
                "If a matching partial index exists, its WHERE predicate must be " \
                "`#{config[:idempotency_key]} IS NOT NULL` (other predicates aren't " \
                "automatically validated — opt out of the check by setting " \
                "idempotency_key: nil and enforcing uniqueness another way)."
        end

        self.standard_ledger_idempotency_index_validated = true
      end

      private

      # Match a partial-index predicate of the form `<col> IS NOT NULL`
      # (with optional whitespace and optional table/schema qualification
      # on the column reference). Full-table indexes (no predicate) always
      # qualify. This is conservative: predicates outside this shape can
      # still be perfectly valid for the host's idempotency intent, but
      # we'd need a real SQL parser to decide that — better to raise and
      # let the host either restructure their index or opt out via
      # `idempotency_key: nil`.
      def standard_ledger_index_predicate_acceptable?(index, idempotency_key)
        predicate = index.where
        return true if predicate.nil? || predicate.to_s.strip.empty?

        col = idempotency_key.to_s
        # Postgres wraps the index predicate in parentheses when it returns
        # it via pg_indexes (e.g. `(idempotency_key IS NOT NULL)`) — strip
        # those along with the per-adapter quoting characters before
        # matching. SQLite returns the raw expression, so the same strip is
        # a no-op there. The regex tolerates whitespace around the column
        # and operator and accepts an optional table-qualifier prefix.
        normalised = predicate.to_s.gsub(/["`\[\]()]/, "").strip
        normalised.match?(/\A([\w]+\.)?#{Regexp.escape(col)}\s+IS\s+NOT\s+NULL\z/i)
      end

      def find_existing_standard_ledger_entry(attributes)
        return nil if attributes.nil?

        config = standard_ledger_entry_config
        lookup_columns = config[:scope] + [ config[:idempotency_key] ]
        attrs = attributes.is_a?(Hash) ? attributes.transform_keys(&:to_sym) : {}
        lookup = lookup_columns.each_with_object({}) do |col, memo|
          memo[col] = attrs[col.to_sym]
        end

        # Bail if any lookup value is nil — `find_by` would emit
        # `WHERE col IS NULL` and could match an unrelated row whose column
        # legitimately holds NULL. We require all idempotency columns to be
        # present in `attributes` to make a confident match.
        return nil if lookup.any? { |_, value| value.nil? }

        find_by(lookup)
      end

      # Confirm the RecordNotUnique was raised by *our* idempotency index,
      # not some other unique constraint on the table (surrogate key,
      # business column, etc.). The wrapped DB exception's message usually
      # mentions the index name or the column list — a substring match on
      # each idempotency column name is good enough across PostgreSQL and
      # SQLite without parsing vendor-specific formats.
      #
      # Adapter caveat: MySQL's unique-violation message contains only the
      # index name (e.g. `Duplicate entry 'val' for key 'idx_name'`), not
      # the column list. So this check returns false on MySQL unless the
      # index is named after its columns. The fail-closed behavior re-raises
      # the original RecordNotUnique, which is the correct outcome for an
      # unrecognized violation — never the wrong one for a misclassified
      # one. None of the host apps target MySQL today; revisit if that
      # changes.
      def standard_ledger_idempotency_violation?(exception)
        config = standard_ledger_entry_config
        columns = (config[:scope] + [ config[:idempotency_key] ]).map(&:to_s)
        message = String(exception.message) + String(exception.cause&.message)

        columns.all? { |col| message.include?(col) }
      end
    end

    included do
      class_attribute :standard_ledger_entry_config, instance_writer: false
      class_attribute :standard_ledger_idempotency_index_validated, instance_writer: false
      self.standard_ledger_entry_config = nil
      self.standard_ledger_idempotency_index_validated = false

      # The destroy guard only matters for AR includers (the production case);
      # plain Ruby classes that include Entry for testing the DSL surface
      # get the macro registration without the callback. AR's `readonly?`
      # path covers save/update on persisted rows; this catch-all stops
      # `destroy` for the AR case unless the entry opts out via
      # `allow_destroy: true` (typically because an owning record's
      # `dependent: :destroy` cascade needs to reap them on cleanup).
      if respond_to?(:before_destroy)
        before_destroy :standard_ledger_raise_readonly, if: :standard_ledger_destroy_blocked?
      end

      # Emit `<namespace>.entry.created` after the row is durably committed
      # so subscribers (audit logs, metric pipelines) see it only when the
      # entry is real. Idempotent returns from `create!`'s rescue do not
      # fire `after_commit on: :create` (no INSERT happened), which is the
      # correct behavior: the original write fired the event already.
      if respond_to?(:after_commit)
        after_commit :standard_ledger_emit_entry_created, on: :create
      end
    end

    # Returns true when this row was returned from an idempotent `create!`
    # rescue — i.e. an existing row matched the unique constraint and was
    # returned instead of inserted.
    def idempotent?
      !!@_standard_ledger_idempotent
    end

    # AR consults `readonly?` from `save`/`update`/`destroy` paths; raising
    # ReadOnlyRecord here matches the ActiveRecord contract for persisted
    # immutable rows. New, unpersisted instances stay writable so the
    # initial INSERT can land.
    #
    # When `allow_destroy: true` is set, `#destroy` toggles
    # `@_standard_ledger_destroying` so `readonly?` returns false for the
    # duration of the destroy call (and the duration of any cascade
    # destroys that fire from its `dependent: :destroy` associations).
    # The save/update path is unaffected — those still raise on
    # persisted rows.
    def readonly?
      return super unless standard_ledger_immutable?
      return false if @_standard_ledger_destroying

      !new_record?
    end

    # Wrap `destroy` so it can bypass the `readonly?` guard when the
    # entry has opted in via `allow_destroy: true`. This applies to
    # `destroy`, `destroy!`, and `dependent: :destroy` cascades from a
    # parent record (all routes call through `#destroy`).
    def destroy
      return super unless self.class.respond_to?(:standard_ledger_entry_config)

      config = self.class.standard_ledger_entry_config
      return super if config.nil? || !config[:immutable] || !config[:allow_destroy]

      @_standard_ledger_destroying = true
      super
    ensure
      @_standard_ledger_destroying = false
    end

    # Returns the entry's belongs_to targets keyed by association name.
    # Used by the `entry.created` notification payload and by
    # `StandardLedger.post`'s telemetry. Skips polymorphic and missing
    # associations so the payload only includes what's actually present.
    #
    # Performance trade-off: this fires from `after_commit`, where AR may
    # have cleared the association cache. Each `public_send(reflection.name)`
    # can therefore issue a SELECT to reload the cached target. For the
    # typical 1–2 belongs_to entry, that's negligible. If profiling on a
    # high-cardinality entry shows this matters, capture targets earlier
    # (e.g. in `before_create`) and stash them on the instance — deferred
    # to a future PR. Notably, an inline-mode caller has already resolved
    # these targets by the time `after_commit` runs, so the SELECTs would
    # only happen for entries with belongs_to associations that are *not*
    # registered as projection targets.
    #
    # @return [Hash{Symbol => ActiveRecord::Base}]
    def standard_ledger_targets
      return {} unless self.class.respond_to?(:reflect_on_all_associations)

      self.class.reflect_on_all_associations(:belongs_to).each_with_object({}) do |reflection, memo|
        next if reflection.polymorphic?

        target = public_send(reflection.name)
        memo[reflection.name] = target unless target.nil?
      end
    end

    private

    def standard_ledger_immutable?
      config = self.class.standard_ledger_entry_config
      !config.nil? && config[:immutable]
    end

    # Destroys are blocked when the entry is `immutable: true` AND the user
    # has not opted out via `allow_destroy: true`. Split out so the
    # before_destroy guard can be conditional independently of the
    # save/update `readonly?` path.
    def standard_ledger_destroy_blocked?
      config = self.class.standard_ledger_entry_config
      return false if config.nil?
      return false unless config[:immutable]

      !config[:allow_destroy]
    end

    def standard_ledger_raise_readonly
      raise ActiveRecord::ReadOnlyRecord
    end

    # Publish `<namespace>.entry.created` once the row is durably committed.
    # `after_commit on: :create` only fires for real INSERTs, so idempotent
    # returns from the `create!` rescue path are correctly skipped.
    def standard_ledger_emit_entry_created
      config = self.class.standard_ledger_entry_config
      kind_value = config ? public_send(config[:kind]) : nil
      prefix = StandardLedger.config.notification_namespace

      StandardLedger::EventEmitter.emit(
        "#{prefix}.entry.created",
        entry: self, kind: kind_value, targets: standard_ledger_targets
      )
    end
  end
end
