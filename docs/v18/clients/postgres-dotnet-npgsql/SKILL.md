---
name: postgres-dotnet-npgsql
description: 'Builds .NET and C# applications on PostgreSQL in depth: a runnable Npgsql quickstart, NpgsqlDataSource and connection string keywords with their defaults, multiplexing, binary COPY import and export, NpgsqlBatch, LISTEN with WaitAsync, type mapping (DateTime UTC rules, DateOnly in Npgsql 10, NodaTime, jsonb POCOs, arrays), PostgresException SqlState retries, EF Core 10 with the Npgsql provider (migrations, ToJson complex types, arrays, full-text search, ExecuteUpdate and ExecuteDelete, xmin concurrency, retry strategy), Dapper, ASP.NET Core dependency injection and NativeAOT. Use when writing Postgres code in C#, F# or ASP.NET, "Cannot write DateTime with Kind=Local", EF Core migrations or bulk inserts, or picking Npgsql settings.'
metadata:
  tags:
  - postgres
  - dotnet
  - csharp
  - npgsql
  - ef-core
  - dapper
  - aspnet-core
  - nativeaot
---

# PostgreSQL from .NET with Npgsql and EF Core

Every .NET path to PostgreSQL runs on Npgsql: plain ADO.NET, Dapper, and EF Core through
`Npgsql.EntityFrameworkCore.PostgreSQL`. Create one `NpgsqlDataSource` per application (it owns the pool and the type
mappings), use EF Core for entity CRUD and migrations, and drop to Npgsql or Dapper for bulk work and hand-tuned SQL.
The cross-language choice and shared rules are in `postgres-app-drivers`. Detail:
[EF Core 10 with Npgsql](references/efcore.md).

## Step 0: read the .NET and Npgsql versions in the project

Npgsql 10 changed the default `date` mapping and EF Core majors track .NET majors, so read what the project pins.

```bash
dotnet --version
dotnet list package --include-transitive 2>/dev/null | grep -Ei 'npgsql|entityframework|dapper'
dotnet tool list --global | grep -i dotnet-ef
```

## Choose Npgsql, Dapper or EF Core

All three run on Npgsql, so one application can use them side by side.

| Layer | Wins when | Loses when |
|---|---|---|
| `NpgsqlDataSource` | bulk `COPY`, `LISTEN`, batches, hot paths | you map many rows to objects by hand |
| Dapper | hand-written SQL mapped to records | you want tracked entities and migrations |
| EF Core | entity CRUD and migrations | bulk loads; use binary COPY beside it |

## Quickstart: connect, query and close with Npgsql

This quickstart creates a console app on .NET 10, adds Npgsql 10.0.3, and runs one parameterized query. Npgsql takes
a keyword connection string (`Host=...;Database=...`), not a `postgres://` URL.

```bash
dotnet new console -o PgQuickstart
cd PgQuickstart
dotnet add package Npgsql --version 10.0.3
```

Replace `Program.cs` with the program below: it builds a data source, binds a positional parameter, reads
`timestamptz` as a UTC `DateTime`, and disposes everything at the end.

```csharp
using Npgsql;

var connString = Environment.GetEnvironmentVariable("PG_CONNECTION_STRING")
    ?? throw new InvalidOperationException("Set PG_CONNECTION_STRING");

await using var dataSource = NpgsqlDataSource.Create(connString);
await using var cmd = dataSource.CreateCommand("SELECT now(), current_setting($1)");
cmd.Parameters.AddWithValue("server_version");

await using var reader = await cmd.ExecuteReaderAsync();
await reader.ReadAsync();
DateTime now = reader.GetDateTime(0);   // timestamptz -> DateTime with Kind=Utc
Console.WriteLine($"{now:O} {now.Kind} {reader.GetString(1)}");
```

Run `dotnet run` with `PG_CONNECTION_STRING="Host=localhost;Database=app;Username=app;Password=secret;SSL Mode=VerifyFull"`
(PowerShell: `$env:PG_CONNECTION_STRING="..."`). Versions in October 2026: .NET SDK 10.0.403, Npgsql 10.0.3,
Npgsql.EntityFrameworkCore.PostgreSQL 10.0.3 with EF Core 10.0.14 (11.0 is in release candidate), Dapper 2.1.89.

## NpgsqlDataSource and connection string keywords

An `NpgsqlDataSource` holds the connection pool, the connection string and the type mappings; build it once with
`NpgsqlDataSourceBuilder` and share it. Several Npgsql defaults differ from other drivers.

| Keyword | Default | Advice |
|---|---|---|
| `Maximum Pool Size` | 100 | lower it: 100 per instance exhausts most servers (`postgres-connection-pooling`) |
| `Minimum Pool Size` | 0 | keep |
| `Connection Idle Lifetime` | 300 s | keep; lower behind a pooler |
| `Connection Lifetime` | 3600 s since 9.0 | keep, so failover and load balancers rotate connections |
| `Timeout` (connect) | 15 s | 5 s |
| `Command Timeout` | 30 s | per command for long reports; 0 means none |
| `SSL Mode` | `Prefer`, no certificate check | `VerifyFull` off localhost; `Require` does not verify the server |
| `Max Auto Prepare` | 0, off | 20 to 50 to prepare hot statements without code changes |
| `Application Name` | none | the service name |
| `Multiplexing` | false | true for many short commands; see below |
| `No Reset On Close` | false | true when Npgsql pooling runs behind PgBouncer transaction mode |

The SQL Server spelling `Max Pool Size` is refused (`Couldn't set max pool size`); Npgsql uses `Maximum Pool Size`
or the builder property `MaxPoolSize`.

```csharp
var builder = new NpgsqlDataSourceBuilder(connString);
builder.ConnectionStringBuilder.MaxPoolSize = 20;
builder.ConnectionStringBuilder.ApplicationName = "orders-api";
builder.ConnectionStringBuilder.MaxAutoPrepare = 50;
builder.EnableDynamicJson();          // POCO <-> jsonb through System.Text.Json
await using var dataSource = builder.Build();
```

## Npgsql multiplexing

Npgsql multiplexing (`Multiplexing=true`, off by default, marked experimental since it arrived in 5.0) sends commands
from many callers over a few shared physical connections instead of giving each caller its own. 200 concurrent
commands ran through `Maximum Pool Size=4` on 18.6. Session-bound features do not work in this mode:
`NpgsqlConnection.Wait` throws `NotSupportedException`, so `LISTEN` needs a data source without multiplexing.
Transactions still get a dedicated connection.

## Fastest bulk insert from .NET: binary COPY with BeginBinaryImportAsync

The fastest way to insert many rows (thousands to millions) from a .NET app is Npgsql binary COPY:
`BeginBinaryImportAsync` to import, `BeginBinaryExportAsync` to export. Npgsql binary COPY is the fastest way to move
rows in or out, far ahead of one `INSERT` per row. Write each value with an explicit `NpgsqlDbType`, and
call `CompleteAsync()`: disposing the importer without it cancels the whole COPY.

```csharp
await using (var conn = await dataSource.OpenConnectionAsync())
await using (var importer = await conn.BeginBinaryImportAsync(
    "COPY orders (customer, total) FROM STDIN (FORMAT BINARY)"))
{
    foreach (var o in orders)
    {
        await importer.StartRowAsync();
        await importer.WriteAsync(o.Customer, NpgsqlDbType.Text);
        await importer.WriteAsync(o.Total, NpgsqlDbType.Numeric);
    }
    ulong rows = await importer.CompleteAsync();
}

await using (var conn = await dataSource.OpenConnectionAsync())
await using (var exporter = await conn.BeginBinaryExportAsync(
    "COPY (SELECT id, total FROM orders) TO STDOUT (FORMAT BINARY)"))
{
    while (await exporter.StartRowAsync() != -1)
        Console.WriteLine($"{exporter.Read<long>(NpgsqlDbType.Bigint)} {exporter.Read<decimal>(NpgsqlDbType.Numeric)}");
}
```

A wrong type in binary COPY can fail or, worse, store garbage; test the column list. For text formats use
`BeginTextImportAsync` and `BeginTextExportAsync`.

## NpgsqlBatch for several statements in one round trip

`NpgsqlBatch` sends several statements in one network round trip and returns their results in order through one
reader.

```csharp
await using var batch = dataSource.CreateBatch();
batch.BatchCommands.Add(new NpgsqlBatchCommand("UPDATE orders SET attrs = $1 WHERE id = $2")
    { Parameters = { new() { Value = new Attrs("pro", ["a"]), NpgsqlDbType = NpgsqlDbType.Jsonb }, new() { Value = 1L } } });
batch.BatchCommands.Add(new NpgsqlBatchCommand("SELECT attrs FROM orders WHERE id = 1"));
await using var reader = await batch.ExecuteReaderAsync();
```

Without an explicit transaction the batch runs in one implicit transaction: a failing statement rolls back the
statements before it.

## Type mapping: DateTime, DateOnly, NodaTime, JSON and arrays

Npgsql's type mapping has strict rules for time and opt-ins for JSON.

| PostgreSQL | .NET (Npgsql 10) | Rule |
|---|---|---|
| `timestamptz` | `DateTime` with `Kind=Utc`, `DateTimeOffset` with offset 0 | writing `Kind=Local` or `Unspecified` throws |
| `timestamp` | `DateTime` with `Kind=Unspecified` | not for instants |
| `date` / `time` | `DateOnly` / `TimeOnly` (new default in 10.0) | `GetValue` returns `DateOnly`; `GetFieldValue<DateTime>` still works |
| `numeric` | `decimal` | beyond `decimal` range `GetDecimal` throws `OverflowException`: read whole numbers as `BigInteger`, anything else as `text` with `::text` |
| `jsonb` | `string`, `JsonDocument`; POCOs after `EnableDynamicJson()` | POCO mapping is not NativeAOT-compatible |
| arrays | `T[]`, `List<T>` | bind to `= ANY($1)` |
| `uuid` | `Guid` | |

The `Npgsql.NodaTime` plugin (`builder.UseNodaTime()`) maps `timestamptz` to `Instant`, `date` to `LocalDate` and
`interval` to `Period`, which avoids `DateTime.Kind` mistakes entirely.

## DateTime.Now into a timestamptz column fails: only UTC is supported

Saving `DateTime.Now` into a `timestamptz` column with Npgsql throws `Cannot write DateTime with Kind=Local to
PostgreSQL type 'timestamp with time zone', only UTC is supported`. `DateTime.Now` has `Kind=Local`, and Npgsql writes
only `Kind=Utc` values to `timestamptz` (`Unspecified` throws too). Send `DateTime.UtcNow`, convert with
`ToUniversalTime()`, use `DateTimeOffset` with offset 0, or NodaTime `Instant`.

```csharp
await using var cmd = dataSource.CreateCommand("INSERT INTO events (created_at, due_at) VALUES ($1, $2)");
cmd.Parameters.AddWithValue(DateTime.UtcNow);              // Kind=Utc: accepted
cmd.Parameters.AddWithValue(localDue.ToUniversalTime());   // a Local value converted first
await cmd.ExecuteNonQueryAsync();
```

## LISTEN with WaitAsync

Npgsql raises the `Notification` event on the connection that ran `LISTEN`, but only while it is reading;
`WaitAsync` blocks until one arrives. Hold a dedicated connection from a non-multiplexing data source.

```csharp
await using var listener = await dataSource.OpenConnectionAsync();
listener.Notification += (_, e) => Handle(e.Channel, e.Payload);
await using (var cmd = new NpgsqlCommand("LISTEN order_paid", listener))
    await cmd.ExecuteNonQueryAsync();
while (!stoppingToken.IsCancellationRequested)
    await listener.WaitAsync(stoppingToken);
```

In ASP.NET Core, run this loop in a `BackgroundService` and reconnect with backoff when it throws.

## PostgresException, retries and timeouts

Server errors arrive as `PostgresException` with `SqlState`, `ConstraintName`, `TableName` and `Detail` (detail text
needs `Include Error Detail=true`, which may expose data in logs). `PostgresErrorCodes` names the codes.

```csharp
static async Task<T> InTx<T>(NpgsqlDataSource ds, Func<NpgsqlConnection, NpgsqlTransaction, Task<T>> work)
{
    for (var attempt = 1; ; attempt++)
    {
        await using var conn = await ds.OpenConnectionAsync();
        await using var tx = await conn.BeginTransactionAsync(IsolationLevel.Serializable);
        try
        {
            var result = await work(conn, tx);
            await tx.CommitAsync();
            return result;
        }
        catch (PostgresException e) when (e.SqlState is PostgresErrorCodes.SerializationFailure
                                          or PostgresErrorCodes.DeadlockDetected && attempt < 4)
        {
            // no RollbackAsync here: after a failed COMMIT it throws; await using rolls back
            await Task.Delay(attempt * attempt * 20 + Random.Shared.Next(30));
        }
    }
}
```

When `Command Timeout` passes, Npgsql sends a cancellation request and throws `NpgsqlException` whose
`InnerException` is a `TimeoutException`. Pass a `CancellationToken` to every async call as well.

## Dapper on Npgsql

Dapper maps rows to records over any `NpgsqlConnection` from the data source. Its `@name` parameters work with Npgsql,
and arrays bind to `= ANY(@ids)` without expanding into an `IN` list.

```csharp
await using var conn = await dataSource.OpenConnectionAsync();
var rows = await conn.QueryAsync<OrderRow>(
    "SELECT id, customer, total FROM orders WHERE customer = @customer ORDER BY id LIMIT 50", new { customer });
var n = await conn.ExecuteScalarAsync<long>("SELECT count(*) FROM orders WHERE id = ANY(@ids)", new { ids });
```

## ASP.NET Core dependency injection

`Npgsql.DependencyInjection` registers the data source as a singleton and `NpgsqlConnection` as transient. EF Core 9 and
later configure Npgsql through `UseNpgsql(..., o => ...)`, which builds its own data source.

```csharp
builder.Services.AddNpgsqlDataSource(builder.Configuration.GetConnectionString("Shop")!,
    b => b.EnableDynamicJson());
builder.Services.AddDbContextPool<ShopContext>(o =>
    o.UseNpgsql(builder.Configuration.GetConnectionString("Shop"), n => n.EnableRetryOnFailure()));
```

Inject `NpgsqlDataSource` into singletons and background services, never a long-lived `NpgsqlConnection`.

## EF Core 10 with the Npgsql provider

EF Core on PostgreSQL maps arrays, `jsonb` complex types with `ToJson()`, generated `tsvector` columns, `xmin`
concurrency tokens and set-based `ExecuteUpdate`/`ExecuteDelete`. Migrations, the model and the traps are in
[EF Core 10 with Npgsql](references/efcore.md). Two rules matter most: apply migrations from a deploy step
(`dotnet ef migrations script --idempotent` or a bundle), and with `EnableRetryOnFailure()` wrap any explicit
transaction in `db.Database.CreateExecutionStrategy().ExecuteAsync(...)`.

## NativeAOT and trimming

Npgsql has supported NativeAOT and trimming since 8.0. `NpgsqlSlimDataSourceBuilder` starts with the minimum and
needs opt-ins (`EnableArrays()`, `EnableRanges()`, `EnableJsonTypes()`); a sample using arrays published to a 6 MB
native binary on linux-arm64. JSON POCO mapping (`EnableDynamicJson`) is not AOT-compatible; use `JsonDocument` or
source-generated `System.Text.Json` contexts.

## Gotchas

These are the .NET failures seen most often, each with its symptom, cause and fix.

1. **`Cannot write DateTime with Kind=Local to PostgreSQL type 'timestamp with time zone', only UTC is supported`.**
   Convert with `ToUniversalTime()`, or use `DateTimeOffset` with offset 0, or NodaTime `Instant`.
2. **`(DateTime)reader["day"]` throws `InvalidCastException` after upgrading to Npgsql 10.** `GetValue` now returns
   `DateOnly` for `date`. Use `DateOnly`, or ask explicitly with `GetFieldValue<DateTime>`.
3. **`The configured execution strategy 'NpgsqlRetryingExecutionStrategy' does not support user-initiated
   transactions`.** Run the transaction inside `CreateExecutionStrategy().ExecuteAsync`.
4. **`too many clients already` after scaling out.** Default `Maximum Pool Size` is 100 per instance. Lower it.
5. **A binary COPY "succeeds" but no rows appear.** `CompleteAsync()` was not called. Call it before disposing.
6. **`Wait isn't supported in multiplexing mode`.** Use a second data source without multiplexing for `LISTEN`.
7. **`dotnet ef` fails with `Could not load file or assembly '.../ef.dll'`.** The project's assembly is named `Ef`,
   which collides with the tool's `ef.dll`. Rename the project.

## Verify .NET database code against a real server

Run the application's tests against a real PostgreSQL with these checks, because type mapping and pool limits only
show up there.

```bash
dotnet build -warnaserror && dotnet test
dotnet ef migrations has-pending-model-changes        # fails when the model moved without a migration
dotnet ef migrations script --idempotent -o migrate.sql   # review this file
```

Add one test each that writes `DateTime.UtcNow` to `timestamptz`, reads a `date` as `DateOnly`, and runs a binary COPY
and counts the rows. Under load, `SELECT application_name, count(*) FROM pg_stat_activity GROUP BY 1` must stay at or
below `Maximum Pool Size`.

## Checklist

Check these points before calling .NET database code done.

- [ ] One `NpgsqlDataSource` (or `AddNpgsqlDataSource`) per application; `Maximum Pool Size` set on purpose.
- [ ] `SSL Mode=VerifyFull` off localhost; secrets from configuration providers, not `appsettings.json` in git.
- [ ] Every `DateTime` sent to `timestamptz` is UTC; `date` read as `DateOnly`.
- [ ] Bulk loads use binary COPY with explicit `NpgsqlDbType` and `CompleteAsync()`.
- [ ] Serializable work retries `40001` and `40P01`; EF transactions run inside the execution strategy.
- [ ] EF migrations reviewed as SQL and applied by a deploy step, not by every instance at startup.
- [ ] `LISTEN` runs on a dedicated connection in a `BackgroundService`.

## Anti-patterns in .NET database code

| Do not | Do this instead |
|---|---|
| create an `NpgsqlDataSource` per request | one per application, as a singleton |
| keep a long-lived `NpgsqlConnection` in a service | open from the data source when needed |
| write `DateTime.Now` to `timestamptz` | `DateTime.UtcNow`, or `DateTimeOffset` with offset 0 |
| migrate at startup from every instance | a deploy step with a bundle or an idempotent script |
| leave `Maximum Pool Size` at 100 when scaling out | budget it across instances |
| insert rows one at a time in a loop | binary COPY |

## See also

- `postgres-app-drivers`: the rules shared by every language.
- `postgres-connection-pooling`: pool budget and PgBouncer.
- `postgres-transactions-locking`: what to retry and why.
- `postgres-sql-dates-times`: `timestamptz` and time zones.
- `postgres-schema-migrations`: safe DDL behind EF Core migrations.

## Sources

- https://www.npgsql.org/doc/connection-string-parameters.html, /basic-usage.html, /copy.html, /wait.html, /performance.html, /prepare.html, /security.html, /compatibility.html
- https://www.npgsql.org/doc/types/datetime.html, /types/json.html, /types/nodatime.html, /release-notes/10.0.html, /release-notes/8.0.html
- https://github.com/npgsql/npgsql/blob/v10.0.3/src/Npgsql/NpgsqlConnectionStringBuilder.cs (Multiplexing keyword)
- https://www.npgsql.org/efcore/index.html, /efcore/mapping/json.html, /efcore/mapping/array.html, /efcore/mapping/full-text-search.html, /efcore/release-notes/10.0.html
- https://learn.microsoft.com/ef/core/managing-schemas/migrations/applying
- NuGet and dotnetcli release metadata for every package and SDK named, read 2026-10-28
