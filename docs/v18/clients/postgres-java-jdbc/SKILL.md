---
name: postgres-java-jdbc
description: 'Builds Java and Kotlin services on PostgreSQL in depth: a runnable PgJDBC quickstart, URL parameters (prepareThreshold, reWriteBatchedInserts, binaryTransfer, sslmode, stringtype), HikariCP sizing and defaults, COPY through CopyManager, LISTEN with getNotifications, streaming with fetch size, java.time mapping, Spring Boot 4 DataSource, JdbcClient and transactions, Spring Data JPA and Hibernate 7 on Postgres (sequence allocation, batch inserts, jsonb with @JdbcTypeCode), Flyway and Liquibase migrations, virtual threads with a pool, and jOOQ and R2DBC notes. Use when writing Postgres code in Java, Kotlin or Spring, Hibernate inserts are slow, "The increment size of the [x_seq] sequence" errors, a Flyway migration hangs, or sizing HikariCP.'
metadata:
  tags:
  - postgres
  - java
  - jdbc
  - pgjdbc
  - hikaricp
  - spring-boot
  - hibernate
  - flyway
  - liquibase
---

# PostgreSQL from Java with PgJDBC, HikariCP and Spring

Every Java path to PostgreSQL goes through PgJDBC (`org.postgresql:postgresql`) and, in a server, through HikariCP.
Use Spring's `JdbcClient` for SQL-first code, Spring Data JPA with Hibernate for entity-heavy CRUD, jOOQ when the
team wants typed SQL. Most production problems are URL parameters left at defaults, pools sized by guess, and
Hibernate settings that silently turn off batching. The choice across languages and the shared rules are in
`postgres-app-drivers`. Detail: [Spring Boot, Hibernate and migrations](references/spring-hibernate.md).

## Step 0: read the JDK, driver and framework versions

Spring Boot manages its own versions of Hibernate, HikariCP and Flyway, so the jar on the classpath is often not the
newest release. Read what the build resolves before you rely on an API.

```bash
java -version
mvn dependency:tree -Dincludes=org.postgresql,com.zaxxer,org.hibernate.orm,org.flywaydb,org.liquibase
./gradlew dependencies --configuration runtimeClasspath | grep -E 'postgresql|HikariCP|hibernate-core|flyway|liquibase'
psql -X -Atc 'SHOW server_version'
```

## Choosing JdbcClient, JPA, jOOQ or R2DBC

Pick the data access layer by what the code does most. All of them run on PgJDBC except R2DBC.

| Code does most | Use | Why the others lose here |
|---|---|---|
| Hand-written SQL, reports, bulk work | `JdbcClient` | JPA hides the SQL and costs a mapping per query |
| Entity-heavy CRUD with relations | Spring Data JPA on Hibernate | hand-written SQL repeats the mapping for every table |
| Complex SQL that must stay typed | jOOQ | string SQL breaks at run time when a column changes |
| A reactive WebFlux stack | R2DBC | blocking JDBC ties up event-loop threads; with virtual threads, stay on JDBC |

## Quickstart: connect, query and close with PgJDBC

This quickstart needs only a JDK (17 or later; 25 is the current LTS and 27 the latest release) and the driver jar:
Java runs a single source file directly. In a build, add `org.postgresql:postgresql:42.7.14` (Maven) or
`implementation("org.postgresql:postgresql:42.7.14")` (Gradle).

```bash
mkdir pgjdbc-quickstart && cd pgjdbc-quickstart
curl -fLO https://repo1.maven.org/maven2/org/postgresql/postgresql/42.7.14/postgresql-42.7.14.jar
```

The program opens one connection with try-with-resources, binds a parameter, reads `timestamptz` as
`OffsetDateTime`, and closes everything on exit.

```java
// Main.java
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.time.OffsetDateTime;

public class Main {
    public static void main(String[] args) throws Exception {
        String url = System.getenv("JDBC_URL");          // jdbc:postgresql://localhost:5432/app?sslmode=verify-full
        String user = System.getenv("DB_USER");
        String password = System.getenv("DB_PASSWORD");
        try (Connection conn = DriverManager.getConnection(url, user, password);
             PreparedStatement ps = conn.prepareStatement("SELECT now(), current_setting(?)")) {
            ps.setString(1, "server_version");
            try (ResultSet rs = ps.executeQuery()) {
                rs.next();
                OffsetDateTime now = rs.getObject(1, OffsetDateTime.class);
                System.out.println(now + " " + rs.getString(2));
            }
        }
    }
}
```

Run it with `java -cp postgresql-42.7.14.jar Main.java` (on Windows, `;` separates several classpath jars). Versions in October 2026: PgJDBC 42.7.14, HikariCP 7.1.0 (Spring Boot
4.1.2 manages 7.0.2), Spring Boot 4.1.2, Hibernate ORM 7.4.14 (Boot manages 7.4.13), Flyway 13.12.0 (Boot manages
12.4.0), Liquibase 5.0.4, jOOQ 3.21.9, r2dbc-postgresql 1.1.3.

## PgJDBC URL parameters that matter

PgJDBC connection parameters go in the JDBC URL or as data source properties. These are the ones to decide on.

| Parameter | Default | Set it when |
|---|---|---|
| `sslmode` | `prefer` (falls back to plain text) | always `verify-full` off localhost; `require` and `prefer` do not check the certificate |
| `prepareThreshold` | 5 executions before a server-side prepare | 0 behind a pooler without prepared statement support |
| `reWriteBatchedInserts` | false | true: `executeBatch()` of one INSERT becomes multi-row INSERTs |
| `binaryTransfer` | true | keep; binary is used only for server-prepared statements |
| `preferQueryMode` | `extended` | `simple` only for proxies without the extended protocol |
| `defaultRowFetchSize` | 0, the whole result at once | a few hundred to stream big results (needs autocommit off) |
| `connectTimeout` / `socketTimeout` | 10 s / 0 | `socketTimeout` above your longest query, as a dead-network guard |
| `stringtype` | `VARCHAR` | `unspecified` to bind a Java `String` to `jsonb`, `uuid` or an enum |
| `ApplicationName` | `PostgreSQL JDBC Driver` | the service name, so `pg_stat_activity` shows who is who |
| `options` | none | `-c statement_timeout=30s` for a session default |
| `targetServerType` | `any` | `primary` with several hosts, to land on the writer |

## HikariCP pool sizing and settings

HikariCP is the pool Spring Boot uses by default. Its defaults: `maximumPoolSize` 10, `minimumIdle` equal to the
maximum (a fixed-size pool), `connectionTimeout` 30 s, `idleTimeout` 10 min, `maxLifetime` 30 min, `keepaliveTime`
2 min, `leakDetectionThreshold` 0 (off).

```java
HikariConfig cfg = new HikariConfig();
cfg.setJdbcUrl(System.getenv("JDBC_URL"));
cfg.setUsername(System.getenv("DB_USER"));
cfg.setPassword(System.getenv("DB_PASSWORD"));
cfg.setMaximumPoolSize(10);                 // instances x pool <= the database's budget
cfg.setConnectionTimeout(5_000);            // fail fast, not after 30 s
cfg.setMaxLifetime(30 * 60_000);            // shorter than any server, proxy or firewall idle cut-off
cfg.setKeepaliveTime(5 * 60_000);
cfg.setLeakDetectionThreshold(20_000);      // log holders over 20 s
cfg.addDataSourceProperty("reWriteBatchedInserts", "true");
cfg.addDataSourceProperty("ApplicationName", "orders-api");
cfg.addDataSourceProperty("options", "-c statement_timeout=30s");
HikariDataSource ds = new HikariDataSource(cfg);
```

Size the pool from the database side: total connections across all instances must fit `max_connections` minus
reserved slots (`postgres-connection-pooling`). A bigger pool usually means more waiting inside Postgres, not more
throughput.

## Virtual threads and the connection pool

Java virtual threads (Java 21 and later; Spring Boot recommends 24 or later) let a server run thousands of
concurrent requests, but the pool still allows only `maximumPoolSize` of them into the database at once. The rest
wait in `getConnection()` and fail after `connectionTimeout` with `SQLTransientConnectionException`. Keep the pool
sized for the database, set `connectionTimeout` low, and put a concurrency limit (a semaphore or bulkhead) in front
of database-heavy endpoints. In Spring Boot, `spring.threads.virtual.enabled=true` switches the web server and task
executors to virtual threads.

## Batches and COPY with CopyManager

A JDBC batch with `reWriteBatchedInserts=true` turns `executeBatch()` of single-row INSERTs into multi-row INSERTs;
PgJDBC documents a 2 to 3 times speed-up. `COPY` is faster still and goes through `CopyManager`.

```java
try (Connection c = ds.getConnection();
     PreparedStatement ps = c.prepareStatement("INSERT INTO orders (customer, total) VALUES (?, ?)")) {
    c.setAutoCommit(false);
    for (int i = 0; i < rows.size(); i++) {
        ps.setString(1, rows.get(i).customer());
        ps.setBigDecimal(2, rows.get(i).total());
        ps.addBatch();
        if (i % 1000 == 999) ps.executeBatch();
    }
    ps.executeBatch();
    c.commit();
}

try (Connection c = ds.getConnection()) {
    CopyManager copy = c.unwrap(PGConnection.class).getCopyAPI();
    long in = copy.copyIn("COPY orders (customer, total) FROM STDIN WITH (FORMAT csv)", reader);
    long out = copy.copyOut("COPY (SELECT * FROM orders) TO STDOUT WITH (FORMAT csv, HEADER)", writer);
}
```

`unwrap(PGConnection.class)` works through a Hikari proxy. With `reWriteBatchedInserts`, `executeBatch()` returns
`SUCCESS_NO_INFO` (-2) for rows merged into a multi-row INSERT, not real counts: do not sum the array.

## Streaming large results with fetch size

PgJDBC reads the whole result into memory unless a fetch size is set and autocommit is off; then it uses a cursor and
fetches in batches.

```java
try (Connection c = ds.getConnection()) {
    c.setAutoCommit(false);
    try (PreparedStatement ps = c.prepareStatement("SELECT id, payload FROM events WHERE day = ?")) {
        ps.setObject(1, day);
        ps.setFetchSize(500);
        try (ResultSet rs = ps.executeQuery()) {
            while (rs.next()) { /* one row at a time */ }
        }
    }
    c.commit();
}
```

Behind a transaction-mode pooler this still works, since the cursor lives inside the transaction.

## Type mapping: java.time, numeric, jsonb and arrays

PgJDBC maps types through `getObject(i, Class)` and `setObject`. The traps are time types and JSON.

| PostgreSQL | Java | Note |
|---|---|---|
| `timestamptz` | `OffsetDateTime` (UTC offset) | `getObject(i, Instant.class)` fails in 42.7.14: convert with `toInstant()` |
| `timestamp` | `LocalDateTime` | no zone; avoid for instants |
| `date` / `time` | `LocalDate` / `LocalTime` | |
| `numeric` | `BigDecimal` | never `double` for money |
| `bigint` | `long` | |
| `jsonb` | `PGobject` with type `jsonb`, or a `String` with `stringtype=unspecified` | |
| arrays | `conn.createArrayOf("bigint", Long[])` | bind to `= ANY(?)` |
| `uuid` | `java.util.UUID` | |

## LISTEN with getNotifications

PgJDBC delivers `NOTIFY` messages to the connection that ran `LISTEN`; `getNotifications(timeoutMillis)` waits up to
that long. Use a connection outside the pool (or one held for the listener's life), since the pool may reset or close
it.

```java
try (Connection listener = DriverManager.getConnection(url, user, password)) {
    try (Statement st = listener.createStatement()) { st.execute("LISTEN order_paid"); }
    PGConnection pg = listener.unwrap(PGConnection.class);
    while (running) {
        PGNotification[] ns = pg.getNotifications(10_000);   // empty array after the timeout
        for (PGNotification n : ns) handle(n.getName(), n.getParameter());
    }
}
```

## Transactions, SQLState and retries

PgJDBC raises `PSQLException` with `getSQLState()` and `getServerErrorMessage()` (constraint, table, detail). Retry
whole transactions on `40001` and `40P01` only (`postgres-app-drivers`); map `23505` to a conflict.
`Statement.setQueryTimeout(seconds)` cancels on the server with SQLState `57014`.

## Spring Boot 4: DataSource, JdbcClient and JPA

Spring Boot 4 builds a HikariCP `DataSource` from `spring.datasource.*` and `spring.datasource.hikari.*`.
`JdbcClient` runs SQL with named parameters; Spring Data JPA runs on Hibernate 7. The full application, properties
and entity mapping are in [Spring Boot, Hibernate and migrations](references/spring-hibernate.md).

```java
Map<String, Object> row = jdbc.sql("SELECT email, credit, attrs->>'plan' AS plan FROM customers WHERE id = :id")
        .param("id", id).query().singleRow();
List<String> emails = jdbc.sql("SELECT email FROM customers WHERE id = ANY(:ids) ORDER BY id")
        .param("ids", new Long[]{1L, 2L}).query(String.class).list();
```

Set `spring.jpa.open-in-view=false`: the default (true) keeps a connection-bound session open for the whole web
request, including view rendering.

## Hibernate 7 on PostgreSQL: sequences, batching and jsonb

Hibernate batches inserts only with a sequence id; an `IDENTITY` id disables JDBC insert batching. Use a sequence with
`INCREMENT BY` equal to `allocationSize` (50 by default), set `hibernate.jdbc.batch_size`, and map `jsonb` with
`@JdbcTypeCode(SqlTypes.JSON)`.

```java
@Id
@GeneratedValue(strategy = GenerationType.SEQUENCE, generator = "customers_seq")
@SequenceGenerator(name = "customers_seq", sequenceName = "customers_seq", allocationSize = 50)
private Long id;

@JdbcTypeCode(SqlTypes.JSON)
@Column(columnDefinition = "jsonb", nullable = false)
private Map<String, Object> attrs = new HashMap<>();
```

With `hibernate.jdbc.batch_size=50`, `order_inserts=true` and `reWriteBatchedInserts=true`, saving 200 entities ran
as 6 prepared statements on 18.6 instead of 200 round trips.

## Flyway and Liquibase migrations

Spring Boot 4 runs Flyway or Liquibase at startup only with `spring-boot-starter-flyway` or
`spring-boot-starter-liquibase`; the bare library no longer triggers it. Flyway on PostgreSQL also needs
`flyway-database-postgresql`.

- Flyway holds a transactional advisory lock by default, so a `CREATE INDEX CONCURRENTLY` migration waits forever on
  Flyway's own open transaction. Set `spring.flyway.postgresql.transactional-lock=false`
  (`flyway.postgresql.transactional.lock=false` outside Spring); Flyway then runs that file as non-transactional.
- Liquibase: put `runInTransaction="false"` on a changeset that runs `CREATE INDEX CONCURRENTLY`.
- Lock and backfill rules for the SQL itself: `postgres-schema-migrations`. Tests with Testcontainers:
  `postgres-testing-ci`.

## jOOQ and R2DBC

jOOQ (3.21.9, open-source edition supports PostgreSQL) generates classes from the live schema and builds typed SQL
with `ON CONFLICT`, `jsonb` and window functions. R2DBC (`r2dbc-postgresql` 1.1.3) is the non-blocking driver for
WebFlux; with virtual threads, JDBC is simpler and keeps Hibernate, Flyway and `CopyManager`.

## Verify the Java data layer

Run the quickstart first, then check from the database side what the pool and Hibernate really do. The queries ran
on 18.6; the application side was built and run in the reference.

```bash
java -cp postgresql-42.7.14.jar Main.java                  # prints a timestamp and the server version
```

```sql
SELECT application_name, state, count(*) FROM pg_stat_activity
WHERE application_name = 'orders-api' GROUP BY 1, 2;       -- total stays at or under maximumPoolSize
SELECT schemaname, sequencename, increment_by FROM pg_sequences
WHERE sequencename = 'customers_seq';                      -- 50, equal to allocationSize
```

For batching, read `getPrepareStatementCount()` from Hibernate's statistics: 200 inserts must show a handful of
statements, not 200. For a Flyway `CONCURRENTLY` file, the log must say `[non-transactional]`.

## Gotchas

These are the Java failures seen most often, each with its symptom, cause and fix.

1. **A Flyway migration with `CREATE INDEX CONCURRENTLY` hangs at startup.** `pg_stat_activity` shows the index
   build waiting on `virtualxid` behind Flyway's `idle in transaction` session. Set the transactional lock to false.
2. **`The increment size of the [x_seq] sequence is set to [50] in the entity mapping but the mapped database sequence increment size is [1]`.**
   Hibernate refuses to start with a `MappingException`, because `hibernate.id.sequence.increment_size_mismatch_strategy`
   defaults to `EXCEPTION`. Create the sequence `INCREMENT BY 50`.
3. **Hibernate inserts one row per round trip.** `IDENTITY` ids, or no `hibernate.jdbc.batch_size`. Switch to a
   sequence and set the batch size.
4. **`OutOfMemoryError` on a big query.** Autocommit on, or no fetch size. Turn autocommit off and set a fetch size.
5. **`column "attrs" is of type jsonb but expression is of type character varying`.** A `String` was bound to
   `jsonb`. Use `PGobject`, `?::jsonb`, or `stringtype=unspecified`.
6. **`prepared statement "S_1" already exists` behind PgBouncer.** Transaction mode without prepared statement
   support. Use PgBouncer 1.21+ with `max_prepared_statements`, or `prepareThreshold=0`.
7. **`Connection is not available, request timed out after 30000ms`.** The pool is exhausted: a leak, long
   transactions, or virtual threads queueing. Turn on `leakDetectionThreshold` and look at what holds connections.

## Anti-patterns in Java database code

These are the habits behind most slow or fragile Java services on Postgres.

| Do not | Do instead |
|---|---|
| Use `GenerationType.IDENTITY` on a table you insert into in bulk | Use a sequence with `INCREMENT BY` equal to `allocationSize` |
| Raise `maximumPoolSize` to fix pool timeouts | Find what holds connections with `leakDetectionThreshold`; size from the database's budget |
| Keep `spring.jpa.open-in-view` at its default | Set it to false and load what the view needs in the service |
| Call an HTTP service inside `@Transactional` | Commit first, or use an outbox, so a connection is not held during the call |
| Set `ddl-auto=update` in production | Set `validate` and change the schema with Flyway or Liquibase |
| Catch a SQL exception and carry on in the same transaction | Roll back, or use a nested savepoint: Postgres aborted the transaction |

## Checklist

Check these points before calling Java database code done.

- [ ] One HikariCP pool per service instance, sized from the database's connection budget, `connectionTimeout` low.
- [ ] `sslmode=verify-full` off localhost; credentials from the environment or a secret store.
- [ ] `ApplicationName` and a `statement_timeout` set; `spring.jpa.open-in-view=false`.
- [ ] Batches with `reWriteBatchedInserts=true`, or `COPY` through `CopyManager`.
- [ ] Hibernate ids from a sequence whose increment equals `allocationSize`; batch size set.
- [ ] Big results stream with a fetch size inside a transaction.
- [ ] Serializable code retries `40001`; deadlocks `40P01` retried everywhere.
- [ ] Flyway's transactional lock off when any migration uses `CONCURRENTLY`.

## See also

Related skills in this library, each one works on its own:

- `postgres-app-drivers`: the cross-language driver choice and shared rules.
- `postgres-connection-pooling`: connection budgets and PgBouncer modes.
- `postgres-schema-migrations`: lock and backfill rules for the SQL itself.
- `postgres-transactions-locking`: isolation levels, retries and the outbox pattern.
- `postgres-testing-ci`: tests with Testcontainers.

## Sources

- https://jdbc.postgresql.org/documentation/use/ (connection parameters), /documentation/server-prepare/, /documentation/ssl/
- https://github.com/brettwooldridge/HikariCP (README configuration defaults)
- https://docs.spring.io/spring-boot/reference/features/spring-application.html (virtual threads), /appendix/application-properties/
- https://github.com/spring-projects/spring-boot/wiki/Spring-Boot-4.0-Migration-Guide (Flyway and Liquibase starters)
- https://docs.jboss.org/hibernate/orm/7.4/userguide/html_single/Hibernate_User_Guide.html (batching, JSON mapping)
- https://documentation.red-gate.com/fd/flyway-postgresql-transactional-lock-setting-277579114.html
- https://docs.liquibase.com/reference-guide/changelog-attributes/runintransaction
- https://www.jooq.org/download/, Maven Central metadata for every artifact named, read 2026-10-28
