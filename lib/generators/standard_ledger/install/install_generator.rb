require "rails/generators"

module StandardLedger
  module Generators
    # Installs StandardLedger in a host Rails application.
    #
    # Writes config/initializers/standard_ledger.rb with commented-out
    # examples covering the public Config DSL.
    #
    # Idempotent: re-running on an existing initializer logs and skips.
    # Pass +--force+ to overwrite.
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc <<~DESC
        Installs StandardLedger. Writes config/initializers/standard_ledger.rb
        with commented-out examples covering the public Config DSL.

        The generator is idempotent — already-installed initializer is skipped
        with a clear message. Pass --force to overwrite.
      DESC

      def create_initializer_file
        path = "config/initializers/standard_ledger.rb"
        if File.exist?(File.join(destination_root, path)) && !options.force?
          say_status("skip", "#{path} already present, skipping (use --force to overwrite)", :yellow)
          return
        end

        template "initializer.rb.tt", path
      end
    end
  end
end
