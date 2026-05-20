//! Mutable, arena-backed HTML node tree with fluent chain methods.
//! Server iterates to serialize HTML; client iterates to wire event
//! listeners and signal bindings.
//!
//! Each chain method returns `*Node` so calls compose left-to-right.
//! Allocation failures during a chain are absorbed onto `self.err` and
//! surfaced at the chain terminus via `build()`. This keeps the chain
//! free of `try` prefixes at every step.

const std = @import("std");

pub const Attr = struct {
    key: []const u8,
    value: []const u8,
};

pub const Node = struct {
    arena: ?std.mem.Allocator = null,
    tag: []const u8,
    text_content: ?[]const u8 = null,
    z_bind_name: ?[]const u8 = null,
    z_on_click_action: ?[]const u8 = null,
    attrs: std.ArrayList(Attr) = .empty,
    children_list: std.ArrayList(*Node) = .empty,
    err: ?anyerror = null,

    // ---- termination -----------------------------------------------------

    /// Surface any deferred error from the chain. Components terminate
    /// their tree with `.build()` so allocation failures propagate.
    pub fn build(self: *Node) !*Node {
        if (self.err) |e| return e;
        return self;
    }

    // ---- attributes ------------------------------------------------------

    pub fn attr(self: *Node, key: []const u8, val: []const u8) *Node {
        if (self.err != null) return self;
        self.attrs.append(self.arena.?, .{ .key = key, .value = val }) catch |e| {
            self.err = e;
        };
        return self;
    }

    pub fn attrFmt(self: *Node, key: []const u8, comptime fmt: []const u8, args: anytype) *Node {
        if (self.err != null) return self;
        const v = std.fmt.allocPrint(self.arena.?, fmt, args) catch |e| {
            self.err = e;
            return self;
        };
        return self.attr(key, v);
    }

    pub fn class(self: *Node, val: []const u8) *Node {
        return self.attr("class", val);
    }

    pub fn id(self: *Node, val: []const u8) *Node {
        return self.attr("id", val);
    }

    pub fn href(self: *Node, val: []const u8) *Node {
        return self.attr("href", val);
    }

    pub fn name(self: *Node, val: []const u8) *Node {
        return self.attr("name", val);
    }

    pub fn type_(self: *Node, val: []const u8) *Node {
        return self.attr("type", val);
    }

    pub fn placeholder(self: *Node, val: []const u8) *Node {
        return self.attr("placeholder", val);
    }

    pub fn required(self: *Node) *Node {
        return self.attr("required", "true");
    }

    pub fn autofocus(self: *Node) *Node {
        return self.attr("autofocus", "true");
    }

    pub fn value(self: *Node, val: []const u8) *Node {
        return self.attr("value", val);
    }

    pub fn src(self: *Node, val: []const u8) *Node {
        return self.attr("src", val);
    }

    pub fn alt(self: *Node, val: []const u8) *Node {
        return self.attr("alt", val);
    }

    // ---- a11y sugar ------------------------------------------------------

    pub fn role(self: *Node, val: []const u8) *Node {
        return self.attr("role", val);
    }

    pub fn ariaLabel(self: *Node, val: []const u8) *Node {
        return self.attr("aria-label", val);
    }

    pub fn ariaLive(self: *Node, val: []const u8) *Node {
        return self.attr("aria-live", val);
    }

    pub fn ariaCurrent(self: *Node, val: []const u8) *Node {
        return self.attr("aria-current", val);
    }

    pub fn ariaPressed(self: *Node, val: bool) *Node {
        return self.attr("aria-pressed", if (val) "true" else "false");
    }

    pub fn ariaExpanded(self: *Node, val: bool) *Node {
        return self.attr("aria-expanded", if (val) "true" else "false");
    }

    pub fn ariaHidden(self: *Node, val: bool) *Node {
        return self.attr("aria-hidden", if (val) "true" else "false");
    }

    // ---- bindings --------------------------------------------------------

    pub fn bind(self: *Node, signal_name: []const u8) *Node {
        if (self.err != null) return self;
        self.z_bind_name = signal_name;
        return self;
    }

    pub fn onClick(self: *Node, action: []const u8) *Node {
        if (self.err != null) return self;
        self.z_on_click_action = action;
        return self;
    }

    // ---- text ------------------------------------------------------------

    pub fn text(self: *Node, t: []const u8) *Node {
        if (self.err != null) return self;
        self.text_content = t;
        return self;
    }

    pub fn textFmt(self: *Node, comptime fmt: []const u8, args: anytype) *Node {
        if (self.err != null) return self;
        const v = std.fmt.allocPrint(self.arena.?, fmt, args) catch |e| {
            self.err = e;
            return self;
        };
        self.text_content = v;
        return self;
    }

    pub fn textInt(self: *Node, n: anytype) *Node {
        return self.textFmt("{d}", .{n});
    }

    // ---- children --------------------------------------------------------

    /// Append children to this node. Accepts:
    ///
    ///   .children(.{ node_a, node_b, node_c })  // anonymous tuple — most common
    ///   .children(slice_of_node_ptrs)           // []*Node or []const *Node
    ///   .children(single_node)                  // bare *Node
    ///
    /// Returns self so the chain continues. Allocation failures are recorded
    /// on `self.err` and surface at `.build()`.
    pub fn children(self: *Node, args: anytype) *Node {
        if (self.err != null) return self;
        const T = @TypeOf(args);
        const info = @typeInfo(T);
        switch (info) {
            .@"struct" => |s| {
                if (!s.is_tuple) {
                    @compileError("children(): struct arg must be an anonymous tuple, got " ++ @typeName(T));
                }
                inline for (s.fields) |f| {
                    self.appendOneChild(@field(args, f.name));
                    if (self.err != null) return self;
                }
                return self;
            },
            .pointer => |p| {
                if (p.size == .slice and p.child == *Node) {
                    for (args) |c| {
                        self.appendOneChild(c);
                        if (self.err != null) return self;
                    }
                    return self;
                }
                if (p.size == .one and p.child == Node) {
                    self.appendOneChild(args);
                    return self;
                }
                @compileError("children(): pointer arg must be *Node or []*Node, got " ++ @typeName(T));
            },
            else => @compileError("children() accepts a tuple of *Node, a slice of *Node, or a single *Node; got " ++ @typeName(T)),
        }
    }

    fn appendOneChild(self: *Node, c: *Node) void {
        if (c.err) |e| {
            self.err = e;
            return;
        }
        self.children_list.append(self.arena.?, c) catch |e| {
            self.err = e;
        };
    }
};

/// Shared sentinel returned by node factories when arena allocation fails.
/// Methods on a poisoned node short-circuit via the `err` check, so the
/// poison is never mutated after init — safe to share across threads.
pub var poison: Node = .{
    .tag = "verve_poison",
    .err = error.OutOfMemory,
};

pub fn create(arena: std.mem.Allocator, tag: []const u8) *Node {
    const node = arena.create(Node) catch return &poison;
    node.* = .{ .arena = arena, .tag = tag };
    return node;
}

/// Void elements per HTML spec — no closing tag, no content.
pub fn isVoidTag(tag: []const u8) bool {
    const void_tags = [_][]const u8{
        "area", "base", "br",     "col",   "embed", "hr", "img", "input",
        "link", "meta", "source", "track", "wbr",
    };
    for (void_tags) |v| {
        if (std.mem.eql(u8, tag, v)) return true;
    }
    return false;
}
