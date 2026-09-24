require_relative "lib/standard_ledger/version"

Gem::Specification.new do |spec|
  spec.name        = "standard_ledger"
  spec.version     = StandardLedger::VERSION
  spec.authors     = [ "Jaryl Sim" ]
  spec.email       = [ "code@jaryl.dev" ]
  spec.homepage    = "https://github.com/rarebit-one/standard_ledger"
  spec.summary     = "Immutable, append-only journal entries and materialized-view refresh for Rails apps."
  spec.description = "StandardLedger marks ActiveRecord models as immutable, append-only journal entries with idempotency-by-unique-index, provides a StandardLedger.post helper that returns a Result (optionally the host's own Result type), a Projection base class for host-side projectors, and StandardLedger.refresh! for host-owned PostgreSQL materialized views (including concurrently: :auto)."
  spec.license     = "MIT"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/rarebit-one/standard_ledger"
  spec.metadata["changelog_uri"] = "https://github.com/rarebit-one/standard_ledger/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/rarebit-one/standard_ledger/issues"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["lib/**/*", "LICENSE", "Rakefile", "README.md", "CHANGELOG.md"]
  end

  # Matches the rest of the standard_* family, and — more to the point — matches
  # what is actually exercised: CI has only ever run the 4.0.x matrix, so the
  # old ">= 3.4" was an untested claim. Every consumer runs 4.0.x too.
  spec.required_ruby_version = ">= 4.0"

  spec.add_dependency "railties", ">= 8.0"
  spec.add_dependency "activerecord", ">= 8.0"
  spec.add_dependency "activesupport", ">= 8.0"

  spec.add_development_dependency "brakeman"
  spec.add_development_dependency "bundler-audit"
  spec.add_development_dependency "simplecov"
end
