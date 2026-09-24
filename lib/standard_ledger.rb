require "active_support"
require "active_support/notifications"
require "active_support/core_ext/string/inflections"

require "standard_ledger/version"
require "standard_ledger/errors"
require "standard_ledger/event_emitter"
require "standard_ledger/result"
require "standard_ledger/config"
require "standard_ledger/entry"
require "standard_ledger/projection"
require "standard_ledger/matview"

# StandardLedger captures the "immutable, append-only journal entry" pattern
# for host ActiveRecord models, plus two small helpers that sit next to it:
# a `post` sugar for writing entries and a `refresh!` wrapper for host-owned
# materialized views. See `standard_ledger-design.md` for the design notes.
#
# Public surface:
#
#   StandardLedger.configure { |c| ... }   # configure once at boot
#   StandardLedger.config                  # read configured values
#   StandardLedger.post(EntryClass, ...)   # write an entry, return a Result
#   StandardLedger.refresh!(:view_name)    # refresh a materialized view
#   StandardLedger.reset!                  # test helper (wipes config)
#
# 0.6.0 removed the projection engine (`projects_onto`, the projection
# modes, `rebuild!`, `with_modes`, the jobs and the `doctor` task) — no
# consuming app used it. See CHANGELOG.md for the upgrade note.
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

    # Clears the cached `Config`. Intended for specs that exercise the gem's
    # boot path; hosts that configure the gem from an initializer should not
    # call this between examples (it would undo their initializer config).
    def reset!
      @config = nil
    end

    # Sugar over `EntryClass.create!` that maps `targets:` onto the entry's
    # `belongs_to` associations and wraps the outcome in a Result.
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
    #   host's Result type when `Config#custom_result?` is true. `idempotent?`
    #   is true when the create matched an existing row via the entry's
    #   idempotency key. `projections` is always `{}` since 0.6.0; the key is
    #   kept so existing `result_adapter` lambdas keep their signature.
    def post(entry_class, kind:, targets: {}, attrs: {})
      kind_column = resolve_kind_column(entry_class)
      create_attrs = build_create_attrs(entry_class, kind_column, kind, targets, attrs)

      entry = entry_class.create!(create_attrs)

      build_result(
        success: true,
        entry: entry,
        idempotent: entry.respond_to?(:idempotent?) && entry.idempotent?
      )
    rescue ActiveRecord::RecordInvalid => e
      build_result(success: false, entry: e.record, errors: e.record.errors.full_messages)
    end

    # Refresh a host-owned materialized view. Issues
    # `REFRESH MATERIALIZED VIEW [CONCURRENTLY] <view_name>` against the
    # active connection and emits `<prefix>.projection.refreshed` on success.
    # When the refresh SQL raises, it emits `<prefix>.projection.failed`,
    # reports the error through `Rails.error` (`handled: false`,
    # `severity: :error`, `context: { view:, concurrently: }`,
    # `source: "standard_ledger"`) and re-raises, so the host's job runner
    # still drives its retry path. Hosts don't need their own
    # report-and-re-raise; Rails skips an exception it has already reported,
    # so an existing one is harmless. Argument errors and
    # `RefreshInsideTransaction` are programming errors raised before any
    # SQL runs; they are not reported by the gem.
    #
    # @example scheduled job refreshing a list of views
    #   VIEWS.each { |view| StandardLedger.refresh!(view, concurrently: :auto) }
    #
    # @param view_name [String, Symbol] the materialized view to refresh.
    #   Must be a bare or `schema.view` SQL identifier.
    # @param concurrently [Boolean, Symbol, nil]
    #   - `true` — force `CONCURRENTLY`. Raises `RefreshInsideTransaction`
    #     inside an open transaction; Postgres raises if the view is empty
    #     or has no suitable unique index.
    #   - `false` — force a plain (blocking) refresh.
    #   - `:auto` — use `CONCURRENTLY` only when it can succeed: no open
    #     transaction, the view is populated, and it has a unique index
    #     without a WHERE clause or expressions. Otherwise fall back to a
    #     plain refresh. If the catalog probe itself fails, the error is
    #     reported via `Rails.error` (handled) and a plain refresh runs.
    #   - `nil` (default) — read `Config#matview_refresh_strategy`
    #     (`:concurrent` => `true`, `:blocking` => `false`, `:auto` => `:auto`).
    # @return [StandardLedger::Result, Object] success result with
    #   `projections[:refreshed] = [{ view:, concurrently: }]`, where
    #   `concurrently` is the resolved Boolean. The host's Result type when
    #   `Config#custom_result?` is true.
    # @raise [ArgumentError] when `view_name` is not a valid identifier or
    #   `concurrently` is not one of the values above.
    # @raise [StandardLedger::RefreshInsideTransaction] for
    #   `concurrently: true` inside an open transaction.
    def refresh!(view_name, concurrently: nil)
      effective = Matview.resolve_concurrently(view_name, requested_concurrently(concurrently))
      Matview.refresh!(view_name, concurrently: effective)
      build_result(
        success: true,
        projections: { refreshed: [ { view: view_name.to_s, concurrently: effective } ] }
      )
    end

    # Report +error+ through `Rails.error` (or `ActiveSupport.error_reporter`
    # outside Rails) with `source: "standard_ledger"`. A reporter failure is
    # swallowed so it can never mask the error being reported.
    #
    # @api private
    def report_error(error, handled:, severity:, context:)
      reporter =
        if defined?(::Rails) && ::Rails.respond_to?(:error)
          ::Rails.error
        elsif ActiveSupport.respond_to?(:error_reporter)
          ActiveSupport.error_reporter
        end
      reporter&.report(error, handled: handled, severity: severity, context: context, source: "standard_ledger")
    rescue StandardError
      nil
    end

    private

    # Resolve the kind column name for an entry class. Falls back to `:kind`
    # when the host hasn't called `ledger_entry` yet — `post` is still useful
    # for plain Entry-shaped models.
    def resolve_kind_column(entry_class)
      config = entry_class.respond_to?(:standard_ledger_entry_config) ? entry_class.standard_ledger_entry_config : nil
      config ? config[:kind] : :kind
    end

    # Translate `targets:` into association assignments after confirming via
    # `reflect_on_association` that each key is a real association. Targets
    # must be ActiveRecord instances; raw foreign-key ids should be passed via
    # `attrs:` instead (`<assoc>_id: ...`).
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

    # Normalise the public `concurrently:` argument. `nil` defers to
    # `Config#matview_refresh_strategy`; explicit values are honored verbatim
    # so callers can override the default per call.
    def requested_concurrently(concurrently)
      value = concurrently.nil? ? strategy_to_flag(config.matview_refresh_strategy) : concurrently
      return value if [ true, false, :auto ].include?(value)

      raise ArgumentError,
            "concurrently: must be true, false, :auto, or nil; got #{concurrently.inspect}"
    end

    def strategy_to_flag(strategy)
      case strategy
      when :concurrent then true
      when :blocking then false
      when :auto then :auto
      else
        raise ArgumentError,
              "Config#matview_refresh_strategy must be :concurrent, :blocking, or :auto; got #{strategy.inspect}"
      end
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
        Result.failure(errors: errors, entry: entry, projections: projections)
      end
    end
  end
end
