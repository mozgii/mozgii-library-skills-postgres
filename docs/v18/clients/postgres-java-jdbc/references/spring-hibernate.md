---
title: Spring Boot 4, Hibernate 7 and Flyway on PostgreSQL
author: MOZGII, Inc.
lang: en
---

# Spring Boot 4, Hibernate 7 and Flyway on PostgreSQL

This reference is a complete Spring Boot 4.1.2 application on PostgreSQL: Maven build, properties, a Flyway schema,
a JPA entity with a pooled sequence, `jsonb` and `text[]`, a transactional service and `JdbcClient` queries. It was
built with Maven on Java 25 and run against PostgreSQL 18.6 (Hibernate 7.4.13, HikariCP 7.0.2, Flyway 12.4.0 and
PgJDBC 42.7.14, as managed by Boot 4.1.2).

## Contents

The sections of this reference on Spring Boot, Hibernate and Flyway:

1. Maven build for Spring Boot 4 with JPA and Flyway
2. application.properties for PostgreSQL
3. Flyway schema with a pooled sequence
4. JPA entity with jsonb, text[] and optimistic locking
5. Transactional service and JdbcClient
6. Checking that Hibernate batches
7. Spring transaction rules on PostgreSQL

## Maven build for Spring Boot 4 with JPA and Flyway

The Spring Boot 4 build needs the Flyway starter (Boot 4 split auto-configuration into modules) and Flyway's
PostgreSQL module. The driver is a runtime dependency; Boot's parent pins every version.

```xml
<parent>
  <groupId>org.springframework.boot</groupId>
  <artifactId>spring-boot-starter-parent</artifactId>
  <version>4.1.2</version>
</parent>
<properties>
  <java.version>25</java.version>
</properties>
<dependencies>
  <dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-data-jpa</artifactId>
  </dependency>
  <dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-flyway</artifactId>
  </dependency>
  <dependency>
    <groupId>org.flywaydb</groupId>
    <artifactId>flyway-database-postgresql</artifactId>
  </dependency>
  <dependency>
    <groupId>org.postgresql</groupId>
    <artifactId>postgresql</artifactId>
    <scope>runtime</scope>
  </dependency>
</dependencies>
```

Use `spring-boot-starter-jdbc` instead of the JPA starter for a `JdbcClient`-only service.

## application.properties for PostgreSQL

These properties set the pool, PgJDBC parameters, Hibernate batching and Flyway. Credentials come from the
environment.

```properties
spring.datasource.url=${JDBC_URL}
spring.datasource.username=${DB_USER}
spring.datasource.password=${DB_PASSWORD}
spring.datasource.hikari.maximum-pool-size=10
spring.datasource.hikari.connection-timeout=5000
spring.datasource.hikari.max-lifetime=1800000
spring.datasource.hikari.data-source-properties.reWriteBatchedInserts=true
spring.datasource.hikari.data-source-properties.ApplicationName=shop
spring.jpa.open-in-view=false
spring.jpa.hibernate.ddl-auto=validate
spring.jpa.properties.hibernate.jdbc.batch_size=50
spring.jpa.properties.hibernate.order_inserts=true
spring.jpa.properties.hibernate.order_updates=true
spring.threads.virtual.enabled=true
spring.flyway.locations=classpath:db/migration
spring.flyway.postgresql.transactional-lock=false
```

- `ddl-auto=validate` checks the entities against the schema Flyway built; never `update` in production.
- `transactional-lock=false` lets `CREATE INDEX CONCURRENTLY` migrations finish; with the default `true` they wait
  on Flyway's own open transaction until someone kills it.

## Flyway schema with a pooled sequence

The schema's sequence increments by 50 to match Hibernate's default `allocationSize`, so Hibernate takes 50 ids per
`nextval` call. Files live in `src/main/resources/db/migration` as `V<version>__<name>.sql`.

```sql
-- V1__customers.sql
CREATE SEQUENCE customers_seq INCREMENT BY 50;
CREATE TABLE customers (
  id         bigint PRIMARY KEY DEFAULT nextval('customers_seq'),
  email      text NOT NULL UNIQUE,
  credit     numeric(12,2) NOT NULL DEFAULT 0,
  attrs      jsonb NOT NULL DEFAULT '{}',
  tags       text[] NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL DEFAULT now(),
  version    bigint NOT NULL DEFAULT 0
);
ALTER SEQUENCE customers_seq OWNED BY customers.id;
```

A file that holds only `CREATE INDEX CONCURRENTLY` is detected by Flyway and run outside a transaction (the log says
`[non-transactional]`):

```sql
-- V2__customers_created_at_idx.sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS customers_created_at_idx ON customers (created_at);
```

## JPA entity with jsonb, text[] and optimistic locking

This Hibernate 7 entity maps `jsonb` to a `Map`, `text[]` to a `List<String>`, `timestamptz` to `Instant`, and uses
a `@Version` column so concurrent updates fail instead of overwriting.

```java
@Entity
@Table(name = "customers")
public class Customer {
    @Id
    @GeneratedValue(strategy = GenerationType.SEQUENCE, generator = "customers_seq")
    @SequenceGenerator(name = "customers_seq", sequenceName = "customers_seq", allocationSize = 50)
    private Long id;

    @Column(nullable = false, unique = true)
    private String email;

    @Column(nullable = false, precision = 12, scale = 2)
    private BigDecimal credit = BigDecimal.ZERO;

    @JdbcTypeCode(SqlTypes.JSON)
    @Column(columnDefinition = "jsonb", nullable = false)
    private Map<String, Object> attrs = new HashMap<>();

    @JdbcTypeCode(SqlTypes.ARRAY)
    @Column(columnDefinition = "text[]", nullable = false)
    private List<String> tags = List.of();

    @Column(name = "created_at", nullable = false, insertable = false, updatable = false)
    private Instant createdAt;

    @Version
    private long version;

    protected Customer() {}
    // constructor, getters and domain methods
}
```

`insertable = false` lets the database default fill `created_at`. A failed version check throws
`ObjectOptimisticLockingFailureException` in Spring; reload and retry, or report a conflict.

## Transactional service and JdbcClient

Spring's `@Transactional` binds one connection to the method; repositories and `JdbcClient` calls inside it share
that connection and transaction.

```java
@Service
class CustomerService {
    private final CustomerRepository repo;
    CustomerService(CustomerRepository repo) { this.repo = repo; }

    @Transactional
    public void importCustomers(List<Customer> customers) {
        repo.saveAll(customers);
    }

    @Transactional
    public long addCredit(String email, BigDecimal amount) {
        Customer c = repo.findByEmail(email).orElseThrow();
        c.addCredit(amount);                       // flushed as one UPDATE at commit
        return c.getId();
    }
}
```

`JdbcClient` reads with named parameters and maps to records, scalars or maps:

```java
List<String> emails = jdbc.sql("SELECT email FROM customers WHERE id = ANY(:ids) ORDER BY id")
        .param("ids", new Long[]{1L, 2L}).query(String.class).list();
```

## Checking that Hibernate batches

Hibernate's statistics show whether inserts were batched. Turn them on in a test profile
(`spring.jpa.properties.hibernate.generate_statistics=true`) and read the prepared statement count.

```java
var stats = emf.unwrap(SessionFactory.class).getStatistics();
service.importCustomers(twoHundredCustomers);
System.out.println(stats.getPrepareStatementCount());   // 6 on PostgreSQL 18.6 for 200 rows
```

200 inserts ran as 6 prepared statements in total, inserts and sequence calls together. With `IDENTITY` ids
Hibernate turns insert batching off, so each row is its own round trip.

## Spring transaction rules on PostgreSQL

These Spring rules prevent most transaction bugs on PostgreSQL.

- `@Transactional` applies only through the Spring proxy: a call from another method of the same class skips it.
- An exception caught inside a transaction still leaves PostgreSQL's transaction aborted
  (`current transaction is aborted, commands ignored until end of transaction block`); use a nested savepoint or let
  it propagate.
- Keep HTTP calls and message publishing out of `@Transactional` methods: they hold a pooled connection and a
  snapshot open (`postgres-transactions-locking`, outbox pattern).
