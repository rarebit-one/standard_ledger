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
#   StandardLedger.reset!                  # test helper
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

    def reset!
      @config = nil
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

    public

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

    private

    # Resolve override-map keys to actual class constants so callers can
    # write `with_modes(PaymentRecord => :inline)` *or*
    # `with_modes(:payment_record => :inline)`. The String/Symbol form uses
    # `String#classify` then `Object.const_get`; the Class form is passed
    # through verbatim. Anything else raises so the caller fixes the typo
    # rather than silently storing a key that nothing will ever match.
    def resolve_mode_overrides(overrides)
      overrides.each_with_object({}) do |(key, mode), memo|
        klass =
          case key
          when Class then key
          when String, Symbol then Object.const_get(key.to_s.classify)
          else
            raise ArgumentError,
                  "with_modes: expected Class, String, or Symbol key; got #{key.inspect}"
          end
        memo[klass] = mode
      end
    end
  end
end
