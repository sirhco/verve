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
const root = @import("root");

/// Native-host backend opt-in. A desktop/template build that links the C++
/// WebView2 host declares `pub const verve_win_backend_native = true;` in its
/// ROOT source file. `@hasDecl` guards the access so test runners and bare
/// modules without the decl still compile (default: legacy).
pub const win_backend_native = @hasDecl(root, "verve_win_backend_native") and root.verve_win_backend_native;

/// The selected backend module. Only the taken switch prong is imported
/// (`builtin.os.tag` is comptime), so non-Windows builds never touch the
/// Windows backends and vice-versa.
pub const impl = switch (builtin.os.tag) {
    .macos => @import("macos.zig"),
    .windows => if (win_backend_native) @import("windows_native.zig") else @import("windows.zig"),
    .linux => @import("linux.zig"),
    else => @compileError("verve.desktop: unsupported OS — only macOS, Windows, and Linux are wired today"),
};
