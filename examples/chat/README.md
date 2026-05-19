# Example: chat

A broadcast chat board. Every visitor sees every post in near-real-time
without polling — the page subscribes to the framework's `/events` SSE
stream and reloads itself whenever the server bumps `last_count` (which
happens on every `postMessage` / `clearMessages` action).

## Run

```sh
cd examples/chat
zig build
./zig-out/bin/chat-server
# Open http://127.0.0.1:8080/chat in two browser tabs and post.
```

## What this demonstrates

- **Form-based actions.** `/api/postMessage` accepts `author` + `body` form
  fields. The browser submits natively (no JS required) and the server
  redirects (303) back to `/chat`.
- **Multi-field action input.** Both string fields are parsed by the
  framework's URL-decoder and bound to the action's struct argument.
- **Server state with a spin-lock.** A fixed-size ring buffer guarded by
  `std.atomic.Mutex`; `snapshot()` dupes into the request arena before
  releasing.
- **SSE-driven live updates.** A tiny inline `<script>` subscribes to
  `/events`. When the integer counter advances past the value the page
  was rendered with, the script calls `location.reload()`. Works on every
  visitor's tab simultaneously.
- **Error returns surface as 500.** Posting an empty body returns
  `error.EmptyField`; the framework renders the standard error page.

## Files

| Path | Purpose |
|---|---|
| `build.zig` | Wires the framework via `../../src/...` |
| `src/app/api.zig` | `Actions` + ring buffer + `snapshot` |
| `src/app/routes.zig` | `/`, `/chat` |
| `src/app/components.zig` | Page chrome + chat list + auto-reload script |

## Things to try

- `curl -X POST -d 'author=alice&body=hello' http://127.0.0.1:8080/api/postMessage`
- Refresh `/chat` in two tabs, post from tab A, watch tab B update.
- Disable JS in the browser — posting still works, you just have to
  refresh manually.
