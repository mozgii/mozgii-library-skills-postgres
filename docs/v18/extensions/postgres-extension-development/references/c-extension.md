---
title: A complete PostgreSQL C extension with PGXS
author: MOZGII, Inc.
lang: en
---

# A complete PostgreSQL C extension with PGXS

This reference holds the full source of `pgl_hello`, the C extension built and run against Postgres.app 18.6 on
macOS: a checked `bigint` addition, a `text` function, a query through SPI guarded by a custom setting, a counter in
shared memory updated by an executor hook, and a background worker. Use it as a starting skeleton.

## Files of the C extension

The extension is four files plus tests. The control file names the library without `$libdir/`, so
`dynamic_library_path` can find it outside the server's directory:

```ini
# pgl_hello.control
comment = 'Example C extension: checked math, text, SPI, a hook and a background worker'
default_version = '1.0'
module_pathname = 'pgl_hello'
relocatable = true
```

The install script declares each C symbol as an SQL function:

```sql
-- sql/pgl_hello--1.0.sql
\echo Use "CREATE EXTENSION pgl_hello" to load this file. \quit

CREATE FUNCTION add_checked(bigint, bigint) RETURNS bigint
AS 'MODULE_PATHNAME', 'pgl_add_checked' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION reverse_bytes(text) RETURNS text
AS 'MODULE_PATHNAME', 'pgl_reverse_bytes' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION table_rows(regclass) RETURNS bigint
AS 'MODULE_PATHNAME', 'pgl_table_rows' LANGUAGE C STABLE STRICT PARALLEL RESTRICTED;

CREATE FUNCTION executor_runs() RETURNS bigint
AS 'MODULE_PATHNAME', 'pgl_executor_runs' LANGUAGE C VOLATILE PARALLEL SAFE;
```

## C source of the extension

The source compiles without warnings with the flags PGXS takes from Postgres.app 18.6's `pg_config`. Text arguments
are read with `PG_GETARG_TEXT_PP` and `VARDATA_ANY`, which also accept short and compressed values; the result is
built with `palloc` and `SET_VARSIZE`. SPI runs SQL from C inside the current transaction; `SPI_execute(sql, true, 0)`
runs it read-only with no row limit. `quote_qualified_identifier` quotes the table name, because SPI has no
parameters for identifiers. This is the whole file:

```c
#include "postgres.h"

#include "common/int.h"
#include "executor/executor.h"
#include "executor/spi.h"
#include "fmgr.h"
#include "miscadmin.h"
#include "port/atomics.h"
#include "postmaster/bgworker.h"
#include "storage/ipc.h"
#include "storage/lwlock.h"
#include "storage/shmem.h"
#include "utils/builtins.h"
#include "utils/guc.h"
#include "utils/lsyscache.h"

PG_MODULE_MAGIC_EXT(.name = "pgl_hello", .version = "1.0.0");

typedef struct PglHelloShared
{
	pg_atomic_uint64 executor_runs;
} PglHelloShared;

static PglHelloShared *shared = NULL;
static int	pgl_hello_max_rows = 1000000;
static shmem_request_hook_type prev_shmem_request_hook = NULL;
static shmem_startup_hook_type prev_shmem_startup_hook = NULL;
static ExecutorEnd_hook_type prev_ExecutorEnd = NULL;

PGDLLEXPORT void pgl_hello_worker_main(Datum main_arg);

/* add_checked(bigint, bigint): addition that raises instead of wrapping */
PG_FUNCTION_INFO_V1(pgl_add_checked);
Datum
pgl_add_checked(PG_FUNCTION_ARGS)
{
	int64		a = PG_GETARG_INT64(0);
	int64		b = PG_GETARG_INT64(1);
	int64		result;

	if (pg_add_s64_overflow(a, b, &result))
		ereport(ERROR,
				(errcode(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE),
				 errmsg("bigint out of range")));
	PG_RETURN_INT64(result);
}

/* reverse_bytes(text): palloc'd result in the function's memory context */
PG_FUNCTION_INFO_V1(pgl_reverse_bytes);
Datum
pgl_reverse_bytes(PG_FUNCTION_ARGS)
{
	text	   *in = PG_GETARG_TEXT_PP(0);
	int			len = VARSIZE_ANY_EXHDR(in);
	const char *src = VARDATA_ANY(in);
	text	   *out = (text *) palloc(VARHDRSZ + len);
	char	   *dst = VARDATA(out);

	SET_VARSIZE(out, VARHDRSZ + len);
	for (int i = 0; i < len; i++)
		dst[i] = src[len - 1 - i];
	PG_RETURN_TEXT_P(out);
}

/* table_rows(regclass): count(*) through SPI, refusing tables above a GUC limit */
PG_FUNCTION_INFO_V1(pgl_table_rows);
Datum
pgl_table_rows(PG_FUNCTION_ARGS)
{
	Oid			relid = PG_GETARG_OID(0);
	char	   *nsp = get_namespace_name(get_rel_namespace(relid));
	char	   *rel = get_rel_name(relid);
	StringInfoData sql;
	int64		count;
	bool		isnull;
	int			rc;

	if (nsp == NULL || rel == NULL)
		ereport(ERROR, (errcode(ERRCODE_UNDEFINED_TABLE), errmsg("relation %u does not exist", relid)));

	initStringInfo(&sql);
	appendStringInfo(&sql, "SELECT count(*) FROM %s", quote_qualified_identifier(nsp, rel));

	SPI_connect();
	rc = SPI_execute(sql.data, true, 0);
	if (rc != SPI_OK_SELECT || SPI_processed != 1)
		elog(ERROR, "SPI_execute failed: %s", SPI_result_code_string(rc));
	count = DatumGetInt64(SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &isnull));
	SPI_finish();

	if (count > pgl_hello_max_rows)
		ereport(ERROR,
				(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				 errmsg("table has %lld rows, more than pgl_hello.max_rows (%d)",
						(long long) count, pgl_hello_max_rows)));
	PG_RETURN_INT64(count);
}

/* executor_runs(): a counter in shared memory, NULL when not preloaded */
PG_FUNCTION_INFO_V1(pgl_executor_runs);
Datum
pgl_executor_runs(PG_FUNCTION_ARGS)
{
	if (shared == NULL)
		PG_RETURN_NULL();
	PG_RETURN_INT64((int64) pg_atomic_read_u64(&shared->executor_runs));
}

static void
pgl_shmem_request(void)
{
	if (prev_shmem_request_hook)
		prev_shmem_request_hook();
	RequestAddinShmemSpace(MAXALIGN(sizeof(PglHelloShared)));
}

static void
pgl_shmem_startup(void)
{
	bool		found;

	if (prev_shmem_startup_hook)
		prev_shmem_startup_hook();
	LWLockAcquire(AddinShmemInitLock, LW_EXCLUSIVE);
	shared = ShmemInitStruct("pgl_hello", sizeof(PglHelloShared), &found);
	if (!found)
		pg_atomic_init_u64(&shared->executor_runs, 0);
	LWLockRelease(AddinShmemInitLock);
}

static void
pgl_ExecutorEnd(QueryDesc *queryDesc)
{
	if (shared)
		pg_atomic_fetch_add_u64(&shared->executor_runs, 1);
	if (prev_ExecutorEnd)
		prev_ExecutorEnd(queryDesc);
	else
		standard_ExecutorEnd(queryDesc);
}

void
pgl_hello_worker_main(Datum main_arg)
{
	BackgroundWorkerUnblockSignals();
	elog(LOG, "pgl_hello worker started, pid %d", MyProcPid);
	proc_exit(0);
}

void
_PG_init(void)
{
	BackgroundWorker worker;

	DefineCustomIntVariable("pgl_hello.max_rows",
							"Largest table table_rows() will count.",
							NULL, &pgl_hello_max_rows, 1000000, 0, INT_MAX,
							PGC_USERSET, 0, NULL, NULL, NULL);
	MarkGUCPrefixReserved("pgl_hello");

	if (!process_shared_preload_libraries_in_progress)
		return;					/* hooks and workers only when preloaded */

	prev_shmem_request_hook = shmem_request_hook;
	shmem_request_hook = pgl_shmem_request;
	prev_shmem_startup_hook = shmem_startup_hook;
	shmem_startup_hook = pgl_shmem_startup;
	prev_ExecutorEnd = ExecutorEnd_hook;
	ExecutorEnd_hook = pgl_ExecutorEnd;

	memset(&worker, 0, sizeof(worker));
	worker.bgw_flags = BGWORKER_SHMEM_ACCESS;
	worker.bgw_start_time = BgWorkerStart_RecoveryFinished;
	worker.bgw_restart_time = BGW_NEVER_RESTART;
	snprintf(worker.bgw_library_name, BGW_MAXLEN, "pgl_hello");
	snprintf(worker.bgw_function_name, BGW_MAXLEN, "pgl_hello_worker_main");
	snprintf(worker.bgw_name, BGW_MAXLEN, "pgl_hello worker");
	snprintf(worker.bgw_type, BGW_MAXLEN, "pgl_hello");
	RegisterBackgroundWorker(&worker);
}
```

## What the C extension does when run

These results came from the scratch server, first without preloading and then with
`shared_preload_libraries = pg_stat_statements, pgl_hello` and a restart:

```text
SELECT add_checked(40, 2), reverse_bytes('stressed');      -> 42 | desserts
SELECT add_checked(9223372036854775807, 1);                -> ERROR: bigint out of range
SET pgl_hello.max_rows = 10; SELECT table_rows('pg_class'); -> ERROR: table has 419 rows, more than pgl_hello.max_rows (10)
SET pgl_hello.unknown = 1;                                  -> ERROR: invalid configuration parameter name "pgl_hello.unknown"
                                                               DETAIL: "pgl_hello" is a reserved prefix.
SELECT module_name, version FROM pg_get_loaded_modules();   -> pgl_hello | 1.0.0
SELECT executor_runs();   (not preloaded)                   -> NULL
server log after restart with preloading                    -> LOG: pgl_hello worker started, pid 61821
SELECT executor_runs();   (preloaded)                       -> 0 on a fresh server, 3 after three more statements
```

## Rules for C extension code

These rules come from the PostgreSQL 18 documentation on C-language functions and were followed above.

- Include `postgres.h` first, then `fmgr.h` and the rest.
- Zero structures (`memset` or `palloc0`) before use; padding bytes otherwise hold garbage that can break hashing
  and comparisons.
- Use `palloc`/`pfree`, never `malloc`/`free`, for anything returned to the server; memory is reclaimed with its
  context at the end of the call or transaction.
- Report errors with `ereport(ERROR, (errcode(...), errmsg(...)))`; `elog` is for internal "cannot happen" errors.
- Declare `_PG_init` work that needs shared memory or hooks only when
  `process_shared_preload_libraries_in_progress` is true.
- Save the previous value of every hook and call it (or the `standard_` function) from yours.
- Reserve your setting prefix with `MarkGUCPrefixReserved` so misspelled settings fail instead of being ignored.
- A loaded library is never unloaded; reconnect after reinstalling.
