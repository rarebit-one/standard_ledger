require "active_support"
require "active_support/notifications"
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
    # @param entry_class [Class] an `ActiveRecord::Base` subclass that
    #   includes `StandardLedger::Entry`.
    # @param kind [Symbol, String] value for the entry's configured kind
    #   column (read from `entry_class.standard_ledger_entry_config[:kind]`).
    # @param targets [Hash{Symbol => ActiveRecord::Base, Integer, String}]
    #   association name -> target instance (or id). Each is assigned via
    #   the matching `belongs_to` setter.
    # @param attrs [Hash] additional attributes merged into the create call.
    # @return [StandardLedger::Result, Object] the gem's Result, or the
    #   host's Result type when `Config#custom_result?` is true.
    def post(entry_class, kind:, targets: {}, attrs: {})
      kind_column = resolve_kind_column(entry_class)
      create_attrs = build_create_attrs(entry_class, kind_column, kind, targets, attrs)

      entry = entry_class.create!(create_attrs)

      build_result(
        success: true,
        entry: entry,
        idempotent: entry.respond_to?(:idempotent?) && entry.idempotent?,
        projections: { inline: applied_inline_names(entry_class) }
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

    # Translate `targets:` into the matching foreign-key assignments. Uses
    # AR's reflection so the caller can pass either a model instance or an
    # id, and the gem sets the right side of the belongs_to.
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

    # Names of the `:inline`-mode projections registered on this entry
    # class — surfaced in `result.projections[:inline]` so callers can
    # distinguish "applied now" from "queued" from "scheduled" (§7).
    def applied_inline_names(entry_class)
      return [] unless entry_class.respond_to?(:standard_ledger_projections_for)

      entry_class.standard_ledger_projections_for(:inline).map(&:target_association)
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
  end
end
