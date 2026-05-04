require "spec_helper"
require "fileutils"
require "stringio"
require "tmpdir"
require "rails/generators"
require "generators/standard_ledger/install/install_generator"

RSpec.describe StandardLedger::Generators::InstallGenerator, type: :generator do
  let(:destination_root) { Dir.mktmpdir("standard_ledger_install_generator") }
  let(:initializer_path) { File.join(destination_root, "config/initializers/standard_ledger.rb") }

  before do
    FileUtils.mkdir_p(File.join(destination_root, "config/initializers"))
  end

  after do
    FileUtils.rm_rf(destination_root)
  end

  def run_generator(args = [])
    captured = StringIO.new
    original_stdout = $stdout
    $stdout = captured
    described_class.start(args, destination_root: destination_root)
    captured.string
  ensure
    $stdout = original_stdout
  end

  describe "default invocation" do
    it "creates the initializer file" do
      run_generator
      expect(File).to exist(initializer_path)
    end

    it "templates the configure block into the initializer" do
      run_generator
      content = File.read(initializer_path)

      expect(content).to include("StandardLedger.configure do |c|")
    end

    it "documents every public Config setting as a commented-out example" do
      run_generator
      content = File.read(initializer_path)

      expect(content).to include("# c.default_async_job = Orders::FulfillableProjectionJob")
      expect(content).to include("# c.default_async_retries = 3")
      expect(content).to include("# c.scheduler = :solid_queue")
      expect(content).to include("# c.matview_refresh_strategy = :concurrent")
      expect(content).to include('# c.notification_namespace = "standard_ledger"')
    end

    it "documents the host Result interop adapter pattern" do
      run_generator
      content = File.read(initializer_path)

      expect(content).to include("# c.result_class   = ApplicationOperation::Result")
      expect(content).to include("# c.result_adapter = ->(success:, value:, errors:, entry:, idempotent:, projections:)")
    end

    it "generates a fully commented-out configure body" do
      run_generator
      content = File.read(initializer_path)

      configure_body = content[/StandardLedger\.configure do \|c\|(.+)^end/m, 1]
      expect(configure_body).not_to be_nil

      uncommented = configure_body.lines.reject do |line|
        stripped = line.strip
        stripped.empty? || stripped.start_with?("#")
      end

      expect(uncommented).to be_empty,
        "expected every line inside the configure block to be commented out, found: #{uncommented.inspect}"
    end
  end

  describe "idempotency" do
    it "skips when the initializer already exists" do
      run_generator
      sentinel = "# user customisation\n"
      File.write(initializer_path, sentinel)

      output = run_generator

      expect(output).to match(/already present, skipping/)
      expect(File.read(initializer_path)).to eq(sentinel)
    end
  end

  describe "--force" do
    it "overwrites an existing initializer" do
      File.write(initializer_path, "# stale\n")

      run_generator([ "--force" ])

      content = File.read(initializer_path)
      expect(content).to include("StandardLedger.configure do |c|")
      expect(content).not_to eq("# stale\n")
    end
  end
end
