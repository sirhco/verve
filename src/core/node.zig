//! Recursive HTML node tree. Server iterates to serialize HTML;
//! client iterates to wire event listeners and signal bindings.

pub const Attr = struct {
    key: []const u8,
    value: []const u8,
};

pub const Node = struct {
    tag: []const u8,
    attrs: []const Attr = &.{},
    text: ?[]const u8 = null,
    z_bind: ?[]const u8 = null,
    z_on_click: ?[]const u8 = null,
    children: []const Node = &.{},
};

/// Void elements per HTML spec — no closing tag, no content.
pub fn isVoidTag(tag: []const u8) bool {
    const std = @import("std");
    const void_tags = [_][]const u8{
        "area", "base", "br",     "col",   "embed", "hr", "img", "input",
        "link", "meta", "source", "track", "wbr",
    };
    for (void_tags) |v| {
        if (std.mem.eql(u8, tag, v)) return true;
    }
    return false;
}
