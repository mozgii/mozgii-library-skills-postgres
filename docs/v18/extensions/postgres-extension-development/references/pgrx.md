---
title: PostgreSQL extensions in Rust with pgrx
author: MOZGII, Inc.
lang: en
---

# PostgreSQL extensions in Rust with pgrx

This reference summarizes pgrx 0.19.3 (crates.io, released September 2026) from its README, the `cargo-pgrx` README
and the project templates. It was not run on the test machine, which has no Rust toolchain; every command and file
below is quoted from those sources.

## pgrx requirements and supported versions

pgrx supports PostgreSQL 13 through 18, plus a 19 beta, and is tested on x86_64 and aarch64 Linux, aarch64 macOS and
x86_64 Windows. It needs a Rust toolchain from rustup (no minimum version policy: use the latest stable), `git`,
`libclang` 11 or later for bindgen, and a C compiler (MSVC or Clang on Windows). `cargo pgrx init` downloads and
builds PostgreSQL on Linux and macOS, and downloads EDB binaries on Windows, unless you point it at a
user-writable installation's `pg_config`.

## pgrx project layout and features

`cargo pgrx new my_extension` creates `Cargo.toml`, `my_extension.control`, `sql/` and `src/lib.rs`. The generated
`Cargo.toml` pins pgrx exactly and has one feature per PostgreSQL major:

```toml
[lib]
crate-type = ["cdylib"]

[features]
default = ["pg13"]
pg18 = ["pgrx/pg18", "pgrx-tests/pg18" ]
pg_test = []

[dependencies]
pgrx = "=0.19.3"

[dev-dependencies.pgrx-tests]
version = "=0.19.3"

[profile.release]
panic = "unwind"
opt-level = 3
lto = "fat"
codegen-units = 1
```

Change `default` to the major you target, or pass `--features pg18 --no-default-features`; keep
`panic = "unwind"` as the template sets it.

## A pgrx function and its test

The template's `src/lib.rs` declares the module magic, one SQL function and one in-database test:

```rust
use pgrx::prelude::*;

::pgrx::pg_module_magic!(name, version);

#[pg_extern]
fn hello_my_extension() -> &'static str {
    "Hello, my_extension"
}

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {
    use pgrx::prelude::*;

    #[pg_test]
    fn test_hello_my_extension() {
        assert_eq!("Hello, my_extension", crate::hello_my_extension());
    }
}
```

- `#[pg_extern]` exports a function; `Option<T>` arguments and results map to SQL NULL.
- `SetOfIterator` returns `SETOF`, `TableIterator` returns `TABLE (...)`, `#[pg_trigger]` writes triggers.
- `#[derive(PostgresType)]` makes a Rust struct a PostgreSQL type (CBOR on disk, JSON as text by default);
  `#[derive(PostgresEnum)]` makes an enum.
- Type mapping: `text` is `String`/`&str`, `bigint` is `i64`, `jsonb` is `pgrx::JsonB`, `timestamptz` is
  `pgrx::TimestampWithTimeZone`.

## pgrx commands for build, test and packaging

These `cargo pgrx` commands cover the development loop.

| Command | Does |
|---|---|
| `cargo pgrx init [--pg18 download\|<pg_config>]` | registers or builds the PostgreSQL versions pgrx uses |
| `cargo pgrx run pg18` | builds, installs into pgrx's server, starts it, opens psql |
| `cargo pgrx test pg18` | runs `#[test]` and `#[pg_test]` functions inside a temporary server |
| `cargo pgrx install [--release] [--sudo]` | installs into the `pg_config` found on `PATH` |
| `cargo pgrx package` | writes an installation tree under `target/release/<name>-pg<N>/` for packaging |
| `cargo pgrx schema` | prints the generated SQL |

For cross-compiling, pgrx documents `cargo pgrx init --no-run` with the target's `pg_config`, then
`cargo pgrx package --pg-config <path> --target <triple>`; `cargo pgrx run` does not work in that setup.

## When to choose pgrx over C

pgrx removes most memory and error-handling mistakes of C (Rust panics and `elog(ERROR)` both unwind through Rust's
drop logic) and builds for several majors from one codebase with feature flags. Its costs are build time, a Rust
toolchain in every build environment, and a pinned pgrx version that must be upgraded to support each new PostgreSQL
major. Low-level hooks and custom index access methods are still easier to follow in C, where the PostgreSQL source is
the reference.
