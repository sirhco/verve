# 08 — Observability

Three things drop out of the framework for free:

- **`/health`** — JSON liveness probe with uptime + total request count.
- **`/metrics`** — JSON per-route latency (count, avg_ns, max_ns).
- **Structured logs** — `std.log.scoped(.verve)` everywhere, including
  per-request `method path duration` lines.

No external metrics agent, no log shipper config. Plain JSON over HTTP.

## `/health`

```sh
curl http://127.0.0.1:8080/health
# {"status":"ok","uptime_sec":42,"requests":117}
```

Use it as a Kubernetes liveness / readiness probe, a load-balancer
health endpoint, or just a fast curl for "is it up?".

Headers:

- `content-type: application/json`
- `cache-control: no-store`

The fields:

- `status` — always `"ok"` if the handler runs. (If the server is
  dead, you get connection refused.)
- `uptime_sec` — seconds since the server boot timestamp captured in
  `main`.
- `requests` — monotonic count of every request received, including
  503'd ones.

## `/metrics`

```sh
curl http://127.0.0.1:8080/metrics | jq .
```

```json
{
  "uptime_sec": 84,
  "total_requests": 312,
  "rejected": 0,
  "routes": {
    "/": {"count": 23, "avg_ns": 195000, "max_ns": 1240000},
    "/counter": {"count": 18, "avg_ns": 240000, "max_ns": 980000},
    "/api/incrementCount": {"count": 5, "avg_ns": 120000, "max_ns": 410000},
    "/health": {"count": 240, "avg_ns": 78000, "max_ns": 220000}
  }
}
```

Headers:

- `content-type: application/json`
- `cache-control: no-store`

Top-level fields:

| Field | Source |
|---|---|
| `uptime_sec`     | Same as `/health`. |
| `total_requests` | Same as `/health.requests`. |
| `rejected`       | Connections turned away by the admission cap (503). |
| `routes`         | Per-route stats, keyed by canonical label. |

Per-route fields:

| Field | Meaning |
|---|---|
| `count`  | Number of requests handled. |
| `avg_ns` | Mean wall-clock from `receiveHead` to handler return, in nanoseconds. |
| `max_ns` | Maximum observed wall-clock, in nanoseconds. |

Routes with zero observations don't appear — keeps the JSON small even
on apps with dozens of `/api/<fn>` endpoints. The `__not_found__`
bucket collects all unknown paths.

### Why per-route, not per-handler-function?

The label is the **canonical request path**, not the function symbol.
`/public/*` collapses to a single bucket so dimensionality stays
bounded (static-asset cardinality could otherwise be unbounded).

`/api/<fn>` paths are listed individually because the action set is
fixed at compile time — `metrics.routeLabel` walks
`std.meta.declarations(app.Actions)` to recognize them.

### Wait-free recording

Latency recording is on the hot path of every request:

```zig
const t0 = std.Io.Clock.now(.awake, io);
// ... handler runs ...
const ns = t0.durationTo(end).nanoseconds;
metrics.record(route_label, @intCast(@max(ns, 0)));
```

`record` does atomic fetch-add on the count + total_ns counters and a
CAS loop for max_ns. No mutex. Concurrent recordings on the same label
are safe; readers (the `/metrics` handler) see a consistent-enough
snapshot for monitoring purposes (count and total may briefly disagree
across the read, but the next sample will close the gap).

### Adding application metrics

The framework's metrics module is for HTTP-level stats. Application
metrics — domain-specific counters, gauges, histograms — belong in
your `Actions` module:

```zig
pub var orders_processed: std.atomic.Value(u64) = .init(0);
pub var orders_failed: std.atomic.Value(u64) = .init(0);

pub const Actions = struct {
    pub fn placeOrder(...) !void {
        // ... business logic ...
        if (ok) _ = orders_processed.fetchAdd(1, .monotonic)
        else { _ = orders_failed.fetchAdd(1, .monotonic); return error.Rejected; }
    }
};
```

Expose them via your own page route (the bookmarks example's `/stats`
page is a worked example) or add an action that returns them as JSON.

## Logging

Every emit goes through `std.log.scoped(.verve)`. The scope means
filtering by source is trivial:

```sh
./zig-out/bin/verve-server 2>&1 | grep '^info(verve)'
```

The framework logs:

- One line per request — method, path, duration in µs or ms:
  ```
  info(verve): GET /counter 240µs
  info(verve): POST /api/addTodo 1.2ms
  ```
- Startup banner — listening URL, worker cap, all known routes /
  actions / assets / ops endpoints.
- Errors — body read failures, render errors, accept errors, signal
  delivery.

Set log level via `std_options` at the root of the executable. Default
is `.info`. Drop to `.warn` for quieter production output:

```zig
// src/server/main.zig
pub const std_options: std.Options = .{ .log_level = .warn };
```

(That edit ships only when you rebuild — there's no runtime knob today.
A `--log-level` flag is a one-line CLI extension if you need it.)

### Diagnostic prints

A few intentional `std.debug.print` calls live in:

- `printUsage` — CLI help.
- `onShutdownSignal` — final "received SIGTERM" line goes through
  `std.debug.print` rather than `log.info` because signal handlers
  shouldn't allocate.

If you grep for `std.debug.print` you'll find them all — there are
fewer than ten.

## Putting it on a dashboard

There's no Prometheus exposition format today (the chosen output is
JSON). To scrape into Prometheus, the cleanest path is a tiny adapter
that polls `/metrics`, parses the JSON, and re-exposes a
`text/plain; version=0.0.4` endpoint with the metric names you want.
Alternatively, switch `metrics.writeJson` to a Prometheus-style
serializer — ~30 lines change.

For ad-hoc dashboards: pipe `curl /metrics | jq .` into Grafana via
`json-exporter` or scrape into Loki via `promtail` parsing the
structured log lines.

## Next

- [09 — Performance](09-performance.md) — admission cap details that
  drive the `rejected` counter on `/metrics`.
- [11 — Deployment](11-deployment.md) — running this thing under
  systemd, including the LISTEN_FDS protocol.
