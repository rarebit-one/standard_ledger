RSpec.describe StandardLedger::Projection do
  it "raises NotImplementedError from #apply until a subclass overrides it" do
    expect { described_class.new.apply(Object.new, Object.new) }
      .to raise_error(NotImplementedError, /#apply must be implemented/)
  end

  it "raises NotRebuildable from #rebuild until a subclass overrides it" do
    expect { described_class.new.rebuild(Object.new) }
      .to raise_error(StandardLedger::NotRebuildable, /cannot be rebuilt/)
  end

  it "lets subclasses implement apply and rebuild as plain methods" do
    projector = Class.new(described_class) do
      def apply(target, entry) = target << entry
      def rebuild(target) = target.clear
    end.new

    target = []
    projector.apply(target, :entry)
    expect(target).to eq([ :entry ])

    projector.rebuild(target)
    expect(target).to be_empty
  end
end
