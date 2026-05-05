namespace :standard_ledger do
  # PostgreSQL-only: queries `pg_trigger` directly. The only mode that
  # registers a trigger today is `:trigger`, and the only adopter is
  # nutripod-web (Postgres). SQLite has no comparable per-statement
  # trigger introspection that makes sense for this gem's contract — if
  # a non-Postgres host adopts `:trigger` mode in the future, they'll
  # need to extend this task with a connection-adapter dispatch. The
  # task is loud about its Postgres assumption: a `pg_trigger` query
  # against a non-Postgres connection will raise, which is preferable
  # to silently passing.
  desc "Verify that every :trigger projection's trigger exists in the database (Postgres-only)"
  task doctor: :environment do
    require "standard_ledger"

    # Discover entry classes by walking ActiveRecord descendants for
    # ones that include `StandardLedger::Projector` and have at least
    # one `:trigger` projection registered. The host's eager loading
    # (Rails default in production / when explicitly invoked in dev)
    # ensures all entry classes are loaded before this iterates.
    entry_classes = ActiveRecord::Base.descendants.select { |klass|
      klass.respond_to?(:standard_ledger_projections) &&
        klass.standard_ledger_projections.any? { |d| d.mode == :trigger }
    }

    missing = []
    entry_classes.each do |klass|
      klass.standard_ledger_projections_for(:trigger).each do |definition|
        # `pg_trigger.tgname` is the trigger's name as known to Postgres.
        # The `LIMIT 1` guards against pathological cases where a
        # trigger of the same name exists on multiple tables — for the
        # doctor's purpose ("does it exist anywhere?") that's fine.
        result = ActiveRecord::Base.connection.exec_query(
          "SELECT 1 FROM pg_trigger WHERE tgname = $1 LIMIT 1",
          "standard_ledger:doctor",
          [ definition.trigger_name ]
        )
        if result.rows.empty?
          missing << "  #{klass.name}##{definition.target_association}: trigger #{definition.trigger_name.inspect} not found"
        end
      end
    end

    if missing.empty?
      puts "All :trigger projections have their triggers present."
    else
      warn "Missing triggers detected:"
      missing.each { |line| warn line }
      warn ""
      warn "Run the migration that creates the trigger, or check that the trigger name in `projects_onto` matches the actual trigger name in the schema."
      exit 1
    end
  end
end
