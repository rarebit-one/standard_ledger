require "rspec/expectations"
require "active_support/notifications"
require "standard_ledger/event_emitter"

module StandardLedger
  module RSpec
    # Collects `<namespace>.entry.created` payloads from `Rails.event` for the
    # duration of a `post_ledger_entry` block. A dedicated object (not a
    # Proc) because `EventReporter#unsubscribe` matches with `===`.
    #
    # @api private
    class RailsEventCollector
      attr_reader :payloads

      def initialize(event_name)
        @event_name = event_name
        @payloads = []
      end

      def emit(event)
        @payloads << event[:payload] if event[:name] == @event_name
      end
    end
  end
end

# `post_ledger_entry` — assert that a block of code wrote a ledger entry.
#
#   expect {
#     Vouchers::IssueOperation.call(scheme: scheme, profile: profile)
#   }.to post_ledger_entry(VoucherRecord)
#
#   expect {
#     Vouchers::IssueOperation.call(scheme: scheme, profile: profile)
#   }.to post_ledger_entry(VoucherRecord).with(kind: :grant)
#
#   expect {
#     Vouchers::IssueOperation.call(scheme: scheme, profile: profile)
#   }.to post_ledger_entry(VoucherRecord).with(
#     kind:    :grant,
#     targets: { voucher_scheme: scheme },
#     attrs:   { serial_no: "v-123" }
#   )
#
#   expect { ... }.to_not post_ledger_entry(VoucherRecord)
#
# The matcher subscribes to `<namespace>.entry.created` for the duration of
# the block, on whichever channel `StandardLedger::EventEmitter` emits through
# (`Rails.event` on Rails 8.1+, `ActiveSupport::Notifications` otherwise),
# captures every fired event, and asserts that at least one event
# matched the expected class (and, when chained, the expected `kind`,
# `targets`, and `attrs`). The notification namespace is read from
# `StandardLedger.config.notification_namespace`, so a host that customised
# the namespace before the block runs is honored automatically.
RSpec::Matchers.define :post_ledger_entry do |entry_class|
  supports_block_expectations

  chain :with do |options = {}|
    @expected_kind    = options[:kind]    if options.key?(:kind)
    @expected_targets = options[:targets] if options.key?(:targets)
    @expected_attrs   = options[:attrs]   if options.key?(:attrs)
  end

  match do |block|
    @expected_class = entry_class
    @captured_events = capture_entry_created_events(&block)

    @captured_events.any? { |payload| event_matches?(payload) }
  end

  match_when_negated do |block|
    @expected_class = entry_class
    @captured_events = capture_entry_created_events(&block)

    @captured_events.none? { |payload| event_matches?(payload) }
  end

  failure_message do
    if @captured_events.empty?
      "expected block to post a #{@expected_class} ledger entry, but no " \
        "`#{notification_event_name}` events fired"
    else
      "expected block to post a #{@expected_class} ledger entry " \
        "#{describe_expectations}, but got: #{describe_captured_events}"
    end
  end

  failure_message_when_negated do
    matched = @captured_events.select { |payload| event_matches?(payload) }
    "expected block not to post a #{@expected_class} ledger entry " \
      "#{describe_expectations}, but #{matched.size} matching event(s) fired: " \
      "#{describe_captured_events(matched)}"
  end

  # ----------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------

  # Listens on the same channel `EventEmitter.emit` picks. Listening only on
  # AS::Notifications meant that on Rails 8.1 (where emit goes through
  # `Rails.event`) the matcher saw nothing — every positive expectation
  # failed and every negated one passed vacuously.
  def capture_entry_created_events(&block)
    if StandardLedger::EventEmitter.rails_event_available?
      capture_via_rails_event(&block)
    else
      capture_via_notifications(&block)
    end
  end

  def capture_via_rails_event(&block)
    bus = ::Rails.event
    collector = StandardLedger::RSpec::RailsEventCollector.new(notification_event_name)
    bus.subscribe(collector)

    begin
      block.call
    ensure
      bus.unsubscribe(collector)
    end

    collector.payloads
  end

  def capture_via_notifications(&block)
    events = []
    subscriber = ActiveSupport::Notifications.subscribe(notification_event_name) do |*args|
      events << ActiveSupport::Notifications::Event.new(*args).payload
    end

    begin
      block.call
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end

    events
  end

  def notification_event_name
    "#{StandardLedger.config.notification_namespace}.entry.created"
  end

  def event_matches?(payload)
    entry = payload[:entry]
    return false unless entry.is_a?(@expected_class)

    if defined?(@expected_kind)
      return false unless kind_matches?(payload[:kind], @expected_kind)
    end

    if defined?(@expected_targets)
      return false unless hash_includes?(payload[:targets] || {}, @expected_targets)
    end

    if defined?(@expected_attrs)
      return false unless attrs_match?(entry, @expected_attrs)
    end

    true
  end

  # `kind` arrives in the payload as whatever the entry stored — usually a
  # string, since that's what a string column reads back as. Allow specs to
  # pass either symbol or string and compare loosely.
  def kind_matches?(actual, expected)
    actual.to_s == expected.to_s
  end

  def hash_includes?(actual, expected)
    expected.all? { |key, value| actual[key] == value }
  end

  def attrs_match?(entry, expected)
    expected.all? do |key, value|
      next false unless entry.respond_to?(key)

      entry.public_send(key) == value
    end
  end

  def describe_expectations
    parts = []
    parts << "with kind: #{@expected_kind.inspect}"      if defined?(@expected_kind)
    parts << "targets: #{@expected_targets.inspect}"     if defined?(@expected_targets)
    parts << "attrs: #{@expected_attrs.inspect}"         if defined?(@expected_attrs)
    parts.empty? ? "" : "(#{parts.join(', ')})"
  end

  def describe_captured_events(events = @captured_events)
    return "(none)" if events.empty?

    events.map { |payload|
      "<#{payload[:entry].class}: kind=#{payload[:kind].inspect}, " \
        "targets=#{(payload[:targets] || {}).keys.inspect}>"
    }.join(", ")
  end
end
