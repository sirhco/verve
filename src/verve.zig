//! Verve — full-stack Zig web framework public API.
//!
//! Shared between native server build and wasm32-freestanding client build.
//! Anything imported here must compile in both targets, so this file avoids
//! std.Io / std.heap.page_allocator etc. Server-only or wasm-only helpers
//! live in their respective subtrees.

const node_mod = @import("core/node.zig");
const signal_mod = @import("core/signal.zig");
const context_mod = @import("core/context.zig");
const renderer_mod = @import("core/renderer.zig");

pub const Node = node_mod.Node;
pub const Attr = node_mod.Attr;
pub const Signal = signal_mod.Signal;
pub const Context = context_mod.Context;
pub const Renderer = renderer_mod.Renderer;
pub const escapeHtml = renderer_mod.escapeHtml;

test {
    _ = node_mod;
    _ = signal_mod;
    _ = context_mod;
    _ = renderer_mod;
}
