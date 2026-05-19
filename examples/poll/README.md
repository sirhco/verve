# Example: poll

A live multi-candidate poll. Vote and every connected browser sees the
tallies update via the framework's SSE stream.

## Run

```sh
cd examples/poll
zig build
./zig-out/bin/poll-server
# Open http://127.0.0.1:8080/ in several tabs and vote.
```

## What this demonstrates

- **Single action driving multiple counters.** `/api/vote` takes a
  `candidate: usize` form field; the action looks up the matching
  atomic counter and bumps it. Adding candidates is a one-line edit
  to the `CANDIDATES` constant.
- **Atomic state arrays.** `tallies: [N]std.atomic.Value(u32)` —
  no lock needed for the increment path, and the snapshot read uses
  per-counter `.load(.monotonic)`.
- **Comptime UI from runtime data.** The page renders one row per
  candidate, computes percentage bars from the live counters.
- **SSE-driven full-page refresh.** Same pattern as the chat example
  but driving a richer DOM update.
- **Form fallback.** Each "Vote" button is its own tiny `<form>` with
  a hidden `candidate` input. Works with JS disabled.

## Files

| Path | Purpose |
|---|---|
| `build.zig` | Wires the framework via `../../src/...` |
| `src/app/api.zig` | `vote`, `resetTallies` actions |
| `src/app/routes.zig` | `/` |
| `src/app/components.zig` | Page chrome + poll rows + auto-reload script |

## Things to try

- `curl -X POST -d 'candidate=2' http://127.0.0.1:8080/api/vote`
- Hit `/health` and `/metrics` while traffic is flowing — note the
  per-route latency for `/api/vote` accumulating.
- Bump `--workers 1` and load the page from a dozen tabs at once;
  observe the admission cap throttling.
