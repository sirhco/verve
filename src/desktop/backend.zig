//! Single source of truth for desktop backend selection.
//!
//! `window.zig`, `cookies.zig`, and `clipboard.zig` MUST all resolve the host
//! backend through `impl` here. They previously each had their own
//! `switch (os.tag)`; on Windows that diverged once a second backend existed:
//! `window.zig` honored the native-host opt-in while `cookies.zig`/`clipboard.zig`
//! hardcoded the legacy backend. A `Window` from one backend then handed its
//! opaque window pointer to a `CookieStore`/`Clipboard` that dispatched into the
//! OTHER backend, which dereferenced the foreign pointer — a segfault. Routing
//! every consumer through this one selection makes that mismatch impossible.
const builtin = @import("builtin");

/// The selected backend module. Only the taken switch prong is imported
/// (`builtin.os.tag` is comptime), so non-Windows builds never touch the
/// Windows backends and vice-versa.
///
/// Windows resolves to the native C++ WebView2 host (`windows_native.zig`,
/// backed by `win_native/webview2_host.cpp` behind a flat C ABI). The legacy
/// pure-Zig hand-rolled COM backend was deleted in the Bundle 9 cutover, so
/// there is no longer a fallback or a `verve_win_backend_native` opt-in.
pub const impl = switch (builtin.os.tag) {
    .macos => @import("macos.zig"),
    .windows => @import("windows_native.zig"),
    .linux => blk: {
        const use_gtk4 = detect: {
            const root = @import("root");
            if (@hasDecl(root, "desktop_options")) break :detect root.desktop_options.gtk4;
            break :detect false;
        };
        break :blk if (use_gtk4) @import("linux_gtk4.zig") else @import("linux.zig");
    },
    else => @compileError("verve.desktop: unsupported OS — only macOS, Windows, and Linux are wired today"),
};
