---
title: Rails 8.1 Active Record on PostgreSQL
author: MOZGII, Inc.
lang: en
---

# Rails 8.1 Active Record on PostgreSQL

This reference holds the Active Record code for PostgreSQL features that Rails supports but scatters across guides:
enum types, jsonb and array columns, GIN and partial indexes, upsert_all and insert_all, batches, row locks with
SKIP LOCKED, advisory locks, isolation levels, strong_migrations, and Solid Queue. Every example ran on Ruby 4.0.6,
Active Record 8.1.4 and PostgreSQL 18.6 in October 2026.

## Contents

The sections of this reference on Rails 8.1 Active Record on PostgreSQL:

1. Rails migration with an enum type, jsonb, arrays, GIN and a partial unique index
2. Adding a value to a PostgreSQL enum in Rails
3. Querying jsonb and arrays from Active Record
4. upsert_all and insert_all on PostgreSQL
5. Batches with find_each and in_batches
6. Row locks and SKIP LOCKED in Active Record
7. Advisory locks and isolation levels in Rails
8. strong_migrations setup for PostgreSQL
9. Solid Queue on PostgreSQL
10. Solid Queue with structure.sql

## Rails migration with an enum type, jsonb, arrays, GIN and a partial unique index

A Rails 8.1 migration can create a PostgreSQL enum type, `jsonb` and array columns, GIN indexes and a partial unique
index with the Ruby DSL alone, so `schema.rb` keeps all of it.

```ruby
class CreateOrders < ActiveRecord::Migration[8.1]
  def change
    create_enum :order_status, %w[pending paid shipped]
    create_table :orders do |t|
      t.string :email, null: false
      t.enum :status, enum_type: :order_status, null: false, default: "pending"
      t.jsonb :meta, null: false, default: {}
      t.string :tags, array: true, null: false, default: []
      t.decimal :total, precision: 12, scale: 2, null: false
      t.timestamps
    end
    add_index :orders, :meta, using: :gin
    add_index :orders, :tags, using: :gin
    add_index :orders, :email, unique: true, where: "status <> 'shipped'", name: "orders_open_email_key"
  end
end
```

Rails `t.timestamps` creates `timestamp(6) without time zone` columns and stores UTC in them by default
(`default_timezone = :utc`). Keep that default; do not mix in code that writes local time.

The model maps the enum type to Ruby symbols; `validate: true` turns a bad value into a validation error instead of
an `ArgumentError`.

```ruby
class Order < ApplicationRecord
  enum :status, { pending: "pending", paid: "paid", shipped: "shipped" }, validate: true
end
```

## Adding a value to a PostgreSQL enum in Rails

`add_enum_value` runs `ALTER TYPE ... ADD VALUE`; `rename_enum_value` renames one. PostgreSQL cannot drop an enum
value, so a removal means a new type and a column rewrite.

```ruby
class AddRefundedStatus < ActiveRecord::Migration[8.1]
  def up
    add_enum_value :order_status, "refunded", after: "shipped"
  end
end
```

A value added inside a transaction cannot be used in that same transaction; put the data change that uses it in a
later migration.

## Querying jsonb and arrays from Active Record

Active Record casts `jsonb` to a Hash and arrays to Ruby arrays. Containment queries go through SQL fragments with
bound values, which the GIN indexes above serve.

```ruby
Order.where("meta @> ?", { src: "web" }.to_json)      # jsonb containment, GIN index
Order.where("? = ANY(tags)", "vip")                   # array membership
Order.where("tags @> ARRAY[?]::varchar[]", ["vip"])   # array containment, GIN index
```

`= ANY(tags)` cannot use a GIN index on `tags`; `@>` can.

## upsert_all and insert_all on PostgreSQL

`upsert_all` compiles to `INSERT ... ON CONFLICT ... DO UPDATE` and `insert_all` to `ON CONFLICT DO NOTHING`; both
skip validations and callbacks and send one statement. `unique_by` accepts an index name, and Rails repeats a partial
index's `WHERE` in the conflict target, so the partial unique index above works.

```ruby
Order.upsert_all(
  [{ email: "a@x.example", total: 99, status: "pending" }, { email: "b@x.example", total: 5, status: "paid" }],
  unique_by: :orders_open_email_key, update_only: [:total], returning: %w[id email total]
)
Order.insert_all([{ email: "b@x.example", total: 1 }, { email: "c@x.example", total: 2 }], returning: %w[email])
# => only c@x.example comes back: b@x.example hit the unique index and was skipped
```

Each conflicting row still consumes a sequence value, so ids have gaps; that is expected.

## Batches with find_each and in_batches

`find_each` and `in_batches` page by the primary key with `WHERE id > last_id`, so each batch is an index range scan
and no `OFFSET` grows with the table. Rails 8 adds `cursor:` for another unique key.

```ruby
Order.where(status: "paid").find_each(batch_size: 1000) { |o| o.touch }
Order.in_batches(of: 5000).update_all("meta = meta || '{\"migrated\": true}'::jsonb")
Order.find_each(cursor: [:created_at, :id], order: [:desc, :desc]) { |o| }
```

## Row locks and SKIP LOCKED in Active Record

`lock` takes a lock clause string, so `FOR UPDATE SKIP LOCKED` works for job claims; it must run inside a
transaction.

```ruby
Order.transaction do
  job = Order.where(status: "pending").order(:id).lock("FOR UPDATE SKIP LOCKED").first
  job&.update!(status: "paid")
end
# SELECT "orders".* FROM "orders" WHERE "orders"."status" = 'pending' ORDER BY "orders"."id" ASC LIMIT 1
#   FOR UPDATE SKIP LOCKED
```

`record.lock!` re-reads one row with `FOR UPDATE`; `with_lock { }` does that inside a transaction.

## Advisory locks and isolation levels in Rails

Active Record has no public advisory lock API; call the PostgreSQL function. The transaction-scoped form is safe
through a transaction pooler.

```ruby
Order.transaction do
  got = Order.connection.select_value("SELECT pg_try_advisory_xact_lock(hashtext('nightly-report'))")
  next unless got                         # another process holds it
  # ... the work; the lock ends with the transaction
end

ActiveRecord::Base.transaction(isolation: :serializable) do
  Order.where(email: "a@x.example").update_all("total = total + 1")
end
```

`ActiveRecord::SerializationFailure` (40001) and `ActiveRecord::Deadlocked` (40P01) both inherit from
`ActiveRecord::TransactionRollbackError`; rescue it around the outermost transaction and retry the block.
`ActiveRecord::LockWaitTimeout` is `lock_timeout`, `ActiveRecord::QueryCanceled` is `statement_timeout`.

## strong_migrations setup for PostgreSQL

strong_migrations 2.8 checks each migration before it runs and raises `StrongMigrations::UnsafeMigration` with the
safe alternative. An index added without `algorithm: :concurrently` and a foreign key added with validation in the
same step are both stopped. Settings go in the generated initializer:

```ruby
# config/initializers/strong_migrations.rb
StrongMigrations.lock_timeout = 10.seconds
StrongMigrations.statement_timeout = 1.hour
StrongMigrations.target_version = 18          # the production PostgreSQL major
```

Mark a reviewed exception with `safety_assured { ... }` in the migration, never by disabling the gem.

## Solid Queue on PostgreSQL

Solid Queue 1.7 is the Rails 8 default Active Job backend. It stores jobs in its own tables and claims them with
`FOR UPDATE SKIP LOCKED`; workers poll every 0.1 s and dispatchers every 1 s by default, with no `LISTEN`. A new
Rails 8.1 app configures a separate `queue` database in production; in development, add it the same way:

```yaml
development:
  primary:
    <<: *default
    database: app_development
  queue:
    <<: *default
    database: app_development_queue
    migrations_paths: db/queue_migrate
    schema_format: ruby
```

```ruby
# config/environments/development.rb
config.active_job.queue_adapter = :solid_queue
config.solid_queue.connects_to = { database: { writing: :queue } }
```

Then `bin/rails db:prepare` creates both databases and loads `db/queue_schema.rb`, and `bin/jobs` starts the
supervisor. Size the queue database pool to at least worker threads plus 2: each worker also polls and sends
heartbeats. Finished jobs stay for `clear_finished_jobs_after` (1 day by default) and a recurring task clears them.
With a separate queue database, a job enqueued inside an application transaction commits on its own: it can run
before that transaction commits, or after it rolls back. Set `self.enqueue_after_transaction_commit = true` in
`ApplicationJob` (off by default) so Active Job enqueues only after commit.

## Solid Queue with structure.sql

With `config.active_record.schema_format = :sql`, every database without its own `schema_format` dumps and loads
SQL, so the queue database looks for `db/queue_structure.sql` and `db:prepare` leaves it empty. Keep
`schema_format: ruby` on the `queue` entry, as above. The single-database alternative copies `db/queue_schema.rb`
into a normal migration and drops `connects_to`.
