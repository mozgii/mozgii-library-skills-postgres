---
title: EF Core 10 with the Npgsql provider on PostgreSQL
author: MOZGII, Inc.
lang: en
---

# EF Core 10 with the Npgsql provider on PostgreSQL

This reference is a working EF Core 10 model on PostgreSQL with migrations, `jsonb`, arrays, full-text search,
set-based updates, optimistic concurrency, retries and bulk inserts. It ran on .NET 10 against PostgreSQL 18.6 with
Npgsql.EntityFrameworkCore.PostgreSQL 10.0.3, EF Core 10.0.14 and dotnet-ef 10.0.14.

## Contents

The sections of this reference on EF Core with Npgsql:

1. Project file and the dotnet-ef tool
2. A model with identity, jsonb, arrays, tsvector and xmin
3. Migrations: add, review and apply
4. Queries on arrays, JSON and full-text columns
5. ExecuteUpdate and ExecuteDelete
6. Optimistic concurrency with xmin
7. Retry strategy and explicit transactions
8. Bulk inserts from an EF Core application

## Project file and the dotnet-ef tool

An EF Core project on PostgreSQL references the Npgsql provider and, for migrations, the design package. Install
`dotnet-ef` as a local tool so every developer and CI job uses the same version.

```bash
dotnet add package Npgsql.EntityFrameworkCore.PostgreSQL --version 10.0.3
dotnet add package Microsoft.EntityFrameworkCore.Design --version 10.0.14
dotnet new tool-manifest
dotnet tool install dotnet-ef --version 10.0.14
dotnet build                      # dotnet ef needs a restored, buildable project
```

Do not name the project or assembly `Ef`: it collides with the tool's own `ef.dll` and every `dotnet ef` command fails
with `Could not load file or assembly`.

## A model with identity, jsonb, arrays, tsvector and xmin

This EF Core model uses an identity key, a `numeric(12,2)` price, a `text[]` array with a GIN index, a complex type
stored as `jsonb` with `ToJson()`, a generated `tsvector` column with a GIN index, and `xmin` as concurrency token.

```csharp
public class Product
{
    public long Id { get; set; }
    public required string Name { get; set; }
    public required string Description { get; set; }
    public decimal Price { get; set; }
    public string[] Tags { get; set; } = [];
    public required ProductDetails Details { get; set; }
    public NpgsqlTsVector SearchVector { get; set; } = null!;
    public DateTime CreatedAt { get; set; }
    public uint Version { get; set; }
}

public class ProductDetails
{
    public required string Brand { get; set; }
    public int WeightGrams { get; set; }
}

public class ShopContext(DbContextOptions<ShopContext> options) : DbContext(options)
{
    public DbSet<Product> Products => Set<Product>();

    protected override void OnModelCreating(ModelBuilder b)
    {
        b.Entity<Product>(e =>
        {
            e.Property(p => p.Id).UseIdentityAlwaysColumn();
            e.Property(p => p.Price).HasPrecision(12, 2);
            e.Property(p => p.CreatedAt).HasDefaultValueSql("now()");
            e.ComplexProperty(p => p.Details, d => d.ToJson());
            e.HasGeneratedTsVectorColumn(p => p.SearchVector, "english", p => new { p.Name, p.Description })
             .HasIndex(p => p.SearchVector).HasMethod("GIN");
            e.HasIndex(p => p.Tags).HasMethod("GIN");
            e.Property(p => p.Version).IsRowVersion();     // maps to the xmin system column
        });
    }
}
```

## Migrations: add, review and apply

EF Core migrations are C# files; review the SQL they produce before it reaches production. An idempotent script can
run in any environment and skips migrations already applied.

```bash
dotnet ef migrations add Init
dotnet ef migrations script --idempotent -o migrate.sql   # review this file, then apply it with psql in CI
dotnet ef migrations bundle                               # or ship a self-contained migrator executable
```

The `Init` migration above produced, among others:

```sql
"Id" bigint GENERATED ALWAYS AS IDENTITY,
"SearchVector" tsvector GENERATED ALWAYS AS (to_tsvector('english', "Name" || ' ' || "Description")) STORED NOT NULL,
"Details" jsonb NOT NULL,
CREATE INDEX "IX_Products_SearchVector" ON "Products" USING GIN ("SearchVector");
CREATE INDEX "IX_Products_Tags" ON "Products" USING GIN ("Tags");
```

- Generated indexes are plain `CREATE INDEX`, which locks writes on a big table. Write those migrations by hand with
  `migrationBuilder.Sql("CREATE INDEX CONCURRENTLY ...", suppressTransaction: true)` (`postgres-schema-migrations`).
- `Database.MigrateAsync()` at startup is fine for a single-instance app or a test; for several replicas apply the
  script or bundle once from the deploy pipeline.
- EF names tables and columns in PascalCase and quotes them; plain SQL against them needs the quotes too.

## Queries on arrays, JSON and full-text columns

The Npgsql provider translates array, JSON and full-text expressions to PostgreSQL operators.

```csharp
var steel = await db.Products
    .Where(p => p.SearchVector.Matches(EF.Functions.WebSearchToTsQuery("english", "steel widgets")))
    .CountAsync();
var onSale = await db.Products.CountAsync(p => p.Tags.Contains("sale"));
var acme = await db.Products
    .Where(p => p.Details.Brand == "Acme" && p.Details.WeightGrams > 150)
    .Select(p => p.Name).ToListAsync();
```

In EF 10, `Tags.Contains(x)` translates to `x = ANY("Tags")` unless a GIN index on the column is in the model; with
the GIN index above it became `"Tags" @> ARRAY['sale']::text[]`, which can use the index. `ToQueryString()` shows the
SQL for any query.

## ExecuteUpdate and ExecuteDelete

`ExecuteUpdateAsync` and `ExecuteDeleteAsync` run one set-based `UPDATE` or `DELETE` in the database without loading
entities, and return the row count. They bypass the change tracker, so tracked entities in the same context keep old
values.

```csharp
var updated = await db.Products.Where(p => p.Tags.Contains("sale"))
    .ExecuteUpdateAsync(s => s.SetProperty(p => p.Price, p => p.Price * 0.9m));
var deleted = await db.Products.Where(p => p.Price > 100m).ExecuteDeleteAsync();
```

## Optimistic concurrency with xmin

A `uint` property marked `IsRowVersion()` maps to PostgreSQL's `xmin` system column, which changes on every update;
no extra column is created. EF adds `xmin` to the `WHERE` of updates and throws `DbUpdateConcurrencyException` when
another session changed the row first: reload and retry, or report the conflict.

```csharp
var a = await db1.Products.OrderBy(p => p.Id).FirstAsync();
var b = await db2.Products.OrderBy(p => p.Id).FirstAsync();
a.Price += 1; await db1.SaveChangesAsync();
b.Price += 2;
try { await db2.SaveChangesAsync(); }
catch (DbUpdateConcurrencyException) { /* conflict: the row changed since it was read */ }
```

## Retry strategy and explicit transactions

`UseNpgsql(cs, o => o.EnableRetryOnFailure())` retries transient failures, but refuses explicit transactions opened
outside it with `The configured execution strategy 'NpgsqlRetryingExecutionStrategy' does not support
user-initiated transactions`. Run the whole unit of work inside the strategy so a retry repeats all of it:

```csharp
var strategy = db.Database.CreateExecutionStrategy();
var count = await strategy.ExecuteAsync(async () =>
{
    await using var tx = await db.Database.BeginTransactionAsync(IsolationLevel.Serializable);
    var c = await db.Products.CountAsync();
    await tx.CommitAsync();
    return c;
});
```

## Bulk inserts from an EF Core application

EF Core batches `SaveChanges` inserts, but for tens of thousands of rows binary COPY on the context's own connection
is much faster and needs no extra package. JSON columns take their JSON text with `NpgsqlDbType.Jsonb`.

```csharp
var conn = (NpgsqlConnection)db.Database.GetDbConnection();
await conn.OpenAsync();
await using var w = await conn.BeginBinaryImportAsync(
    "COPY \"Products\" (\"Name\", \"Description\", \"Price\", \"Tags\", \"Details\") FROM STDIN (FORMAT BINARY)");
foreach (var p in products)
{
    await w.StartRowAsync();
    await w.WriteAsync(p.Name, NpgsqlDbType.Text);
    await w.WriteAsync(p.Description, NpgsqlDbType.Text);
    await w.WriteAsync(p.Price, NpgsqlDbType.Numeric);
    await w.WriteAsync(p.Tags, NpgsqlDbType.Array | NpgsqlDbType.Text);
    await w.WriteAsync(JsonSerializer.Serialize(p.Details), NpgsqlDbType.Jsonb);
}
await w.CompleteAsync();
```

Generated columns (`SearchVector`) and identity keys are filled by the database, so leave them out of the column list.
