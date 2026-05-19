# Example: bookmarks

A starred-links list with per-bookmark visit counters and a custom
stats page sitting alongside the framework's `/metrics` JSON.

## Run

```sh
cd examples/bookmarks
zig build
./zig-out/bin/bookmarks-server
# Open http://127.0.0.1:8080/
```

## What this demonstrates

- **Multi-route apps.** Two distinct page routes (`/` for the list,
  `/stats` for app-level aggregates) plus three actions
  (`addBookmark`, `removeBookmark`, `recordVisit`).
- **Custom input validation.** `addBookmark` checks for non-empty
  title + URL and enforces `http://` or `https://` schemes. Validation
  errors return as `error.MissingTitle` / `error.MissingUrl` /
  `error.InvalidScheme`, which the framework renders as 500 with the
  error name visible in the standard error page.
- **Per-record atomic state.** Each bookmark carries its own
  `std.atomic.Value(u64)` visit counter — incremented on every
  `recordVisit` call, surfaced in the table and in the stats page.
- **Aggregate accessors.** `totalBookmarks()` and `totalVisits()`
  walk the fixed-size pool under the spin-lock and return a snapshot
  to the renderer.
- **Composability with framework observability.** The /stats page
  links straight to /metrics, where you can see per-route latency
  for `/api/addBookmark`, `/api/removeBookmark`, `/api/recordVisit`
  — derived automatically from the comptime walk over `Actions`.

## Files

| Path | Purpose |
|---|---|
| `build.zig` | Wires the framework via `../../src/...` |
| `src/app/api.zig` | Pool of bookmarks + actions + validation |
| `src/app/routes.zig` | `/`, `/stats` |
| `src/app/components.zig` | Page chrome + nav + list + stats cards |

## Things to try

- Submit `title=foo&url=ftp://x` — see the `InvalidScheme` error page.
- Curl a handful of bookmarks, then hit `/metrics` for the
  per-action histogram.
- Open `/stats` in one tab and `/metrics` in another; refresh both
  while adding bookmarks to compare app metrics vs framework metrics.
