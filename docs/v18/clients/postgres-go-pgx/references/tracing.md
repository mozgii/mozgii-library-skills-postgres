---
title: A slow query tracer for pgx
author: MOZGII, Inc.
lang: en
---

# A slow query tracer for pgx

A pgx `QueryTracer` has two methods, one called before a query and one after it. This reference gives a small tracer
for `cfg.ConnConfig.Tracer` that logs statements slower than a limit. It logs SQL text and timings, never argument
values, which hold user data.

## slowQueryTracer: log statements slower than a limit

This tracer logs statements slower than a limit, through `log/slog`. It compiled and ran on Go 1.27 with pgx 5.11.0, where a
`pg_sleep(0.05)` logged `slow query took=55ms`.

```go
type queryStartKey struct{}

type queryStart struct {
	sql   string
	began time.Time
}

type slowQueryTracer struct{ min time.Duration }

func (t slowQueryTracer) TraceQueryStart(ctx context.Context, _ *pgx.Conn, d pgx.TraceQueryStartData) context.Context {
	return context.WithValue(ctx, queryStartKey{}, queryStart{sql: d.SQL, began: time.Now()})
}

func (t slowQueryTracer) TraceQueryEnd(ctx context.Context, _ *pgx.Conn, d pgx.TraceQueryEndData) {
	s, ok := ctx.Value(queryStartKey{}).(queryStart)
	if !ok {
		return
	}
	if took := time.Since(s.began); took >= t.min {
		slog.Warn("slow query", "took", took, "tag", d.CommandTag.String(), "err", d.Err, "sql", s.sql)
	}
}
```

`TraceQueryStart` puts the start time in the context pgx passes on to `TraceQueryEnd`, so the tracer holds no shared
state and one value serves the whole pool. The imports are `context`, `log/slog`, `time` and
`github.com/jackc/pgx/v5`. Set it with `cfg.ConnConfig.Tracer = slowQueryTracer{min: 200 * time.Millisecond}`.
