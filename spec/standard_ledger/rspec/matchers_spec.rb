require "standard_ledger/rspec/matchers"

# rubocop:disable RSpec/DescribeClass, RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe "post_ledger_entry matcher" do
  before do
    stub_const("VoucherScheme", Class.new(ActiveRecord::Base) do
      self.table_name = "voucher_schemes"
      has_many :voucher_records, dependent: nil
    end)

    stub_const("CustomerProfile", Class.new(ActiveRecord::Base) do
      self.table_name = "customer_profiles"
      has_many :voucher_records, dependent: nil
    end)

    stub_const("VoucherRecord", Class.new(ActiveRecord::Base) do
      self.table_name = "voucher_records"
      include StandardLedger::Entry

      belongs_to :voucher_scheme
      belongs_to :customer_profile

      ledger_entry kind:            :action,
                   idempotency_key: :serial_no,
                   scope:           :organisation_id
    end)

    stub_const("OtherRecord", Class.new(ActiveRecord::Base) do
      self.table_name = "voucher_records"
      include StandardLedger::Entry

      belongs_to :voucher_scheme
      belongs_to :customer_profile

      ledger_entry kind: :action, idempotency_key: :serial_no, scope: :organisation_id
    end)
  end

  after do
    [ VoucherRecord, VoucherScheme, CustomerProfile ].each { |m| m.unscoped.delete_all }
  end

  let(:scheme)  { VoucherScheme.create!(name: "Scheme A") }
  let(:profile) { CustomerProfile.create!(name: "Customer A") }

  def post_grant(entry_class = VoucherRecord, attrs: {}, kind: "grant")
    StandardLedger.post(
      entry_class,
      kind:    kind,
      targets: { voucher_scheme: scheme, customer_profile: profile },
      attrs:   { organisation_id: "org-1", serial_no: "v-#{SecureRandom.hex(2)}" }.merge(attrs)
    )
  end

  describe "matching on entry class only" do
    it "passes when the block posts an entry of the expected class" do
      expect { post_grant }.to post_ledger_entry(VoucherRecord)
    end

    it "fails when no entry is posted at all" do
      expect {
        expect { :no_op }.to post_ledger_entry(VoucherRecord)
      }.to raise_error(RSpec::Expectations::ExpectationNotMetError, /no.*events fired/)
    end

    it "fails when the entry posted is a different class" do
      expect {
        expect { post_grant(OtherRecord) }.to post_ledger_entry(VoucherRecord)
      }.to raise_error(RSpec::Expectations::ExpectationNotMetError, /VoucherRecord/)
    end
  end

  describe "matching on kind" do
    it "passes when kind matches (symbol vs. string)" do
      expect { post_grant(kind: "grant") }.to post_ledger_entry(VoucherRecord).with(kind: :grant)
    end

    it "fails when the kind differs" do
      expect {
        expect { post_grant(kind: "redeem") }.to post_ledger_entry(VoucherRecord).with(kind: :grant)
      }.to raise_error(RSpec::Expectations::ExpectationNotMetError, /kind: :grant/)
    end
  end

  describe "matching on targets" do
    it "passes when the targets hash includes the expected entries" do
      expect {
        post_grant
      }.to post_ledger_entry(VoucherRecord).with(targets: { voucher_scheme: scheme })
    end

    it "fails when a target is missing or different" do
      other_scheme = VoucherScheme.create!(name: "Other")
      expect {
        expect {
          post_grant
        }.to post_ledger_entry(VoucherRecord).with(targets: { voucher_scheme: other_scheme })
      }.to raise_error(RSpec::Expectations::ExpectationNotMetError)
    end
  end

  describe "matching on attrs" do
    it "passes when the entry's attribute values match" do
      expect {
        post_grant(attrs: { serial_no: "v-attr-1" })
      }.to post_ledger_entry(VoucherRecord).with(attrs: { serial_no: "v-attr-1", organisation_id: "org-1" })
    end

    it "fails when an expected attr differs" do
      expect {
        expect {
          post_grant(attrs: { serial_no: "v-attr-2" })
        }.to post_ledger_entry(VoucherRecord).with(attrs: { serial_no: "v-other" })
      }.to raise_error(RSpec::Expectations::ExpectationNotMetError, /serial_no/)
    end
  end

  describe "compound matchers" do
    it "passes only when class, kind, targets, and attrs all match" do
      expect {
        post_grant(attrs: { serial_no: "v-cmp-1" })
      }.to post_ledger_entry(VoucherRecord).with(
        kind:    :grant,
        targets: { voucher_scheme: scheme, customer_profile: profile },
        attrs:   { serial_no: "v-cmp-1" }
      )
    end
  end

  describe "negative assertions" do
    it "passes when no matching entry was posted" do
      expect { :no_op }.not_to post_ledger_entry(VoucherRecord)
    end

    it "passes when a different class was posted" do
      expect { post_grant(OtherRecord) }.not_to post_ledger_entry(VoucherRecord)
    end

    it "fails when a matching entry was posted" do
      expect {
        expect { post_grant }.not_to post_ledger_entry(VoucherRecord)
      }.to raise_error(RSpec::Expectations::ExpectationNotMetError, /1 matching event/)
    end
  end

  describe "namespace customisation" do
    # The auto-cleanup hook preserves Config across examples so a host's
    # Rails initializer config survives. Tests in this group mutate the
    # global `notification_namespace`, so they must reset it themselves to
    # avoid leaking into other specs.
    after { StandardLedger.reset! }

    it "honors a custom notification_namespace" do
      StandardLedger.configure { |c| c.notification_namespace = "host.ledger" }

      expect { post_grant }.to post_ledger_entry(VoucherRecord).with(kind: :grant)
    end

    it "doesn't see events under the default namespace when reconfigured" do
      # Subscribe to default-namespace events to confirm no leakage in the
      # custom-namespace path.
      seen = []
      sub = ActiveSupport::Notifications.subscribe("standard_ledger.entry.created") do |*args|
        seen << ActiveSupport::Notifications::Event.new(*args).payload
      end

      StandardLedger.configure { |c| c.notification_namespace = "host.ledger" }
      post_grant

      # The custom matcher should still see the event under the new namespace.
      expect {
        post_grant
      }.to post_ledger_entry(VoucherRecord)
      # Default-namespace listener saw nothing.
      expect(seen).to be_empty
    ensure
      ActiveSupport::Notifications.unsubscribe(sub) if sub
    end
  end

  describe "failure messages" do
    it "names the expected class and chained expectations" do
      message = nil
      begin
        expect {
          post_grant(kind: "redeem")
        }.to post_ledger_entry(VoucherRecord).with(kind: :grant)
      rescue RSpec::Expectations::ExpectationNotMetError => e
        message = e.message
      end

      expect(message).to include("VoucherRecord")
      expect(message).to include("kind: :grant")
      # Captured event summary should also be present.
      expect(message).to include('kind="redeem"').or include("kind=\"redeem\"")
    end

    it "is helpful when no events fire at all" do
      message = nil
      begin
        expect { :no_op }.to post_ledger_entry(VoucherRecord).with(kind: :grant)
      rescue RSpec::Expectations::ExpectationNotMetError => e
        message = e.message
      end

      expect(message).to include("no")
      expect(message).to include("standard_ledger.entry.created")
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/ExampleLength, RSpec/MultipleExpectations
