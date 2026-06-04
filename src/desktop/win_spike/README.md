# WebView2 native-host spike

Proves the **native C++ host + thin Zig C-ABI** pattern (à la
[vercel-labs/zero-native](https://github.com/vercel-labs/zero-native/tree/main/src/platform))
as a replacement for the 4129-line pure-Zig hand-rolled COM backend in
`src/desktop/windows.zig`.

Design: `docs/superpowers/specs/2026-06-04-webview2-host-spike-design.md`.

## Files

| file | role |
|------|------|
| `host.h` | flat C ABI — the entire Zig↔native seam (~8 fns) |
| `webview2_host.cpp` | native host: Win32 window + WebView2, plain C++ COM handlers, **no WRL** |
| `spike.zig` | Zig driver: extern decls, bridge callback, message loop |
| `../../../vendor/webview2/` | vendored `WebView2.h`, `EventToken.h` shim, `WebView2Loader.dll` |

The C++ compiler generates correct COM vtables from `WebView2.h`; Zig never
counts an offset.

## Build (works on macOS — cross-compiles)

```sh
zig build win-spike
# -> zig-out/bin/verve-win-spike.exe + WebView2Loader.dll
```

Compiles under zig's bundled mingw clang with only the vendored header — no
Windows SDK, no WRL, no NuGet at build time. Key flags (`build.zig`):
`-fms-extensions -fno-exceptions -fno-rtti -DUNICODE`.

## Run (Windows)

1. Copy the whole `zig-out/bin/` folder to a Windows box (needs
   `verve-win-spike.exe` + `WebView2Loader.dll` together).
2. Requires the **WebView2 Runtime** (preinstalled on current Win10/11; else
   install the Evergreen bootstrapper from Microsoft).
3. Run `verve-win-spike.exe`.

### Success = these runtime milestones

- Window opens (900×640).
- Page renders: heading + "ping → Zig" button.
- On load, the `#log` box updates to **"Zig received: hello from JS on load"**
  — that text made a full round-trip: JS `postMessage` → C++ host → Zig
  callback → `ExecuteScript` → back into the DOM.
- Clicking **ping → Zig** updates `#log` with a fresh `ping <timestamp>`.
- A console window also prints `[zig] bridge received: ...` per message.
- Closing the window exits cleanly.

If all of that works, the native-host pattern is validated and the remaining
~59 `Window` backend methods (see the conformance list in
`src/desktop/window.zig`) are mechanical ports onto this seam.
