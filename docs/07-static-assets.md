# 07 — Static assets

Verve serves files under `/public/*` two ways:

1. **Runtime overlay** — `--public-dir DIR` reads from disk on every
   request. Great for development.
2. **Comptime embed** — `-Dpublic-dir=DIR` bakes every file in `DIR`
   into the binary via `@embedFile`. Great for production / containers.

Both can be active at once. The runtime overlay wins on collision, so
you can override an embedded file by dropping a same-named file on disk.

## Runtime: `--public-dir`

```sh
mkdir -p ./public
echo "hello" > ./public/index.txt
./zig-out/bin/verve-server --public-dir ./public
curl http://127.0.0.1:8080/public/index.txt
# hello
```

The handler (`src/server/main.zig:serveStatic`):

- Rejects empty paths, absolute paths (`/foo`), and any path
  containing `..` — returns 403.
- Returns 404 for `FileNotFound` / `NotDir` / `IsDir`.
- Enforces a 4 MB per-file cap (returns 413 above that).
- Guesses content-type from the extension via a small table.
- Adds `cache-control: public, max-age=300`.
- Gzip-compresses text-ish content types when the client sent
  `Accept-Encoding: gzip`.

## Comptime: `-Dpublic-dir`

```sh
zig build -Dpublic-dir=./public
./zig-out/bin/verve-server               # no --public-dir flag needed
curl http://127.0.0.1:8080/public/index.txt
```

At configure time `build.zig` walks the directory, copies every file
into a `WriteFiles` step, and emits a manifest:

```zig
// generated public_assets.zig
pub const Entry = struct {
    path: []const u8,
    bytes: []const u8,
    content_type: []const u8,
};

pub const entries: []const Entry = &.{
    .{ .path = "index.txt", .bytes = @embedFile("index.txt"), .content_type = "text/plain; charset=utf-8" },
    .{ .path = "style.css", .bytes = @embedFile("style.css"), .content_type = "text/css; charset=utf-8" },
};
```

The server imports this as `public_assets` and scans it after the
runtime path fails:

```zig
// src/server/main.zig:serveStatic
if (public_dir) |dir| {
    if (try tryServeFromDisk(...)) return;
}
for (public_assets.entries) |entry| {
    if (std.mem.eql(u8, entry.path, rel_path)) {
        try respondBuffered(..., entry.content_type, ..., entry.bytes);
        return;
    }
}
```

So the resolution order is **disk → embed → 404**.

## Why both?

The two modes serve different workflows:

- **Dev**: `zig build` doesn't re-walk public/, so edits to a CSS file
  show up immediately under `--public-dir ./public`. No rebuild.
- **Prod**: ship a single binary that includes its assets. `docker
  scratch` works. No runtime filesystem read required, no missing-file
  surprises.
- **Hybrid**: ship the binary with embedded defaults, allow ops to
  drop overrides in a deployment dir without rebuilding.

## Content-type table

In `src/server/main.zig:contentTypeFor`:

| Extension | Content-Type |
|---|---|
| `.css`   | `text/css; charset=utf-8` |
| `.html`  | `text/html; charset=utf-8` |
| `.ico`   | `image/x-icon` |
| `.js`    | `application/javascript` |
| `.json`  | `application/json` |
| `.png`   | `image/png` |
| `.svg`   | `image/svg+xml` |
| `.txt`   | `text/plain; charset=utf-8` |
| `.wasm`  | `application/wasm` |
| `.webp`  | `image/webp` |

Anything not listed gets `application/octet-stream`. Add rows directly
to the table when you need more.

For the comptime path, the same table runs at configure time (in
`build.zig:guessContentType`) so the bytes shipped already include a
correct content-type string.

## Path safety

Every path goes through the same check:

```zig
if (rel_path.len == 0 or rel_path[0] == '/' or std.mem.indexOf(u8, rel_path, "..") != null) {
    try renderError(gpa, request, .forbidden, "Invalid static asset path.");
    return;
}
```

- Empty paths (just `/public/`): 403.
- Absolute paths (`/public//etc/passwd` → `/etc/passwd` after prefix
  strip): 403.
- Any path component `..`: 403.

There's no symlink-following protection — if your `--public-dir` points
at a directory with a symlink out of tree, that's reachable. Mount
your asset dir as readonly with the contents you intend to serve.

## File size cap

4 MB hard cap; over that the server returns 413 Payload Too Large.
Set in `src/server/main.zig`:

```zig
const STATIC_MAX_SIZE: usize = 4 * 1024 * 1024;
```

For larger assets, you probably want a CDN. If you have to serve them
yourself, raise the constant and add a `respondStreaming` path so the
whole file doesn't sit in memory.

## Verifying the embed path

The repo has a dedicated test binary (`verve-server-embed`) that
always bakes `tests/public_fixture/`. The integration test
`-Dpublic-dir bakes files into the binary and serves them without
--public-dir` spawns this binary, hits `/public/hello.txt`, and
asserts the body.

You can reproduce manually:

```sh
zig build -Dpublic-dir=tests/public_fixture
./zig-out/bin/verve-server
curl -i http://127.0.0.1:8080/public/hello.txt
# HTTP/1.1 200 OK
# content-type: text/plain; charset=utf-8
# cache-control: public, max-age=300
# 
# static asset fixture
```

## Next

- [08 — Observability](08-observability.md) — `/health` + `/metrics` +
  request logging.
- [09 — Performance](09-performance.md) — gzip details, admission cap,
  thread pool.
