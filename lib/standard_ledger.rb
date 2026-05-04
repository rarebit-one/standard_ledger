require "active_support"
require "active_support/notifications"
require "active_support/core_ext/string/inflections"
require "concurrent"

require "standard_ledger/version"
require "standard_ledger/errors"
require "standard_ledger/result"
require "standard_ledger/config"
require "standard_ledger/entry"
require "standard_ledger/projection"
require "standard_ledger/projector"
require "standard_ledger/modes/inline"
require "standard_ledger/modes/sql"
require "standard_ledger/modes/matview"
require "standard_ledger/jobs/matview_refresh_job"
require "standard_ledger/engine" if defined?(::Rails::Engine)

# StandardLedger captures the recurring "immutable journal entry → N
# aggregate projections" pattern as a declarative DSL on host ActiveRecord
# models. See `standard_ledger-design.md` in the workspace root for the
# full design discussion.
#
# Public surface:
#
#   StandardLedger.configure { |c| ... }   # configure once at boot
#   StandardLedger.config                  # read configured values
#   StandardLedger.post(EntryClass, ...)   # write an entry + project
#   StandardLedger.rebuild!(EntryClass)    # recompute projections from log
#   StandardLedger.refresh!(:view_name)    # ad-hoc matview refresh
#   StandardLedger.reset!                  # full test helper (wipes config + overrides)
#   StandardLedger.reset_mode_overrides!   # clears only the with_modes thread-local
module StandardLedger
  class << self
    # Configure the gem once per app, typically from
    # `config/initializers/standard_ledger.rb`. Yields the `Config` instance.
    def configure
      yield config
      config
    end

    def config
      @config ||= Config.new
    end

    # Full reset: clears the cached `Config` AND any thread-local `with_modes`
    # overrides. Use this when a spec needs to verify the gem's boot path or
    # when the host has *not* installed a Rails initializer (so wiping
    # `@config` is harmless). Hosts that *do* configure the gem in an
    # initializer should not call this between examples — use
    # `reset_mode_overrides!` instead, which the auto-cleanup hook already
    # invokes.
    def reset!
      @config = nil
      reset_mode_overrides!
    end

    # Test-friendly reset that only clears the thread-local `with_modes`
    # override map, leaving `Config` intact. The `standard_ledger/rspec`
    # auto-cleanup hook calls this in `before(:each)` so a host's initializer
    # config (e.g. a configured `result_adapter`) survives across examples
    # while per-example mode overrides still get torn down cleanly.
    def reset_mode_overrides!
      Thread.current[:standard_ledger_mode_overrides] = nil
    end

    # Sugar over `EntryClass.create!` that maps `targets:` onto the entry's
    # `belongs_to` foreign keys. Equivalent to calling `create!` directly
    # with the assignments folded together — the inline projection callback
    # fires from the same code path either way.
    #
    # @example
    #   StandardLedger.post(VoucherRecord,
    #                       kind:    :grant,
    #                       targets: { voucher_scheme: scheme, customer_profile: profile },
    #                       attrs:   { serial_no: "v-123", organisation_id: org.id })
    #
    # @example pass an id via attrs when you don't have a model instance
    #   StandardLedger.post(VoucherRecord,
    #                       kind:  :grant,
    #                       attrs: { voucher_scheme_id: 42, organisation_id: org.id, serial_no: "v-1" })
    #
    # @param entry_class [Class] an `ActiveRecord::Base` subclass that
    #   includes `StandardLedger::Entry`.
    # @param kind [Symbol, String] value for the entry's configured kind
    #   column (read from `entry_class.standard_ledger_entry_config[:kind]`).
    # @param targets [Hash{Symbol => ActiveRecord::Base}] association name ->
    #   model instance. Each is assigned via the matching `belongs_to`
    #   setter. To assign by id without loading the record, pass the
    #   foreign key directly via `attrs:` (e.g. `voucher_scheme_id: 42`).
    # @param attrs [Hash] additional attributes merged into the create call.
    # @return [StandardLedger::Result, Object] the gem's Result, or the
    #   host's Result type when `Config#custom_result?` is true. The Result's
    #   `projections[:inline]` contains the target_association names of the
    #   inline projections that actually ran for this entry — projections
    #   skipped by an `if:` guard are excluded, and an idempotent retry
    #   returns an empty array (no projections fire on the rescue path).
    def post(entry_class, kind:, targets: {}, attrs: {})
      kind_column = resolve_kind_column(entry_class)
      create_attrs = build_create_attrs(entry_class, kind_column, kind, targets, attrs)

      entry = entry_class.create!(create_attrs)

      build_result(
        success: true,
        entry: entry,
        idempotent: entry.respond_to?(:idempotent?) && entry.idempotent?,
        projections: { inline: applied_projections_for(entry) }
      )
    rescue ActiveRecord::RecordInvalid => e
      build_result(success: false, entry: e.record, errors: e.record.errors.full_messages)
    end

    # Force specific entry classes' projections to run in the supplied mode
    # for the duration of the block. Intended for tests that want to drive an
    # async-mode projection inline so the spec doesn't need a job runner.
    #
    # The override map is stored thread-locally so concurrent specs (or the
    # gem's own `:async` workers) don't observe each other's overrides. Mode
    # strategies consult `StandardLedger.mode_override_for(entry_class)`
    # before falling back to the projection's declared mode.
    #
    # The block's prior override map is restored on exit, including on
    # exception, so nested `with_modes` calls compose cleanly: the inner
    # block's keys win during its scope, then the outer map is restored
    # untouched.
    #
    # Today only `:inline` exists as a real mode, so this is a no-op for
    # already-inline projections. The hook lands now so async projections
    # can opt into the inline path the moment `Modes::Async` ships.
    #
    # @example
    #   StandardLedger.with_modes(PaymentRecord => :inline) do
    #     Orders::CheckoutOperation.call(...)
    #   end
    #
    # @example string keys (resolved via const_get)
    #   StandardLedger.with_modes("PaymentRecord" => :inline) do
    #     ...
    #   end
    #
    # @param overrides [Hash{Class, String, Symbol => Symbol}] entry class (or
    #   constant name / underscored symbol) → forced mode symbol.
    def with_modes(overrides)
      resolved = resolve_mode_overrides(overrides)

      prior = Thread.current[:standard_ledger_mode_overrides]
      merged = (prior || {}).merge(resolved)
      Thread.current[:standard_ledger_mode_overrides] = merged

      yield
    ensure
      Thread.current[:standard_ledger_mode_overrides] = prior
    end

    # Read the active override (if any) for `entry_class`. Mode strategies
    # call this in their `install!` / `#call` paths before deciding whether
    # to dispatch to the declared mode or the override mode. Returns `nil`
    # outside any `with_modes` block.
    #
    # @param entry_class [Class] the host entry class.
    # @return [Symbol, nil] the override mode, or `nil` for "no override".
    def mode_override_for(entry_class)
      overrides = Thread.current[:standard_ledger_mode_overrides]
      return nil if overrides.nil?

      overrides[entry_class]
    end

    # Recompute projections from the entry log for one or more targets.
    # The deterministic counterpart to `post`: instead of applying the
    # delta from a single new entry, this replays the full log onto the
    # target by delegating to the projector class's `rebuild(target)`.
    #
    # Scope (mutually exclusive — pass at most one):
    #
    # - `target:` — rebuild every projection whose `target_association`
    #   resolves to `target.class`, for that single instance.
    # - `target_class:` — rebuild every matching projection for every
    #   target referenced by the log for that AR class, in `find_each`
    #   batches. Targets with zero log entries are skipped (rebuilding a
    #   target the log never touched would zero its counters — destructive
    #   rather than corrective).
    # - neither — rebuild every projection on `entry_class` for every
    #   target referenced by the log.
    #
    # Per-mode rules:
    #
    # - `:inline` projections must be class-form (`via: ProjectorClass`)
    #   AND that class must implement `rebuild`. Block-form projections
    #   are delta-based — they cannot be reconstructed from the log
    #   without the host providing a recompute path — so they raise
    #   `StandardLedger::NotRebuildable` here.
    # - `:async`, `:sql`, `:trigger`, `:matview` modes are not yet
    #   supported by `rebuild!`; they raise `StandardLedger::Error`.
    #   Each lands with its mode's own PR.
    #
    # Atomicity: each (target, projection) pair runs in its own
    # transaction. A failure mid-loop is **not** rolled back — earlier
    # successful rebuilds remain applied. Concurrent posts to the entry
    # log during rebuild produce eventually-correct state: the rebuild
    # operates on a snapshot of the log up to the projector's own
    # SELECT, and any entries written after that snapshot project
    # normally via the entry's own callback path. See design doc §5.5.
    #
    # @example rebuild a single target
    #   StandardLedger.rebuild!(VoucherRecord, target: scheme)
    #
    # @example rebuild every scheme
    #   StandardLedger.rebuild!(VoucherRecord, target_class: VoucherScheme)
    #
    # @example rebuild every projection across every target
    #   StandardLedger.rebuild!(VoucherRecord)
    #
    # @param entry_class [Class] an `ActiveRecord::Base` subclass that
    #   includes `StandardLedger::Projector`.
    # @param target [ActiveRecord::Base, nil] one specific projection
    #   target instance.
    # @param target_class [Class, nil] rebuild for every target of this
    #   AR class that the log references. Targets with zero log entries
    #   are skipped.
    # @param batch_size [Integer] passed to `find_each` when iterating
    #   targets. Default 1000.
    # @return [StandardLedger::Result, Object] success result with
    #   `projections[:rebuilt] = [{ target_class:, target_id:,
    #   projection: }, ...]`, one entry per (target, projection) pair
    #   that ran. Failure result with `errors:` when any rebuild raises.
    #   Returns the host's Result type when `Config#custom_result?` is
    #   true, otherwise `StandardLedger::Result`.
    # @raise [StandardLedger::NotRebuildable] when an applicable
    #   projection has no rebuildable projector (block-form, or class
    #   form whose `rebuild` raises `NotRebuildable`).
    # @raise [StandardLedger::Error] when an applicable projection
    #   declares a mode `rebuild!` does not yet support.
    # @raise [ArgumentError] when both `target:` and `target_class:`
    #   are supplied, when the entry class does not respond to
    #   `standard_ledger_projections`, or when a non-nil scope
    #   (`target:` / `target_class:`) matches no registered projection.
    # @note Memory: when neither `target:` nor `target_class:` is given,
    #   the no-scope and `target_class:` paths first load every distinct
    #   foreign-key value from the log into memory via `distinct.pluck`
    #   before batching the targets themselves. For very large logs,
    #   prefer `target:` to scope to a single target rather than
    #   rebuilding the full set.
    def rebuild!(entry_class, target: nil, target_class: nil, batch_size: 1000)
      if target && target_class
        raise ArgumentError,
              "rebuild! accepts at most one of `target:` or `target_class:` — got both"
      end

      unless entry_class.respond_to?(:standard_ledger_projections)
        raise ArgumentError,
              "#{entry_class.name || entry_class.inspect} does not include StandardLedger::Projector; " \
              "rebuild! requires registered projections"
      end

      definitions = applicable_definitions_for_rebuild(entry_class, target: target, target_class: target_class)
      validate_definitions_present!(entry_class, definitions, target: target, target_class: target_class)
      rebuilt = []

      definitions.each do |definition|
        validate_rebuildable_mode!(entry_class, definition)

        if definition.mode == :matview
          rebuild_matview_definition(definition)
          rebuilt << {
            target_class: nil,
            target_id:    nil,
            projection:   definition.target_association,
            view:         definition.view
          }
          next
        end

        validate_rebuildable_projector!(entry_class, definition)

        each_rebuild_target(entry_class, definition, target: target, batch_size: batch_size) do |t|
          if definition.mode == :sql
            rebuild_one_sql(entry_class, definition, t)
          else
            rebuild_one(entry_class, definition, t)
          end
          rebuilt << { target_class: t.class, target_id: t.id, projection: definition.target_association }
        end
      end

      build_result(success: true, projections: { rebuilt: rebuilt })
    rescue StandardLedger::Error, ArgumentError
      # Programmer-error / unsupported-mode / not-rebuildable raises bubble
      # up unchanged — these are deterministic, not data-dependent failures.
      raise
    rescue StandardError => e
      # A projector raised mid-rebuild. Earlier successful rebuilds are
      # NOT unwound (the contract is per-target transactional, not
      # cross-target atomic) — we surface the failure but return.
      build_result(success: false, errors: [ e.message ], projections: { rebuilt: rebuilt })
    end

    # Refresh a host-owned materialized view. Issues
    # `REFRESH MATERIALIZED VIEW [CONCURRENTLY] <view_name>` against the
    # active connection and emits the standard `<prefix>.projection.refreshed`
    # notification on success (or `<prefix>.projection.failed` on raise,
    # before re-raising — the host's scheduler / job runner needs to see the
    # failure to drive its retry path).
    #
    # Two callers reach for this:
    #
    # - **Hosts**, after a critical write that needs read-your-write semantics
    #   on a `:matview` projection (e.g. luminality's `PromptPacks::DrawOperation`
    #   refreshes `user_prompt_inventories` at the end of the operation so the
    #   user sees their post-draw count immediately, instead of waiting for
    #   the next scheduled refresh).
    # - **`StandardLedger::MatviewRefreshJob`**, the ActiveJob class hosts
    #   point their scheduler at; that job is a thin wrapper around this
    #   method.
    #
    # @param view_name [String, Symbol] the materialized view to refresh.
    # @param concurrently [Boolean, nil] `nil` (default — read
    #   `Config#matview_refresh_strategy`), `true` (force CONCURRENTLY), or
    #   `false` (force a blocking refresh).
    # @return [StandardLedger::Result, Object] success result on completion;
    #   the host's Result type when `Config#custom_result?` is true. On SQL
    #   failure the underlying exception propagates after the
    #   `<prefix>.projection.failed` event fires.
    def refresh!(view_name, concurrently: nil)
      effective = effective_concurrent_flag(concurrently)
      Modes::Matview.new.refresh!(view_name, concurrently: effective)
      build_result(
        success: true,
        projections: { refreshed: [ { view: view_name.to_s, concurrently: effective } ] }
      )
    end

    private

    # Resolve the kind column name for an entry class. Falls back to `:kind`
    # when the host hasn't called `ledger_entry` yet — `post` is still useful
    # for plain Entry-shaped models.
    def resolve_kind_column(entry_class)
      config = entry_class.respond_to?(:standard_ledger_entry_config) ? entry_class.standard_ledger_entry_config : nil
      config ? config[:kind] : :kind
    end

    # Translate `targets:` into the matching foreign-key assignments by
    # routing each value through the entry's `belongs_to` setter (after
    # confirming via `reflect_on_association` that the key is a real
    # association). Targets must be ActiveRecord instances; raw foreign-key
    # ids should be passed via `attrs:` instead (`<assoc>_id: ...`).
    def build_create_attrs(entry_class, kind_column, kind, targets, attrs)
      assigned = { kind_column => kind }

      if entry_class.respond_to?(:reflect_on_association)
        targets.each do |assoc_name, target|
          reflection = entry_class.reflect_on_association(assoc_name)
          if reflection.nil?
            raise ArgumentError,
                  "#{entry_class.name} has no association :#{assoc_name}; " \
                  "`targets:` keys must match `belongs_to` associations"
          end
          assigned[assoc_name] = target
        end
      else
        assigned.merge!(targets)
      end

      assigned.merge(attrs)
    end

    # Filter the entry class's registered projections down to the set
    # whose target association class matches the requested scope.
    # When neither `target:` nor `target_class:` is supplied, every
    # registered projection is in scope.
    #
    # @return [Array<Projector::Definition>]
    def applicable_definitions_for_rebuild(entry_class, target:, target_class:)
      requested_class = target_class || target&.class
      return entry_class.standard_ledger_projections.dup if requested_class.nil?

      entry_class.standard_ledger_projections.select do |definition|
        association_target_class(entry_class, definition) == requested_class
      end
    end

    # An empty `definitions` set means either (a) the host called
    # `rebuild!` on an entry class that has no `projects_onto`
    # declarations at all, or (b) a non-nil scope (`target:` /
    # `target_class:`) was passed but no registered projection points at
    # that AR class. Both are programmer errors — silently returning
    # `Result.success` with `rebuilt: []` would let the mistake go
    # undetected. Raise so the caller hears about it.
    def validate_definitions_present!(entry_class, definitions, target:, target_class:)
      return unless definitions.empty?

      requested_class = target_class || target&.class

      if requested_class
        raise ArgumentError,
              "#{entry_class.name} has no projections matching #{requested_class.name}; " \
              "check the `projects_onto` declarations on #{entry_class.name}."
      else
        raise ArgumentError,
              "#{entry_class.name} has no projections registered; " \
              "add a `projects_onto` declaration before calling rebuild!."
      end
    end

    # Resolve the AR class on the far side of a projection's
    # `target_association`. Used to match `target:` / `target_class:`
    # against registered projections.
    def association_target_class(entry_class, definition)
      reflection = entry_class.reflect_on_association(definition.target_association)
      return nil if reflection.nil?

      reflection.klass
    end

    # Refuse to rebuild for modes that don't yet implement the
    # log-replay path. `:inline`, `:sql`, and `:matview` are the supported
    # modes today; `:async` and `:trigger` land with their own mode PRs.
    def validate_rebuildable_mode!(entry_class, definition)
      return if definition.mode == :inline
      return if definition.mode == :sql
      return if definition.mode == :matview

      raise StandardLedger::Error,
            "rebuild! does not yet support mode: #{definition.mode.inspect} " \
            "on #{entry_class.name}##{definition.target_association}; " \
            "this mode's rebuild path lands in its own PR"
    end

    # Rebuild a `:matview` projection by issuing a single REFRESH against
    # the registered view. There's no per-target loop — the matview holds
    # state for every target in a single relation, so one refresh is the
    # entire rebuild.
    def rebuild_matview_definition(definition)
      concurrently = definition.refresh_options.is_a?(Hash) ? definition.refresh_options[:concurrently] : nil
      effective = effective_concurrent_flag(concurrently)
      Modes::Matview.new.refresh!(definition.view, concurrently: effective)
    end

    # Reduce the public `concurrently:` parameter to a Boolean by reading
    # `Config#matview_refresh_strategy` only when the caller passed `nil`.
    # `true`/`false` are honored verbatim so callers can override the
    # default per-call (e.g. an ad-hoc blocking refresh on a view whose
    # default is concurrent).
    def effective_concurrent_flag(concurrently)
      return concurrently unless concurrently.nil?

      config.matview_refresh_strategy == :concurrent
    end

    # Block-form `:inline` projections register per-kind handlers
    # (e.g. `on(:grant) { increment(...) }`) that describe a delta.
    # There's no general way to recompute the aggregate from the log
    # without the host providing a recompute path — so we refuse
    # rather than guess. Hosts who want this projection to be
    # rebuildable should extract a `Projection` subclass and implement
    # `rebuild(target)`.
    def validate_rebuildable_projector!(entry_class, definition)
      # `:sql` mode carries its rebuild path in the recompute SQL itself —
      # no projector class is required (and `via:` is rejected at
      # registration). Skip the class-form preflight checks below.
      return if definition.mode == :sql

      if definition.projector_class.nil?
        raise StandardLedger::NotRebuildable,
              "#{entry_class.name}##{definition.target_association} is a block-form projection " \
              "and cannot be rebuilt from the entry log. Implement a Projection subclass with " \
              "`rebuild(target)` and pass it via `via:` to make this projection rebuildable."
      end

      # Best-effort early detection: catches the common "host forgot to
      # override `rebuild`" case before we iterate any targets. The owner
      # check is fragile for projectors that inherit `rebuild` from an
      # intermediate mixin/superclass — the inherited `rebuild` may still
      # raise `NotRebuildable` at runtime. The authoritative gate is the
      # base `Projection#rebuild` implementation, which raises
      # `NotRebuildable` itself; the rescue clause in `rebuild!` re-raises
      # it unchanged. So a fragility miss here just means the failure
      # surfaces at iteration-time instead of pre-flight, which is
      # acceptable for v0.1.
      return if definition.projector_class.instance_method(:rebuild).owner != StandardLedger::Projection

      raise StandardLedger::NotRebuildable,
            "#{definition.projector_class.name}#rebuild is not implemented; " \
            "override it to recompute #{entry_class.name}##{definition.target_association} " \
            "from the entry log."
    end

    # Yield each target in scope for this projection's rebuild. With
    # an explicit `target:` we yield once; with `target_class:` or no
    # scope, we walk every distinct foreign-key value in the log and
    # `find_each` the corresponding rows in batches.
    def each_rebuild_target(entry_class, definition, target:, batch_size:)
      if target
        yield target
        return
      end

      reflection = entry_class.reflect_on_association(definition.target_association)
      target_klass = reflection.klass
      foreign_key = reflection.foreign_key

      # Pluck the distinct ids referenced by the log so we don't
      # rebuild for targets that have no entries against them. Cast
      # through `compact` to skip null FKs (legitimate when the entry
      # has an `if:` guard that may not apply).
      ids = entry_class.where.not(foreign_key => nil).distinct.pluck(foreign_key)
      return if ids.empty?

      target_klass.where(id: ids).find_each(batch_size: batch_size) do |t|
        yield t
      end
    end

    # Run a single (target, projection) rebuild inside its own
    # transaction, then fire `<prefix>.projection.rebuilt` on success
    # so observers can track per-target rebuild progress.
    def rebuild_one(entry_class, definition, target)
      target.class.transaction do
        definition.projector_class.new.rebuild(target)
      end

      prefix = config.notification_namespace
      ActiveSupport::Notifications.instrument(
        "#{prefix}.projection.rebuilt",
        entry_class: entry_class, target: target, projection: definition, mode: definition.mode
      )
    end

    # `:sql` mode rebuild path: run the same recompute SQL the
    # `after_create` callback runs, just bound to this target's id rather
    # than the entry's foreign key. The recompute SQL is the entire
    # contract for `:sql` projections — there's no projector class to
    # invoke; the after-create and rebuild paths share one statement.
    def rebuild_one_sql(entry_class, definition, target)
      target.class.transaction do
        sql = ActiveRecord::Base.sanitize_sql_array([ definition.recompute_sql, { target_id: target.id } ])
        entry_class.connection.exec_update(sql)
      end

      prefix = config.notification_namespace
      ActiveSupport::Notifications.instrument(
        "#{prefix}.projection.rebuilt",
        entry_class: entry_class, target: target, projection: definition, mode: definition.mode
      )
    end

    # Names of the `:inline`-mode projections that actually ran for this
    # entry — surfaced in `result.projections[:inline]` so callers can
    # distinguish "applied now" from "queued" from "scheduled" (§7).
    #
    # `Modes::Inline#call` populates `@_standard_ledger_applied_projections`
    # on the entry instance with the target_association names that ran
    # (skipping projections whose `if:` guard returned false, whose target
    # was nil, or whose permissive miss didn't hit a `:_` wildcard). When
    # the ivar isn't present — e.g. an idempotent rescue returned an
    # existing row without firing `after_create` — we report an empty
    # list, which accurately reflects that no projections ran on this call.
    def applied_projections_for(entry)
      Array(entry.instance_variable_get(:@_standard_ledger_applied_projections))
    end

    # Construct a Result via the host's adapter when configured, otherwise
    # the gem's built-in `StandardLedger::Result`. The adapter contract is
    # documented on `Config#result_adapter`.
    def build_result(success:, entry: nil, errors: [], idempotent: false, projections: {})
      if config.custom_result?
        config.result_adapter.call(
          success: success, value: entry, errors: errors,
          entry: entry, idempotent: idempotent, projections: projections
        )
      elsif success
        Result.success(entry: entry, idempotent: idempotent, projections: projections)
      else
        Result.failure(errors: errors, entry: entry)
      end
    end

    # Resolve override-map keys to actual class constants so callers can
    # write `with_modes(PaymentRecord => :inline)` *or*
    # `with_modes(:payment_record => :inline)`. The String/Symbol form uses
    # `String#classify` then `Object.const_get`; the Class form is passed
    # through verbatim. Anything else raises so the caller fixes the typo
    # rather than silently storing a key that nothing will ever match.
    #
    # An unresolvable String/Symbol key (typo: `:payment_recrd`) is caught
    # and re-raised as `ArgumentError` with a `with_modes:`-prefixed message
    # naming the offending key, rather than leaking `const_get`'s bare
    # `NameError: uninitialized constant ...`.
    def resolve_mode_overrides(overrides)
      overrides.each_with_object({}) do |(key, mode), memo|
        klass =
          case key
          when Class
            key
          when String, Symbol
            begin
              Object.const_get(key.to_s.classify)
            rescue NameError
              raise ArgumentError,
                    "with_modes: could not resolve #{key.inspect} to a constant"
            end
          else
            raise ArgumentError,
                  "with_modes: expected Class, String, or Symbol key; got #{key.inspect}"
          end
        memo[klass] = mode
      end
    end
  end
end
