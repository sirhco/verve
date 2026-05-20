//! Typed handle to a DOM node that survives hydration. The server-side
//! render emits `data-ref="<id>"` onto the node; the client-side runtime
//! exposes `verveQueryRef(id) -> ?Element` so WASM-side effects can
//! observe or mutate the live DOM node without scanning by class/id.
//!
//! `Tag` is a phantom comptime type for compile-time safety — e.g.
//! `NodeRef(Input)` can only be applied to nodes the framework knows
//! are `<input>`. Phase 1 ships a small `Tag` enum covering the most
//! common element types; richer typed-element bindings arrive with the
//! islands work in Phase 8.

const std = @import("std");

/// Compile-time tag identifying the expected element kind. The renderer
/// doesn't enforce it (any node can carry a ref) but typed `use:`
/// directives downstream can require a specific tag.
pub const Tag = enum {
    any,
    div,
    span,
    input,
    button,
    form,
    textarea,
    select,
    a,
    img,
    canvas,
    video,
    audio,
};

pub fn NodeRef(comptime tag: Tag) type {
    return struct {
        id: []const u8,
        pub const expected_tag: Tag = tag;

        const Self = @This();

        pub fn init(id: []const u8) Self {
            return .{ .id = id };
        }
    };
}

/// Render-time helper used by `Node.ref(noderef)` (which is in node.zig)
/// to push a `data-ref="<id>"` attribute onto a node. Kept here so the
/// node module doesn't need to import comptime tag machinery.
pub fn refAttrValue(comptime tag: Tag, ref: NodeRef(tag)) []const u8 {
    return ref.id;
}

/// Type erasure for use-directive: a function that runs on the client
/// once the element is mounted. Signature is intentionally minimal —
/// the directive resolves the DOM node itself via `verveQueryRef`.
pub const DirectiveFn = *const fn (id: []const u8) void;

test "NodeRef carries id and tag" {
    const ref: NodeRef(.input) = .init("email-field");
    try std.testing.expectEqualStrings("email-field", ref.id);
    try std.testing.expect(@TypeOf(ref).expected_tag == .input);
}
