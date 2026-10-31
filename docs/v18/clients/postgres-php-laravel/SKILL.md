---
name: postgres-php-laravel
description: 'Connects PHP to PostgreSQL correctly with PDO pgsql, the Pdo\Pgsql class of PHP 8.4 and 8.5, the pgsql extension, Laravel 13 and Doctrine: install per OS, a working quickstart, DSN and attributes, native or emulated prepares, transactions with retries, COPY with copyFromArray, LISTEN with getNotify, Laravel config with PgBouncer pooled mode, jsonb, GIN, partial and online index migrations, upsert, SKIP LOCKED, database queues, Octane and persistent connections. Use when writing PHP or Laravel code against Postgres, "could not find driver", "prepared statement does not exist" behind PgBouncer, a Laravel upsert fails with 42P10, or a PHP worker runs out of memory on a big query.'
metadata:
  tags:
  - postgres
  - php
  - pdo
  - pdo-pgsql
  - laravel
  - eloquent
  - doctrine
  - symfony
  - pgbouncer
---

# PostgreSQL from PHP with PDO, Laravel and Doctrine

Use PDO with the `pdo_pgsql` driver: exceptions on, native prepared statements, every value bound. On PHP 8.4 and
later, create the connection with `PDO::connect()` to get the `Pdo\Pgsql` class with COPY and LISTEN methods. In
Laravel 13, put timeouts in `server_options`, and behind a transaction-mode PgBouncer turn on `pooled` with a
`direct` connection for migrations. The cross-language chooser is `postgres-app-drivers`; pool sizing and PgBouncer
modes are in `postgres-connection-pooling`; lock-safe DDL in `postgres-schema-migrations`; queue design in
`postgres-transactions-locking`. Laravel detail: [references/laravel.md](references/laravel.md); Doctrine and Symfony:
[references/doctrine-symfony.md](references/doctrine-symfony.md).


## Choosing PDO, the pgsql extension, Laravel or Doctrine

Pick by what the code is. All of them link libpq, so its keywords work in each.

| Code is | Use | Why the others lose here |
|---|---|---|
| A plain script or small service | PDO with `pdo_pgsql` | the `pgsql` extension returns every value as a string |
| COPY or LISTEN on PHP 8.4 or later | `Pdo\Pgsql` from `PDO::connect()` | the old `PDO::pgsqlCopyFromArray()` methods raise a deprecation on 8.5 |
| A Laravel application | its `pgsql` connection | raw PDO skips Laravel's pooled mode and `server_options` |
| A Symfony application or a mapped domain model | Doctrine DBAL and ORM | array-based code repeats the mapping by hand |

## Install pdo_pgsql on macOS, Linux, Windows and Docker

PHP talks to Postgres through `pdo_pgsql` (and the older `pgsql` extension), both linked against libpq; PHP 8.4
and later need libpq 10 or newer. `php -m | grep -i pgsql` must list `pdo_pgsql`, or PDO fails with
`could not find driver`.

| Platform | How |
|---|---|
| macOS, Homebrew | `brew install php`: the formula depends on `libpq` and includes `pdo_pgsql` and `pgsql` |
| Debian, Ubuntu | `apt install php8.4-pgsql` (the version in the package name follows the PHP package) |
| Windows | in `php.ini` uncomment `extension=pdo_pgsql` (and `extension=pgsql`); the official zip ships the DLLs |
| Docker `php` image | `apt-get install -y libpq-dev && docker-php-ext-install pdo_pgsql pgsql` |

This Dockerfile builds a PHP 8.5 CLI image with both extensions and Composer.

```dockerfile
FROM php:8.5-cli
RUN apt-get update && apt-get install -y --no-install-recommends libpq-dev unzip git \
 && docker-php-ext-install pdo_pgsql pgsql && rm -rf /var/lib/apt/lists/*
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer
```

## PHP quickstart: connect, query and close with PDO

This quickstart script connects with `PDO::connect()`, runs one parameterized query and closes the connection. Save
it as `quick.php` and run `PGPASSWORD=secret php quick.php`.

```php
<?php
declare(strict_types=1);

$pdo = PDO::connect('pgsql:host=localhost;port=5432;dbname=app;sslmode=prefer;application_name=quick', 'app',
    getenv('PGPASSWORD') ?: null, [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
        PDO::ATTR_EMULATE_PREPARES => false,
    ]);
echo get_class($pdo), "\n";                                   // Pdo\Pgsql on PHP 8.4+

$st = $pdo->prepare('SELECT version() AS v, ?::int8 * 2 AS answer');
$st->execute([21]);
print_r($st->fetch());

$pdo = null;                                                  // closes the connection
```

Use `sslmode=verify-full` with `sslrootcert=...` for any server off the machine. PDO placeholders are `?` or
`:name`, never `$1`; write the jsonb operator `?` as `??` so PDO does not read it as a placeholder.

## Step 0: read PHP, driver and framework versions

Versions decide which API exists (`Pdo\Pgsql` is 8.4+, lazy fetching is 8.5+), so read them first.

```bash
php -v && php -m | grep -i pgsql
php -r 'echo phpversion("pdo_pgsql"), "\n";'
composer show | grep -E '^(laravel/framework|laravel/octane|doctrine/dbal|doctrine/orm) '
```

Current in October 2026: PHP 8.5.12 (8.4.27 supported), `laravel/framework` 13.39.0 (needs PHP 8.3+),
`laravel/octane` 2.22.0, `doctrine/dbal` 4.5.0, `doctrine/orm` 3.7.6, `doctrine/migrations` 3.9.8, Symfony 8.1.9.

## PDO pgsql DSN and connection attributes

The PDO pgsql DSN is `pgsql:` followed by `key=value` pairs separated by `;`; the driver hands them to libpq, so any
libpq keyword works (`sslmode`, `sslrootcert`, `connect_timeout`, `application_name`, `options`).

| Attribute | Default for pgsql | Set it to |
|---|---|---|
| `PDO::ATTR_ERRMODE` | `ERRMODE_EXCEPTION` (since PHP 8.0) | keep; never silent mode |
| `PDO::ATTR_EMULATE_PREPARES` | `false` (server-side prepares) | `false`; `true` only behind an old pooler |
| `Pdo\Pgsql::ATTR_DISABLE_PREPARES` | off | on: query and parameters go in one call, no named statement |
| `PDO::ATTR_DEFAULT_FETCH_MODE` | `FETCH_BOTH` | `FETCH_ASSOC` |
| `PDO::ATTR_STRINGIFY_FETCHES` | `false` | keep: ints, bools and floats come back typed |
| `PDO::ATTR_PREFETCH` | buffered | `0` (PHP 8.5+): lazy, row-at-a-time fetching for huge results |
| `PDO::ATTR_PERSISTENT` | `false` | `false` unless the server can hold one connection per PHP worker |

Session settings ride in the DSN through libpq's `options`: `pgsql:host=db;dbname=app;options='-c
statement_timeout=30s -c lock_timeout=5s'`.

## PHP types returned by PDO pgsql

PDO pgsql converts some types natively and returns the rest as strings. Measured on PHP 8.5.12 with
`ATTR_STRINGIFY_FETCHES` off:

| Postgres | PHP value | Handle it |
|---|---|---|
| `int2`, `int4`, `int8` | `int` (64-bit PHP) | |
| `bool` | `bool` | bind with `PDO::PARAM_BOOL`, or `false` is sent as an empty string |
| `float8` | `float` | |
| `numeric` | `string` ("19.90") | keep as string or use a decimal library; never `(float)` money |
| `json`, `jsonb` | `string` | `json_decode($v, true, flags: JSON_THROW_ON_ERROR)`; bind `json_encode(...)` |
| `date`, `timestamptz` | `string` | `new DateTimeImmutable($v)`; keep the session `TimeZone` UTC |
| `bytea` | stream resource | `stream_get_contents()`; bind with `PDO::PARAM_LOB` |
| arrays | `string` literal (`{a,b}`) | send `'{1,2,3}'` to `= ANY(?::bigint[])` instead of building `IN` lists |

The `pgsql` extension (`pg_query_params`) returns every value as a string, including integers.

## Transactions with retry in PDO

A PDO transaction is `beginTransaction()`, `commit()` and `rollBack()`. This helper retries the whole transaction on
SQLSTATE `40001` and `40P01` only, with jittered backoff.

```php
function withTx(PDO $pdo, callable $fn, int $attempts = 3): mixed {
    for ($i = 1; ; $i++) {
        $pdo->beginTransaction();
        try {
            $r = $fn($pdo);
            $pdo->commit();
            return $r;
        } catch (PDOException $e) {
            if ($pdo->inTransaction()) { $pdo->rollBack(); }
            $state = $e->errorInfo[0] ?? (string) $e->getCode();
            if (!in_array($state, ['40001', '40P01'], true) || $i >= $attempts) { throw $e; }
            usleep((2 ** $i) * 25000 + random_int(0, 50000));
        }
    }
}

withTx($pdo, function (PDO $c) {
    $c->exec('SET TRANSACTION ISOLATION LEVEL SERIALIZABLE');
    return $c->exec("UPDATE items SET price = price + 1 WHERE sku = 'A-1'");
});
```

`$e->errorInfo[0]` is the SQLSTATE (`23505` for a unique violation); `$e->errorInfo[2]` is the server message.

## COPY with Pdo\Pgsql copyFromArray and copyToArray

`Pdo\Pgsql::copyFromArray()` runs `COPY ... FROM STDIN` with one string per row; it is the fastest PHP load path.
Since PHP 8.5 the rows may be any `Traversable`, so a generator streams a large file without holding it in memory.

```php
$rows = (function () { foreach (range(1, 100000) as $i) { yield "B-$i\t$i\tt\t{}"; } })();
$pdo->copyFromArray('items', $rows, "\t", "\\\\N", 'sku, price, active, attrs');
$lines = $pdo->copyToArray('items', "\t", "\\\\N", 'sku, price');   // one string per row, ending in "\n"
```

Values containing the separator, a backslash or a newline must be escaped in COPY text format. On PHP 8.5 the old
`PDO::pgsqlCopyFromArray()` methods still work on a plain `PDO` but raise a deprecation.

## LISTEN and NOTIFY with Pdo\Pgsql getNotify

`Pdo\Pgsql::getNotify()` returns one pending notification (`message` is the channel, `pid`, `payload`) or `false`,
waiting up to the timeout in milliseconds.

```php
$pdo->exec('LISTEN jobs');
while (true) {
    $n = $pdo->getNotify(PDO::FETCH_ASSOC, 30000);   // wait up to 30 s
    if ($n === false) { continue; }                 // timeout: also a good moment to poll the table
    handleJob($n['payload']);
}
```

Run listeners as long-lived CLI workers on a direct connection, not behind a transaction-mode pooler and not inside
a web request.

## Laravel on PostgreSQL: config, pooled mode and timeouts

Laravel 13's `pgsql` connection uses `Pdo\Pgsql`. Its connector reads `sslmode`, `sslrootcert`, `search_path`,
`application_name`, `timezone`, `isolation_level`, `synchronous_commit`, `keepalives*` and `server_options` (sent as
`-c name=value` startup options).

```php
// config/database.php
'pgsql' => [
    'driver' => 'pgsql',
    'url' => env('DB_URL'),
    'host' => env('DB_HOST', '127.0.0.1'),
    'port' => env('DB_PORT', '5432'),
    'database' => env('DB_DATABASE', 'laravel'),
    'username' => env('DB_USERNAME'),
    'password' => env('DB_PASSWORD'),
    'charset' => env('DB_CHARSET', 'utf8'),
    'search_path' => 'public',
    'sslmode' => env('DB_SSLMODE', 'verify-full'),
    'application_name' => 'laravel-api',
    'server_options' => ['statement_timeout' => '30s', 'lock_timeout' => '5s'],
    'pooled' => env('DB_POOLED', false),                      // transaction-mode PgBouncer in front
    'direct' => array_filter([
        'host' => env('DB_DIRECT_HOST'),
        'port' => env('DB_DIRECT_PORT'),
    ]),
],
```

With `pooled` on, Laravel turns on emulated prepares for the pooled connection, and migrations, schema dumps,
`db:wipe`, `db:show` and `db:table` use the `direct` connection. The query builder's `->timeout()` compiles only for
MySQL; on PostgreSQL it does nothing, so rely on `statement_timeout`. Migrations, upsert, SKIP LOCKED, queues and
Octane: [references/laravel.md](references/laravel.md).

## Persistent connections, PHP-FPM and PgBouncer

`PDO::ATTR_PERSISTENT => true` keeps one connection per PHP-FPM worker alive between requests. PDO does no cleanup
on reuse: an open transaction, a `SET`, a temp table or an advisory lock from the last request is still there. Each
worker holds a server connection even when idle, so 4 servers with 50 workers each need 200 connections. Prefer
short-lived connections through PgBouncer in transaction mode (1.21 or later with `max_prepared_statements` set
keeps native prepares working); Laravel Octane workers keep their connection the same way.

## Verify PHP database code

Check the extension in the SAPI that serves requests, then read the connection from the server. `php -m`, the
quickstart and the SQL ran on PHP 8.5.12 (`php:8.5-cli` image) against PostgreSQL 18.6; the two `artisan` commands are
from the Laravel docs and were not run.

```bash
php -m | grep -i pgsql                  # pdo_pgsql and pgsql, for CLI; repeat through a phpinfo page for FPM
php quick.php                           # prints Pdo\Pgsql and one row
php artisan db:show                     # Laravel: connection, version, tables
php artisan migrate --pretend           # the SQL a migration would run, nothing changed
```

```sql
SELECT application_name, state, count(*) FROM pg_stat_activity
WHERE application_name IN ('quick', 'laravel-api') GROUP BY 1, 2;     -- connections held per worker
```

Behind PgBouncer, run a page twice and check the log for `prepared statement ... does not exist`.

## Gotchas

The PHP and Postgres failures seen most often, each with its cause and fix.

1. **`could not find driver`.** `pdo_pgsql` is not loaded in this SAPI (CLI and FPM read different `php.ini`
   files). Check `php --ini` and `php -m`, then enable the extension for both.
2. **`prepared statement "pdo_stmt_00000001" does not exist` behind PgBouncer.** Transaction pooling without
   prepared statement tracking. Upgrade PgBouncer to 1.21+ with `max_prepared_statements` above 0, or set
   `PDO::ATTR_EMULATE_PREPARES => true` (Laravel: `'pooled' => true`).
3. **A worker uses gigabytes on one big `SELECT` but `memory_limit` never trips.** libpq buffers the whole result
   outside PHP's memory accounting (`Pdo\Pgsql::ATTR_RESULT_MEMORY_SIZE` showed 411 MB for 200,000 rows of 1 KB).
   Use `PDO::ATTR_PREFETCH => 0` on PHP 8.5, a server-side cursor, or keyset pages.
4. **Booleans insert as errors or wrong values.** `false` bound as a string becomes `''`. Bind with
   `PDO::PARAM_BOOL`.
5. **A Laravel upsert fails with `42P10 there is no unique or exclusion constraint matching the ON CONFLICT`.**
   `uniqueBy` names columns with no plain unique index, often a partial one. Write the `ON CONFLICT (...) WHERE ...`
   statement with `DB::affectingStatement()`.
6. **A parameter arrives as NULL with no error.** The SQL used `$1` (copied from psql or the `pgsql` extension);
   PDO binds only `?` and `:name`. Rewrite the placeholders.
7. **`CREATE INDEX CONCURRENTLY cannot run inside a transaction block` (25001).** A Laravel migration with
   `->online()` still runs in a transaction. Add `public $withinTransaction = false;` to that migration.

## Anti-patterns in PHP database code

Each of these hides a failure until production traffic finds it.

| Do not | Do instead |
|---|---|
| Turn on `PDO::ATTR_PERSISTENT` to go faster | Use short connections through PgBouncer; persistent ones keep the last request's state |
| Cast `numeric` to `float` | Keep the string or use a decimal library |
| Build `IN (...)` lists by hand | Send `'{1,2,3}'` to `= ANY(?::bigint[])` |
| Load a big table with `fetchAll()` | Use `ATTR_PREFETCH => 0`, a cursor or keyset pages |
| Rely on Laravel's `->timeout()` on Postgres | Set `statement_timeout` in `server_options` |
| Run `LISTEN` inside a web request | Run a long-lived CLI worker on a direct connection |

## Checklist

Check these points before you call PHP database code done.

- [ ] `pdo_pgsql` loaded in CLI and FPM; connection made with `PDO::connect()` on PHP 8.4+.
- [ ] Exceptions on, native prepares on (or emulated only behind an old pooler), every value bound.
- [ ] `numeric` kept as string; `bool` bound with `PARAM_BOOL`; JSON encoded and decoded with exceptions.
- [ ] Transactions retry on `40001` and `40P01` only; SQLSTATE read from `errorInfo[0]`.
- [ ] `statement_timeout` and `lock_timeout` set through `options` or Laravel `server_options`.
- [ ] Large results streamed (`ATTR_PREFETCH => 0`, cursor or keyset), bulk loads through `copyFromArray`.
- [ ] Persistent connections only with a plan for connection count and leftover session state.

## See also

Related skills in this library, each one works on its own:

- `postgres-app-drivers`: the cross-language chooser.
- `postgres-connection-pooling`: pool sizing and PgBouncer modes.
- `postgres-schema-migrations`: lock-safe DDL.
- `postgres-queues-jobs`: queue design with `SKIP LOCKED`.
- `postgres-transactions-locking`: retries and isolation.

## Sources

- https://www.php.net/manual/en/ref.pdo-pgsql.php and https://www.php.net/manual/en/class.pdo-pgsql.php
- https://www.php.net/manual/en/pdo-pgsql.copyfromarray.php, /pdo-pgsql.getnotify.php, /pdo.connections.php
- https://www.php.net/releases/ (8.5.12, 8.4.27) and https://github.com/php/php-src/blob/PHP-8.5/php.ini-development
- https://laravel.com/docs/13.x/database (Pooled PostgreSQL Connections), /migrations, /queues
- https://github.com/laravel/framework (13.39.0: PostgresConnector, PostgresGrammar, DatabaseQueue)
- https://formulae.brew.sh/formula/php and https://packages.debian.org/trixie/php8.4-pgsql
- https://www.postgresql.org/docs/18/sql-copy.html and https://www.postgresql.org/docs/18/sql-notify.html
