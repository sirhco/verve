# 09 — Performance & hardening

Three knobs and one always-on optimization:

1. **`--workers N`** — bounded admission so the server can't be DoS'd
   by connection floods.
2. **`--body-limit SIZE`** — caps POST body size.
3. **Gzip** — `Accept-Encoding: gzip` triggers compression of
   text-ish responses.

Plus the comptime-embed path for assets, covered in
[`07-static-assets.md`](07-static-assets.md).

## Admission cap (`--workers`)

The accept loop is the classic "spawn a thread per connection" shape.
On its own that's trivially DoS'able — a malicious client can open
10,000 connections and pin every CPU. Verve guards the loop with an
atomic admission counter:

```
client arrives → server.accept → admit.tryAdmit() ?
  ├── yes → spawn detached thread, increment counter
  └── no  → write minimal "503 Service Unavailable\r\nRetry-After: 1"
            and close the socket
```

```zig
// src/server/pool.zig
pub fn tryAdmit(self: *Admit) bool {
    var current = self.in_flight.load(.monotonic);
    while (true) {
        if (current >= self.max) return false;
        const result = self.in_flight.cmpxchgWeak(current, current + 1, .acquire, .monotonic);
        if (result) |new_current| { current = new_current; continue; }
        return true;
    }
}
```

Worker threads call `admit.release()` on exit (the `defer` chains
through `runConnection`).

### Defaults

- `--workers` defaults to `clamp(cpu_count * 2, 4, 1024)`.
- On a 2-core CI runner you get 4.
- On a 16-core dev box you get 32.
- Override explicitly for stress-testing: `--workers 1` is excellent
  for verifying admission behavior.

### Trade-offs vs a fixed worker pool

A classic N-workers-pull-from-a-queue pool would:

- Avoid the cost of spawning a thread per connection (small but
  measurable).
- Allow truly graceful shutdown (drain the queue, then join).

But it needs a condition variable to block workers when the queue is
empty, and Zig 0.16's `std.Thread` exposes only `spawn` / `detach` /
`join` — no `Mutex`, no `Condition`. Building a condvar via `std.Io.Mutex`
or futexes is doable but adds significant code for an unmeasured gain.
The current shape is a pragmatic compromise: pay for spawning on accept,
but cap concurrency so a flood can't escalate.

If that becomes a measurable bottleneck, the path is:

1. Add a per-listener `std.Thread.Semaphore`-shaped object (hand-rolled
   over futex or busy-wait).
2. Make the worker thread sticky — accept inside the worker, loop on
   one persistent thread per slot.

(That refactor is still a one-evening change; nobody's been blocked on
it yet.)

## Body limit (`--body-limit`)

Caps the size of POST bodies the dispatcher will read:

```sh
./zig-out/bin/verve-server --body-limit 64k
./zig-out/bin/verve-server --body-limit 2m
./zig-out/bin/verve-server --body-limit 1g
```

Plain bytes, or with `k` / `m` / `g` suffix (powers of 1024). Default
is **1 MB**. The limit is enforced in
`api_handler.dispatch` via `body_reader.allocRemaining(gpa, .limited(body_limit))`
— oversized bodies return 400 Bad Request rather than allocating
the whole thing.

There is no per-route override. If your app has one action that takes
large bodies (e.g. an upload) and the rest are tiny, set the limit to
fit the upload. For genuinely large uploads, the right answer is to
stream — that's not in the framework today and would need either a
new handler path or a generic chunked-input action shape.

## Gzip compression

Triggers when **all three** are true:

- The client sent `Accept-Encoding: gzip`.
- The response content-type is gzip-eligible (text/, JSON, JS, SVG).
- The body is ≥ 256 bytes.

Binary formats (`image/png`, `image/webp`, `application/wasm`,
`application/octet-stream`) are skipped — already-compressed data
gains nothing.

The helper:

```zig
// src/server/gzip.zig
pub fn compress(gpa: std.mem.Allocator, input: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try aw.ensureUnusedCapacity(64);
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var compressor = try flate.Compress.init(&aw.writer, window, .gzip, flate.Compress.Options.default);
    try compressor.writer.writeAll(input);
    try compressor.finish();
    return aw.toOwnedSlice();
}
```

`std.compress.flate.Compress` with `Container.gzip` produces a fully
framed gzip stream (header + deflate + crc32 + isize footer). The
output is a Content-Length response with `content-encoding: gzip` —
not chunked — so the client knows how much to expect.

On compression failure, the framework falls back to sending the raw
body uncompressed. The request still succeeds.

### When you should turn it off

You can disable gzip for a content-type by editing
`gzip.shouldCompress` in `src/server/gzip.zig`. Real cases:

- If you put Verve behind nginx / Cloudflare / Fly Edge, those
  already compress.
- If you serve only binary content (rare for an SSR framework).

There's no CLI flag for it — it's an opt-out by editing the table.

## Tunables summary

| Knob | Default | Where set |
|---|---|---|
| `--host`             | `127.0.0.1`     | CLI |
| `--port`             | `8080`          | CLI |
| `--body-limit`       | `1m`            | CLI (k/m/g suffix) |
| `--public-dir`       | none            | CLI |
| `--workers`          | `clamp(cpu*2, 4, 1024)` | CLI |
| Static-file cap      | `4 MB`          | `src/server/main.zig:STATIC_MAX_SIZE` |
| SSE tick interval    | `1 s`           | `src/server/main.zig:SSE_TICK` |
| WS broadcast tick    | `250 ms`        | `src/server/main.zig:WS_TICK` |
| Gzip min body        | `256 B`         | `src/server/main.zig:respondBuffered` |
| Gzip eligibility     | text/, JSON, JS, SVG | `src/server/gzip.zig:shouldCompress` |
| Read buffer per conn | `64 KB`         | `src/server/main.zig:READ_BUF_SIZE` |
| Write buffer per conn| `64 KB`         | `src/server/main.zig:WRITE_BUF_SIZE` |

All of them are constants in `src/server/main.zig` except the gzip
ones in `src/server/gzip.zig`. Bumping any of them is a one-line
edit + rebuild.

## Load-testing

A trivial sanity check:

```sh
# ApacheBench — 5000 requests, 64 concurrent
ab -n 5000 -c 64 http://127.0.0.1:8080/

# wrk — 30 seconds, 16 threads, 100 connections
wrk -t16 -c100 -d30s http://127.0.0.1:8080/

# hey — similar, simpler output
hey -n 5000 -c 64 http://127.0.0.1:8080/
```

Watch `/metrics.rejected` climb when you exceed `--workers`. Watch
`/metrics.routes."/".avg_ns` for steady-state latency.

A single core can easily serve thousands of requests per second for the
simple counter page — the renderer streams, gzip is per-response, and
the dispatcher is comptime. Bottlenecks usually appear in the
application action, not the framework.

## Next

- [10 — Scaffolder](10-scaffolder.md) — `verve-cli new`.
- [11 — Deployment](11-deployment.md) — systemd, signal handling,
  containerization.
