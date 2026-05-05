require_relative "lib/standard_ledger/version"

Gem::Specification.new do |spec|
  spec.name        = "standard_ledger"
  spec.version     = StandardLedger::VERSION
  spec.authors     = [ "Jaryl Sim" ]
  spec.email       = [ "code@jaryl.dev" ]
  spec.homepage    = "https://github.com/rarebit-one/standard_ledger"
  spec.summary     = "Immutable journal entries with declarative aggregate projections for Rails apps."
  spec.description = "StandardLedger captures the recurring 'append-only entry → N projection updates' pattern as a declarative DSL on host ActiveRecord models. Supports inline, sql, and matview projection modes (async and trigger modes land in subsequent releases); enforces idempotency-by-unique-index; and provides a deterministic rebuild path from the entry log."
  spec.license     = "MIT"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/rarebit-one/standard_ledger"
  spec.metadata["changelog_uri"] = "https://github.com/rarebit-one/standard_ledger/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/rarebit-one/standard_ledger/issues"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["lib/**/*", "MIT-LICENSE", "Rakefile", "README.md", "CHANGELOG.md"]
  end

  spec.required_ruby_version = ">= 3.4"

  spec.add_dependency "railties", ">= 8.0"
  spec.add_dependency "activerecord", ">= 8.0"
  spec.add_dependency "activejob", ">= 8.0"
  spec.add_dependency "activesupport", ">= 8.0"
  spec.add_dependency "concurrent-ruby", "~> 1.3"

  spec.add_development_dependency "brakeman"
  spec.add_development_dependency "bundler-audit"
  spec.add_development_dependency "simplecov"
end
