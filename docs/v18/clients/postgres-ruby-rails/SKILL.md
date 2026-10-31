---
name: postgres-ruby-rails
description: 'Connects Ruby and Rails to PostgreSQL correctly: the pg gem (install per OS, PG.connect, exec_params, type maps, transactions, COPY with copy_data, pipeline mode, LISTEN with wait_for_notify, error classes), Sequel, and Rails 8.1 Active Record (database.yml, max_connections, PgBouncer with prepared_statements and advisory_locks off, migrations with algorithm: :concurrently and disable_ddl_transaction!, strong_migrations, jsonb, arrays and enum types, upsert_all, find_each, SKIP LOCKED, advisory locks, Solid Queue, structure.sql or schema.rb). Use when writing Ruby or Rails code against Postgres, "prepared statement already exists" behind PgBouncer, a migration locks a big table, or Solid Queue tables are missing.'
metadata:
  tags:
  - postgres
  - ruby
  - rails
  - activerecord
  - pg-gem
  - sequel
  - solid-queue
  - strong-migrations
  - pgbouncer
---

# PostgreSQL from Ruby with the pg gem, Sequel and Rails

Use the `pg` gem directly for scripts and tools, Sequel when you want a full SQL toolkit without Rails, and Active
Record inside Rails. In every one: bind values as parameters, keep transactions short, and retry only on SQLSTATE
`40001` and `40P01`. In Rails 8.1, size the pool with `max_connections`, behind a transaction-mode PgBouncer turn
off `advisory_locks` (and `prepared_statements` for PgBouncer older than 1.21), build indexes with
`algorithm: :concurrently`, and switch to `structure.sql` once the schema uses triggers, functions or views. The
cross-language chooser is `postgres-app-drivers`; PgBouncer modes in `postgres-connection-pooling`; lock-safe DDL in
`postgres-schema-migrations`. Rails detail: [references/rails.md](references/rails.md).

## Install the pg gem on macOS, Linux and Windows

The `pg` gem ships precompiled native gems with libpq bundled, so `bundle install` needs no PostgreSQL client and no
compiler on the common platforms. pg 1.7.0 (October 2026) needs Ruby 3.1 or later and bundles libpq 18.6.

| Platform | What Bundler installs |
|---|---|
| macOS Apple silicon, Intel | `arm64-darwin`, `x86_64-darwin` native gem |
| Linux glibc, x86_64 and aarch64 | `x86_64-linux`, `aarch64-linux` native gem |
| Linux musl (Alpine) | `x86_64-linux-musl`, `aarch64-linux-musl` native gem |
| Windows (RubyInstaller, UCRT) | `x64-mingw-ucrt`, `aarch64-mingw-ucrt` native gem |
| anything else, or `force_ruby_platform` | the source gem: needs libpq headers and `pg_config`, for example `gem install pg -- --with-pg-config=/path/to/pg_config` |

Run `bundle lock --add-platform x86_64-linux` on a Mac before deploying to Linux, so the lockfile names the Linux gem.

## Ruby quickstart: connect, query and close with the pg gem

This quickstart uses a Gemfile with `pg` and `bigdecimal`, then a script that connects, runs one parameterized query
with typed results, and closes. On Ruby 3.4 and later `bigdecimal` is a bundled gem that Bundler loads only when the
Gemfile names it; without it `numeric` columns stay strings.

```ruby
# Gemfile
source "https://rubygems.org"
gem "pg", "~> 1.7"
gem "bigdecimal"
```

The script below is `quick.rb`; run it with `bundle install` then
`DATABASE_URL=postgres://app:secret@localhost/app bundle exec ruby quick.rb`.

```ruby
require "pg"

conn = PG.connect(ENV.fetch("DATABASE_URL"))
begin
  conn.type_map_for_results = PG::BasicTypeMapForResults.new(conn)
  conn.type_map_for_queries = PG::BasicTypeMapForQueries.new(conn)
  row = conn.exec_params("SELECT version() AS v, $1::int8 * 2 AS answer, now() AS at", [21]).first
  puts row["v"], row["answer"], row["at"].class   # Integer 42, Time
ensure
  conn.close
end
```

Add `?sslmode=verify-full&sslrootcert=...` to the URL for any server off the machine.

## Step 0: read Ruby, pg and Rails versions

The installed versions decide the API (Rails 8.1 renamed `pool` to `max_connections`), so read them first.

```bash
ruby -v
bundle exec ruby -e 'require "pg"; puts PG::VERSION, PG.library_version'
bundle exec rails -v 2>/dev/null; bundle list | grep -E ' (pg|activerecord|sequel|solid_queue|strong_migrations) '
```

Current in October 2026: Ruby 4.0.6, `pg` 1.7.0, Rails and Active Record 8.1.4, `sequel` 5.109.0, `solid_queue`
1.7.0, `strong_migrations` 2.8.0.

## pg gem queries, prepared statements and type maps

`exec_params` sends SQL and values separately (`$1`, `$2`); `prepare` plus `exec_prepared` reuses a named server-side
statement. Without a type map every value comes back as a `String`; `PG::BasicTypeMapForResults` decodes integers,
floats, booleans, `numeric` (BigDecimal), timestamps, arrays and JSON, and `PG::BasicTypeMapForQueries` encodes Ruby
arrays, hashes and BigDecimals on the way in.

```ruby
conn.exec_params("INSERT INTO items (sku, price, tags, attrs) VALUES ($1, $2, $3, $4)",
                 ["A-1", "19.90", ["red", "big"], { "w" => 3 }])     # array -> text[], hash -> json
row = conn.exec_params("SELECT id, price, tags, attrs, created_at FROM items WHERE sku = $1", ["A-1"]).first
# {"id"=>1, "price"=>0.199e2, "tags"=>["red", "big"], "attrs"=>{"w"=>3}, "created_at"=>2026-10-28 09:42:16 -0400}
conn.prepare("item_by_sku", "SELECT id FROM items WHERE sku = $1")
conn.exec_prepared("item_by_sku", ["A-1"])
```

Decoded timestamps are local-time `Time` objects; call `.utc` before comparing or serializing. `exec` with no
parameters may hold several statements; `exec_params` takes exactly one.

## Transactions, retries and errors with the pg gem

`conn.transaction { |c| ... }` commits at the end of the block and rolls back and re-raises on an exception. The pg
gem maps every SQLSTATE to a class (`PG::ERROR_CLASSES["40001"]`), so rescue the class.

```ruby
def with_retry(conn, attempts: 3)
  tries = 0
  begin
    tries += 1
    conn.transaction do |c|
      c.exec("SET TRANSACTION ISOLATION LEVEL SERIALIZABLE")
      yield c
    end
  rescue PG::TRSerializationFailure, PG::TRDeadlockDetected
    raise if tries >= attempts
    sleep(0.025 * 2**tries + rand * 0.05)
    retry
  end
end

begin
  conn.exec_params("INSERT INTO items (sku, price) VALUES ($1, $2)", ["A-1", 1])
rescue PG::UniqueViolation => e
  e.result.error_field(PG::PG_DIAG_CONSTRAINT_NAME)   # "items_sku_key"; PG_DIAG_SQLSTATE gives "23505"
end
```

Other useful classes: `PG::QueryCanceled` (`57014`, statement timeout), `PG::LockNotAvailable` (`55P03`, lock
timeout or `NOWAIT`), `PG::ForeignKeyViolation`, `PG::ConnectionBad`.

## COPY, pipeline mode and LISTEN with the pg gem

`copy_data` wraps `COPY ... FROM STDIN` or `TO STDOUT`; with a `PG::TextEncoder::CopyRow` you pass Ruby arrays and
the gem escapes them.

```ruby
enco = PG::TextEncoder::CopyRow.new
conn.copy_data("COPY items (sku, price) FROM STDIN", enco) do
  rows.each { |sku, price| conn.put_copy_data([sku, price]) }
end

deco = PG::TextDecoder::CopyRow.new
conn.copy_data("COPY (SELECT sku, price FROM items) TO STDOUT", deco) do
  while (row = conn.get_copy_data) do handle(row) end      # ["A-1", "19.90"]
end
```

Pipeline mode sends many statements before reading any result, which removes a network round trip per statement.
After `pipeline_sync`, read one result plus a `nil` per statement, then the sync result.

```ruby
conn.enter_pipeline_mode
conn.send_query_params("SELECT $1::int + 1", [1])
conn.send_query_params("SELECT $1::int + 2", [1])
conn.pipeline_sync
r1 = conn.get_result; conn.get_result
r2 = conn.get_result; conn.get_result
conn.get_result                                            # PGRES_PIPELINE_SYNC
conn.exit_pipeline_mode
```

`wait_for_notify(timeout)` blocks until a `NOTIFY` arrives on a channel the connection listens to. Since pg 1.3 every
blocking call goes through Ruby's `Fiber.scheduler` when one is set, so the same code works under Falcon or the
`async` gem.

```ruby
conn.exec("LISTEN jobs")
loop do
  conn.wait_for_notify(30) { |channel, pid, payload| handle(payload) }   # returns nil after 30 s
end
```

## Sequel with PostgreSQL

Sequel 5 is a full SQL toolkit; its PostgreSQL extensions add jsonb, arrays, COPY, LISTEN and retrying transactions.

```ruby
require "sequel"
Sequel.extension :pg_json_ops
DB = Sequel.connect(ENV.fetch("DATABASE_URL"), max_connections: 5, pool_timeout: 5)
DB.extension :pg_json, :pg_array
DB.transaction(isolation: :serializable, retry_on: [Sequel::SerializationFailure], num_retries: 3) do
  DB[:events].where(kind: "x").update(kind: "z")
end
DB[:events].where(Sequel.pg_jsonb_op(:payload).contains("plan" => "pro")).select_map(:kind)
DB[:events].insert_conflict(target: :id, update: { kind: Sequel[:excluded][:kind] }).insert(id: 1, kind: "a", payload: Sequel.pg_jsonb({}))
DB.copy_into(:events, columns: [:kind, :payload], data: "c1\t{}\nc2\t{}\n")
DB.listen("jobs", timeout: 30) { |channel, pid, payload| handle(payload) }
```

## Rails database.yml for PostgreSQL

Rails 8.1 sizes the Active Record pool with `max_connections` (new apps are generated with it; the older `pool`
key still works) and passes `variables` as session settings on every new connection.

```yaml
default: &default
  adapter: postgresql
  encoding: unicode
  max_connections: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>
  checkout_timeout: 5          # seconds to wait for a free connection
  idle_timeout: 300            # close connections idle this long
  variables:
    statement_timeout: 30s
    lock_timeout: 5s

production:
  primary:
    <<: *default
    url: <%= ENV["DATABASE_URL"] %>
```

Set `max_connections` at least to Puma's thread count per process; the server sees processes times
`max_connections`. Other pool keys: `min_connections`, `keepalive` (600 s), `max_age` for retiring connections.

## Rails behind PgBouncer: prepared_statements and advisory_locks

Active Record prepares statements and takes a session-level advisory lock while migrating; both are session state
that a transaction-mode pooler does not keep. Set on the pooled connection:

```yaml
production:
  primary:
    <<: *default
    url: <%= ENV["DATABASE_URL"] %>     # PgBouncer, transaction mode
    advisory_locks: false
    prepared_statements: false          # keep true with PgBouncer 1.21+ and max_prepared_statements > 0
```

Run migrations against the server directly (a second URL in the deploy step) so `advisory_locks` can stay on there.
`statement_limit` (default 1000 per connection) caps prepared statements when they stay on.

## Rails migrations on PostgreSQL without long locks

Rails wraps each migration in a transaction. `disable_ddl_transaction!` turns that off for one migration so
`algorithm: :concurrently` can build the index without blocking writes.

```ruby
class AddOrdersCreatedIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :orders, :created_at, algorithm: :concurrently, if_not_exists: true
  end
end
```

The `strong_migrations` gem stops dangerous migrations before they run (an index without `concurrently`, a foreign
key that validates at once, a column type change) and prints the safe version. Install it with
`rails generate strong_migrations:install`, and set `StrongMigrations.target_version = 18` and its timeouts in the
initializer. Migration patterns: [references/rails.md](references/rails.md).

## schema.rb or structure.sql in Rails

`schema.rb` (the default, `schema_format = :ruby`) records what the Ruby DSL can express: tables, indexes including
partial and expression ones, check constraints, enum types and extensions. It drops triggers, functions, views,
policies and custom types other than enums, and it writes a partition as `options: "INHERITS (parent)"`, which
fails to load (`cannot inherit from partitioned table`). Switch to `config.active_record.schema_format = :sql` once
the schema has any of them; `db/structure.sql` is then written by `pg_dump`, which must be on `PATH` and at least
the server's major version. Set `schema_format` per database in `database.yml` when only some databases need SQL.

## Gotchas

The Ruby and Postgres failures seen most often, each with its cause and fix.

1. **`prepared statement "a1" already exists` or `does not exist` behind PgBouncer.** Transaction pooling without
   prepared statement tracking. PgBouncer 1.21+ with `max_prepared_statements` above 0, or
   `prepared_statements: false`.
2. **`ActiveRecord::ConcurrentMigrationError: Failed to release advisory lock` through PgBouncer.** The session
   advisory lock was taken on one server connection and released on another. Set `advisory_locks: false` on the
   pooled config, or migrate through a direct URL.
3. **`numeric` values come back as strings from the pg gem.** `bigdecimal` is not loadable (Ruby 3.4+ bundled gem
   missing from the Gemfile), so the type map skipped `numeric`. Add `gem "bigdecimal"`.
4. **Solid Queue tables are missing after `db:prepare`.** With `schema_format = :sql` for the app, the queue database
   looked for `db/queue_structure.sql` and ignored `db/queue_schema.rb`. Set `schema_format: ruby` on the `queue`
   entry in `database.yml`.
5. **Loading `structure.sql` fails with `unrecognized configuration parameter "transaction_timeout"`.** A pg_dump 17
   or newer wrote `SET transaction_timeout = 0;` and the target server is older. Run the same major in CI as in
   production.
6. **`find_each` returns rows in id order, not the `order` you gave.** Batches walk the primary key and ignore
   `order`. Use `find_each(cursor: [:created_at, :id], order: [:desc, :desc])` (a unique cursor) and set
   `config.active_record.error_on_ignored_order = true` to catch it.

## Anti-patterns in Ruby and Rails on Postgres

These pass in development and fail against production data or behind a pooler.

| Anti-pattern | What goes wrong | Do instead |
|---|---|---|
| Interpolating values into SQL strings | SQL injection | `$1` with the pg gem, `?` or hashes in Active Record |
| `add_index` on a live table without `algorithm: :concurrently` | writes block for the whole build | `disable_ddl_transaction!` plus `algorithm: :concurrently` |
| Running migrations through transaction-mode PgBouncer | the advisory lock and session settings do not survive | a direct URL in the deploy step |
| A pool smaller than Puma's threads | threads wait for `checkout_timeout`, then raise | `max_connections` at least the thread count |
| `Model.all.each` on a large table | every row loads into memory | `find_each` with a unique cursor |
| `schema.rb` with triggers, functions or views | they vanish from the dumped schema | `schema_format = :sql` |
| `rescue StandardError` and retry | real bugs repeat, and writes run twice | retry only `40001` and `40P01`, around the outermost transaction |

## Verify the pg gem and Rails against a scratch database

The first two lines ran with `pg` 1.7.0 on PostgreSQL 18.6: the first prints the client library, the answer `42` and
the server version, the second prints the SQLSTATE `22012` that retries and rescues depend on.

```bash
ruby -rpg -e 'c = PG.connect(ENV.fetch("DATABASE_URL")); puts PG.library_version, c.exec_params("SELECT $1::int + 1", [41]).getvalue(0, 0), c.server_version; c.close'
ruby -rpg -e 'c = PG.connect(ENV.fetch("DATABASE_URL")); begin; c.exec("SELECT 1/0"); rescue PG::DivisionByZero => e; puts e.result.error_field(PG::Result::PG_DIAG_SQLSTATE); end'
```

Then prove the migrations rebuild the schema. These Rails tasks were not run here: no Rails app was on the test machine.

```bash
RAILS_ENV=test bin/rails db:drop db:create db:migrate    # applies from empty
RAILS_ENV=test bin/rails db:migrate:status               # every line up
git diff --exit-code -- db/                              # the dump matches what is committed
bin/rails runner 'puts ActiveRecord::Base.connection.select_value("SHOW lock_timeout")'   # the value from variables
```

## Checklist

Check these points before you call Ruby database code done.

- [ ] `pg` 1.7 from a native gem, lockfile has every deploy platform, `bigdecimal` in the Gemfile.
- [ ] Every value bound (`$1` with the pg gem, `?` or hashes in Active Record); no string interpolation into SQL.
- [ ] `max_connections` matches threads; `statement_timeout` and `lock_timeout` set in `variables`.
- [ ] Behind PgBouncer: `advisory_locks: false`, prepared statements handled, migrations on a direct URL.
- [ ] Index migrations use `disable_ddl_transaction!` and `algorithm: :concurrently`; `strong_migrations` installed.
- [ ] Retries only on `40001` and `40P01`, around the outermost transaction.
- [ ] `structure.sql` once the schema has triggers, functions, views or policies.

## See also

Related skills in this library:

- `postgres-app-drivers`: the driver chooser across languages
- `postgres-connection-pooling`: PgBouncer modes and pool sizes
- `postgres-schema-migrations`: lock-safe DDL
- `postgres-transactions-locking`: isolation levels and retries
- `postgres-queues-jobs`: queue tables under Solid Queue and others

## Sources

- https://github.com/ged/ruby-pg (README, CHANGELOG v1.7.0) and https://rubygems.org/gems/pg/versions/1.7.0
- https://guides.rubyonrails.org/active_record_postgresql.html and /active_record_migrations.html
- https://guides.rubyonrails.org/configuring.html (Configuring a PostgreSQL Database, schema_format)
- https://api.rubyonrails.org/classes/ActiveRecord/ConnectionAdapters/ConnectionPool.html (Active Record 8.1.4)
- https://github.com/ankane/strong_migrations and https://github.com/rails/solid_queue (README, 1.7.0)
- https://sequel.jeremyevans.net/rdoc/files/doc/postgresql_rdoc.html
- https://www.postgresql.org/docs/18/sql-createindex.html and https://www.postgresql.org/docs/18/app-pgdump.html
