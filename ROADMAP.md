# Verve — Roadmap / Remaining Work

Consolidated view of outstanding work. The framework's per-feature guides
each carry their own "Not yet built / Deferred" notes; this file gathers
them so the backlog is discoverable in one place. Desktop has its own
authoritative backlog at [`docs/11-desktop-roadmap.md`](docs/11-desktop-roadmap.md).

**Current:** v0.1.32 (pre-1.0; public APIs unstable). Status legend:
✅ done · 🟡 partial · ⏳ remaining · 🔒 host-gated (needs a real Win/Linux
host to verify) · 🍎 macOS-verifiable on a dev machine.

---

## Shipped through v0.1.32

The original 6-phase roadmap is substantially complete:

- ✅ **Client hydration + lifecycle** — per-island + route disposal
  (`verve_unmount_route` / `verve_unmount_island`), `MutationObserver`
  hydrate/dispose, per-`vid` owners, keyed reconciler.
- ✅ **Streaming SSR async** — `Resource` via `std.Io.async`; concurrent
  out-of-order Suspense drain (`streamRender(w, io, …)`).
- ✅ **Resource-state hydration** — `ctx.islandState` / `resourceFromState`
  / `islandStateValue` + `<script type="application/verve-state">`.
- ✅ **Typed island props** — `encodeProps`/`decodeProps` over the
  `serialize.zig` binary codec (panic-free decoder).
- ✅ **Chunk-runtime integration** — chunks decode props + read state, scope
  signals to their `vid`, dispatch `z-on-click` to chunk exports.
- ✅ **Multi-instance islands** — auto per-`vid` `z-bind`/`data-ref`
  namespacing (`name__v{vid}`).
- ✅ **Server-fn `_call`** — typed correlated callback (native; correlation
  infra in place).
- ✅ **i18n** — RTL direction + CLDR cardinal pluralization.
- ✅ **Desktop image clipboard (macOS)** — `Clipboard.writeImage`/`readImage`
  (PNG).

---

## Remaining

### Finishing partial phases

- ✅ **Server-fn `_call` wasm round-trip** — the browser path now
  serializes args, registers a correlated one-shot typed decoder, and
  posts with `x-verve-rid`; the server's `"rid"` echo routes the reply
  back to decode the typed value and fire `on_reply`. `app_client` is
  compiled into the wasm client; the client installs the hooks at hydrate.
  Demo: the `/counter` "call +" button.
  → `docs/03-actions.md`, `src/core/server_fn_gen.zig`, `src/client/main.zig`

- ⏳ **i18n lazy/streaming catalog loading** — every catalog ships in full
  today; per-locale split + on-demand load (build split + runtime merge, or
  a server endpoint) for very large translation sets.
  → [`docs/14-i18n.md:96`](docs/14-i18n.md)

### Island follow-ups

- ✅ **Keyed-list (`bindForEach`) multi-instance namespacing** —
  `registerForEach` now suffixes its `parent_bind` by the enclosing island's
  vid (matching the server-side `z-bind` suffix), so two instances of one
  component each reconcile only their own keyed list — no manual parent-bind
  disambiguation. Documented in `docs/15-islands.md`.
  → `src/client/runtime.zig` (`registerForEach`)

- ⏳🍎 **Client-side fetch of pending / local resources** (resource-state
  hydration phase 2) — a `loading` or `LocalResource` resolved client-side
  via the `server_fn_post` → `dispatchResponse` reply loop, vid-scoped. The
  resolved-at-SSR common case already avoids the round-trip.
  → [`docs/15-islands.md:389`](docs/15-islands.md) ("Deferred work")

- ✅ **Chunk-handler cross-component name collisions** — `z-on-click`
  dispatch now nests chunk exports by island `data-name` then export name,
  and resolves against the click target's enclosing `<verve-island>`, so two
  different island components may export the same handler name without
  colliding. Documented in `docs/15-islands.md`.
  → `src/bridge/verve.js` (registration + click delegate)

### Desktop backlog (P6)

Authoritative: [`docs/11-desktop-roadmap.md`](docs/11-desktop-roadmap.md).
Most are host-gated — no Windows/Linux hosts available; cross-compile is
clean but behavior is unvalidated.

- ⏳🔒 **Windows rich WinRT Toast** — `ToastNotificationManager` + AUMID +
  Start-menu shortcut. Balloon-tip path ships; rich Toast pending.
- ⏳🔒 **Updates apply (Win/Linux)** — Squirrel/MSIX (Win),
  AppImageUpdate (Linux). Check + macOS apply ship.
- ⏳🔒 **GTK4 + WebKitGTK 6.0** behind `-Dgtk4` — largest item; GTK3 +
  WebKitGTK 4.1 wired today. Needs Ubuntu 24 LTS / Fedora 41 validation.
- ⏳🍎 **Full a11y provider** — NSAccessibility / UIA / ATK roles + states
  beyond the current `setAccessibilityLabel`. Remaining gap is
  window-chrome semantics (web content + menus self-publish).
- ⏳🍎 **macOS `UNUserNotificationCenter` migration** — off the deprecated
  `NSUserNotification`; needs entitlements + an async permission prompt.
- ⏳🔒 **Image clipboard Win (`CF_DIB`) + Linux (`image/png` target)** —
  macOS (PNG) ships.
- ⏳🔒 **Live Win/Linux validation** — boot every code path on real hosts.
- ⏳ **Notarization automation (macOS)** — manual sequence documented;
  CI script pending.

---

## Notes

- **No single source of truth before this file.** Remaining work is otherwise
  only discoverable by grepping each guide's "Not yet built / Deferred"
  section; only desktop had a consolidated backlog. Keep this file in sync, or
  fold it into `docs/README.md`.
- **Genuinely out of scope (not bugs):** the `_post` fire-and-forget path,
  the `verve-spa` meta opt-out (unimplemented by design), and decimal-operand
  CLDR plural forms (integer counts only) are intentional, not pending.
