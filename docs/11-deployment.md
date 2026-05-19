# 11 — Deployment

The runnable artifact is a single statically-linked binary. No
shared libs, no interpreter, no `node_modules`. That makes deployment
mostly mechanical.

## Container

A scratch Dockerfile is six lines:

```dockerfile
FROM alpine:3.20 AS build
RUN apk add --no-cache zig
WORKDIR /app
COPY . .
RUN zig build -Doptimize=ReleaseSafe -Dpublic-dir=./public

FROM scratch
COPY --from=build /app/zig-out/bin/verve-server /verve-server
EXPOSE 8080
ENTRYPOINT ["/verve-server"]
```

Notes:

- `-Doptimize=ReleaseSafe` keeps Zig's runtime checks; switch to
  `-Doptimize=ReleaseFast` for max throughput (no overflow checks).
- `-Dpublic-dir` bakes assets in so the scratch image needs nothing else.
- `EXPOSE 8080` is documentation only; the actual binding is
  controlled by `--host` / `--port` flags or `LISTEN_FDS`.

## systemd: socket activation via `LISTEN_FDS`

systemd can pre-open the listening socket and hand it to Verve via
file descriptor 3. The binary picks it up automatically.

`/etc/systemd/system/verve.socket`:

```ini
[Unit]
Description=Verve listening socket

[Socket]
ListenStream=0.0.0.0:8080
NoDelay=yes
KeepAlive=yes

[Install]
WantedBy=sockets.target
```

`/etc/systemd/system/verve.service`:

```ini
[Unit]
Description=Verve server
Requires=verve.socket
After=verve.socket

[Service]
Type=simple
ExecStart=/usr/local/bin/verve-server
Restart=on-failure
RestartSec=1
# Optional hardening:
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
```

Then:

```sh
systemctl daemon-reload
systemctl enable --now verve.socket
systemctl status verve.socket
journalctl -u verve.service -f
```

Verve reads the `LISTEN_FDS` environment variable on startup:

```zig
// src/server/main.zig:openListenSocket
if (init.environ_map.get("LISTEN_FDS")) |raw| {
    const count = std.fmt.parseInt(u32, raw, 10) catch return error.InvalidListenFds;
    if (count >= 1) {
        log.info("adopting fd 3 as listening socket (LISTEN_FDS={d})", .{count});
        return .{
            .socket = .{ .handle = 3, .address = .{ .ip4 = std.Io.net.Ip4Address.unspecified(0) } },
            .options = {},
        };
    }
}
```

When that path runs, `--host` and `--port` are ignored — the socket
is what systemd hands you.

The framework startup banner shows which mode it's in:

```
info(verve): adopting fd 3 as listening socket (LISTEN_FDS=1)
info(verve): listening on inherited fd 3 (LISTEN_FDS)
```

vs. the standard:

```
info(verve): listening on http://0.0.0.0:8080
```

## Signal handling

Verve handles `SIGINT` and `SIGTERM`:

```zig
fn onShutdownSignal(sig: std.posix.SIG) callconv(.c) void {
    std.debug.print("\n[verve] received SIGTERM, shutting down (served {d} requests)\n", ...);
    std.process.exit(0);
}
```

Two practical implications:

- `kill -TERM <pid>` and `Ctrl-C` both exit cleanly with code 0.
- In-flight requests are abandoned. There's no drain timer today. If
  you need bound-time graceful shutdown, the worker pool needs a
  shutdown flag the broadcaster threads observe — see the WS
  `streamWebSocket` handler for the pattern.

## Reverse proxy

Verve speaks plain HTTP/1.1. For TLS, sit it behind something else:

- **nginx**: `proxy_pass http://127.0.0.1:8080/;` plus
  `Connection "upgrade"` + `Upgrade $http_upgrade` for WebSocket.
- **Caddy**: `reverse_proxy 127.0.0.1:8080` with WS upgrade
  recognized automatically.
- **fly.io**: bind to `:8080` (Fly handles TLS + load balancing).
- **Cloudflare Tunnel**: `cloudflared tunnel --url http://127.0.0.1:8080`.

Any of these will gzip-compress text responses on your behalf — once
they do, you can disable Verve's gzip by editing
`src/server/gzip.zig:shouldCompress` to return false (saves CPU on
the application server).

## Binding to public interfaces

```sh
./zig-out/bin/verve-server --host 0.0.0.0 --port 80
```

Port 80 / 443 typically need elevated privileges. Options:

- Run behind a reverse proxy on `127.0.0.1:8080` (recommended).
- Use `setcap 'cap_net_bind_service=+ep' /usr/local/bin/verve-server`
  to grant the binary just the bind privilege.
- Run via systemd-socket-activation as above (systemd holds the
  socket, Verve never needs root).

## Resource limits

- `--workers N` caps concurrent connections; pair with `ulimit -n`
  high enough that the kernel doesn't hit fd exhaustion before the
  admission cap kicks in.
- `--body-limit SIZE` caps memory per request body. Default 1 MB.
- Static files are bounded by `STATIC_MAX_SIZE` (4 MB).
- Each connection allocates `READ_BUF_SIZE + WRITE_BUF_SIZE` (64 KB
  each = 128 KB). At `--workers 1024` that's ~130 MB of buffers — fine
  on any modern host.

## Logs

`std.log.scoped(.verve)` writes to stderr. Under systemd that flows
into the journal automatically; under Docker it becomes
`docker logs`. There's no log rotation built in — let the platform
handle it (journald, Docker's json-file driver, cloud log shippers).

## Zero-downtime restarts

Today: hand off via systemd socket activation. systemd holds the
listening socket; restarts of the service don't drop the socket.

Tomorrow (when implemented): a SIGHUP that triggers binary replacement,
or fork-and-exec via systemd `Type=notify`. Not in the framework yet.

## Health checks

Use `/health` for both liveness and readiness:

```yaml
# Kubernetes
livenessProbe:
  httpGet:
    path: /health
    port: 8080
  periodSeconds: 10
  failureThreshold: 3
readinessProbe:
  httpGet:
    path: /health
    port: 8080
  periodSeconds: 5
```

The handler runs in the same thread pool as every other request, so
under admission saturation it'll get a 503 — which is the right
liveness signal anyway (probe failures should mirror real traffic).

## Next

- [12 — WASM client](12-wasm-client.md) — the wasm-side details that
  matter for production (binary size, allocator, escape).
- Back to [the index](README.md).
