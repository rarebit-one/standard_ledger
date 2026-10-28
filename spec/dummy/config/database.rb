require "active_record"

# In-memory SQLite by default. DATABASE_URL (the CI Postgres leg) runs the
# suite on Postgres instead, where a failed statement aborts the enclosing
# transaction; SQLite cannot show that. spec/dummy/db/schema.rb recreates
# every table with `force: true`, so refuse anything that is not a throwaway
# test database.
database_url = ENV["DATABASE_URL"].to_s

if database_url.start_with?("postgres")
  ActiveRecord::Base.establish_connection(database_url)
  database = ActiveRecord::Base.connection.current_database
  abort("Refusing to load the dummy schema into #{database.inspect}: not a test database") unless database.include?("test")
else
  ActiveRecord::Base.establish_connection(
    adapter: "sqlite3",
    database: ":memory:"
  )
end
