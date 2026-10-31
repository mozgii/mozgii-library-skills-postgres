---
title: Laravel 13 on PostgreSQL
author: MOZGII, Inc.
lang: en
---

# Laravel 13 on PostgreSQL

This reference shows Laravel 13 code for PostgreSQL that the framework docs leave scattered: migrations with jsonb,
GIN, partial and online indexes, Eloquent casts, upserts against partial unique indexes, row locking with
SKIP LOCKED, transaction retries, the database queue driver, and Octane. Every example ran on Laravel 13.39.0,
PHP 8.5.12 and PostgreSQL 18.6 in October 2026.

## Contents

The sections of this reference on Laravel 13 on PostgreSQL:

1. Laravel migration with jsonb, GIN and a partial unique index
2. Online index creation in a Laravel migration
3. Eloquent model casts for jsonb and numeric
4. Querying jsonb from Laravel
5. Laravel upsert and partial unique indexes
6. Row locking and SKIP LOCKED in Laravel
7. Transaction retries in Laravel
8. Laravel queues on the database driver with PostgreSQL
9. Laravel Octane and database connections
10. PgBouncer and Laravel pooled mode

## Laravel migration with jsonb, GIN and a partial unique index

A Laravel migration on PostgreSQL can create `jsonb` columns and GIN indexes with the schema builder; a partial
index has no builder method, so it goes through `DB::statement`. Laravel runs each migration in a transaction on
PostgreSQL, so the raw statements roll back with the rest on failure.

```php
<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('orders', function (Blueprint $table) {
            $table->id();                                        // bigserial; ->generatedAs() for an identity column
            $table->string('email');
            $table->string('status')->default('pending');
            $table->jsonb('meta')->default('{}');
            $table->decimal('total', 12, 2);
            $table->timestampsTz(6);                             // timestamptz(6); the default precision is 0
            $table->index('meta', 'orders_meta_gin')->algorithm('gin');
        });
        DB::statement("CREATE UNIQUE INDEX orders_open_email_key ON orders (email) WHERE status <> 'shipped'");
        DB::statement("ALTER TABLE orders ADD CONSTRAINT orders_status_check CHECK (status IN ('pending','paid','shipped'))");
    }

    public function down(): void
    {
        Schema::dropIfExists('orders');
    }
};
```

Use `timestampsTz()` rather than `timestamps()`: the second creates `timestamp without time zone`, which stores the
wall-clock value of whatever zone the session had. Laravel's default time precision is 0, which rounds away fractional
seconds; pass 6 or call `Schema::defaultTimePrecision(6)` once in a service provider. `->nullsNotDistinct()` on a unique index gives PostgreSQL 15+
`NULLS NOT DISTINCT`.

## Online index creation in a Laravel migration

`->online()` on an index adds `CONCURRENTLY` on PostgreSQL, so the build does not block writes. `CREATE INDEX
CONCURRENTLY` cannot run in a transaction, so the migration must turn its transaction off; without that, it fails
with SQLSTATE `25001`.

```php
return new class extends Migration
{
    public $withinTransaction = false;

    public function up(): void
    {
        Schema::table('orders', function (Blueprint $table) {
            $table->index('created_at')->online();
        });
    }

    public function down(): void
    {
        Schema::table('orders', function (Blueprint $table) {
            $table->dropIndex(['created_at']);
        });
    }
};
```

Put one online index in its own migration: with no transaction, a failure halfway leaves earlier statements applied,
and a failed concurrent build leaves an `INVALID` index to drop before retrying (`postgres-indexing`).

## Eloquent model casts for jsonb and numeric

Eloquent casts turn `jsonb` strings into arrays and keep `numeric` as a fixed-scale string, because PDO returns both
as strings.

```php
class Order extends Model
{
    protected $fillable = ['email', 'status', 'meta', 'total'];

    protected function casts(): array
    {
        return ['meta' => 'array', 'total' => 'decimal:2'];      // or AsArrayObject::class for in-place edits
    }
}
```

`decimal:2` returns `"10.50"` as a string; do arithmetic with `bcmath` or a money library, not floats.

## Querying jsonb from Laravel

Laravel's JSON helpers compile to PostgreSQL operators, so the GIN index can serve them.

```php
Order::whereJsonContains('meta', ['src' => 'web'])->count();
// select ... where ("meta")::jsonb @> '{"src":"web"}'
Order::where('meta->src', 'web')->get();         // ->> path extraction; needs an expression index to be fast
```

`@>` uses the default `jsonb_ops` GIN index; `meta->src = ...` needs an expression index on `(meta->>'src')`.

## Laravel upsert and partial unique indexes

`upsert($values, $uniqueBy, $update)` compiles to `INSERT ... ON CONFLICT (cols) DO UPDATE`. PostgreSQL must find a
unique index or constraint on exactly those columns; a partial unique index does not match unless the statement
repeats its `WHERE`, which Laravel cannot express. The call then fails with `42P10 there is no unique or exclusion
constraint matching the ON CONFLICT specification`. Write that statement by hand:

```php
DB::affectingStatement(<<<SQL
    INSERT INTO orders (email, total, meta, status, created_at, updated_at)
    VALUES (?, ?, '{}', 'pending', now(), now())
    ON CONFLICT (email) WHERE status <> 'shipped'
    DO UPDATE SET total = EXCLUDED.total, updated_at = now()
SQL, ['a@x.example', 99]);
```

`DB::table()->upsert()` does not fill `created_at` and `updated_at`; `Model::upsert()` does.

## Row locking and SKIP LOCKED in Laravel

`lockForUpdate()` adds `FOR UPDATE` and `sharedLock()` adds `FOR SHARE`. Laravel 13 has no `skipLocked()` method;
pass the clause as a string to `lock()`, inside a transaction:

```php
$id = DB::transaction(function () {
    $row = DB::table('orders')->where('status', 'pending')->orderBy('id')
        ->lock('for update skip locked')->first();
    // ... claim it: update status, then commit
    return $row?->id;
});
// select * from "orders" where "status" = ? order by "id" asc limit 1 for update skip locked
```

Keep the claim transaction short and do the work after commit (`postgres-transactions-locking`).

## Transaction retries in Laravel

`DB::transaction($callback, attempts: 3)` re-runs the callback when the error is a concurrency error: SQLSTATE
`40001`, or a message containing `deadlock detected`. Retries happen only for the outermost transaction; a nested
one rethrows as `DeadlockException`. The deadlock test matches English message text, so keep the server's
`lc_messages` in English (`C` or `en_US.UTF-8`) for the database Laravel uses.

```php
DB::transaction(function () use ($sku) {
    DB::statement('SET TRANSACTION ISOLATION LEVEL SERIALIZABLE');
    DB::table('stock')->where('sku', $sku)->decrement('qty');
}, attempts: 3);
```

## Laravel queues on the database driver with PostgreSQL

The `database` queue driver stores jobs in the `jobs` table (created by the default migration) and, on PostgreSQL
9.5 and later, claims them with `FOR UPDATE SKIP LOCKED`, so many `queue:work` processes can share one table.

```php
// config/queue.php
'database' => [
    'driver' => 'database',
    'connection' => env('DB_QUEUE_CONNECTION'),     // a direct connection if the main one is pooled
    'table' => env('DB_QUEUE_TABLE', 'jobs'),
    'queue' => env('DB_QUEUE', 'default'),
    'retry_after' => (int) env('DB_QUEUE_RETRY_AFTER', 90),
    'after_commit' => true,                          // dispatch only after the surrounding transaction commits
],
```

`after_commit` defaults to `false`: a job dispatched inside a transaction can run before the row it needs is
committed, or after a rollback. Set it to `true`, or chain `->afterCommit()` on the dispatch. Run workers with
`php artisan queue:work --tries=3 --max-time=3600`, and prune finished and failed rows so the table does not bloat.

## Laravel Octane and database connections

Octane keeps the application in memory between requests, so each worker keeps its database connections open; the
connection count is workers times servers. The `DisconnectFromDatabases` listener ships commented out under
`OperationTerminated` in `config/octane.php`; enable it to close connections after each request, at the cost of a
new connection per request. Never leave a transaction or a session `SET` open at the end of a request: the next
request on that worker inherits it.

## PgBouncer and Laravel pooled mode

Laravel 13 supports transaction-mode poolers with two keys on the `pgsql` connection: `'pooled' => true` and a
`direct` array (host, port, username, password, sslmode) for the server itself. Pooled connections use emulated
prepares; migrations, schema dumps and restores, `db:wipe`, `db:show` and `db:table` use the direct connection.
Session features break through a transaction pooler: `LISTEN`, session advisory locks, `SET` without `LOCAL`, and
temp tables. Use the direct connection for those (`postgres-connection-pooling`).
