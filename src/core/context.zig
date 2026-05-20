//! Per-render context. Owns an arena that is wiped at end of request.
//! Element factory methods allocate fresh `*Node` instances from the
//! arena so components can write HTML-shaped chains:
//!
//!     return ctx.div().class("page")
//!         .children(.{ ctx.h1("Hello") })
//!         .build();

const std = @import("std");
const node_mod = @import("node.zig");
const Signal = @import("signal.zig").Signal;

const Node = node_mod.Node;

pub const Context = struct {
    arena: *std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
    /// Optional process Io handle, populated by the server when rendering
    /// a request. Components that need to perform external I/O (HTTP, file)
    /// can pick this up. Tests and non-server callers may leave it null.
    io: ?std.Io = null,

    pub fn init(arena: *std.heap.ArenaAllocator) Context {
        return .{
            .arena = arena,
            .allocator = arena.allocator(),
        };
    }

    pub fn initWithIo(arena: *std.heap.ArenaAllocator, io: std.Io) Context {
        return .{
            .arena = arena,
            .allocator = arena.allocator(),
            .io = io,
        };
    }

    /// Allocate a Signal in the arena. Returned pointer is valid until the
    /// arena is reset/deinit.
    pub fn useSignal(self: *const Context, comptime T: type, initial: T) !*Signal(T) {
        const sig = try self.allocator.create(Signal(T));
        sig.* = Signal(T).init(initial);
        return sig;
    }

    /// Pass-through helper for components that want the arena allocator.
    pub fn alloc(self: *const Context) std.mem.Allocator {
        return self.allocator;
    }

    // ---- element factories ----------------------------------------------
    //
    // Each factory returns `*Node` so the call site can chain `.class()`,
    // `.children()`, etc. without intermediate `try`. Allocation failure
    // returns a shared poison node — the error surfaces at `.build()`.

    pub const FormOpts = struct {
        post: ?[]const u8 = null,
        get: ?[]const u8 = null,
        class: ?[]const u8 = null,
    };

    /// Generic escape hatch. Use for tags without a dedicated helper.
    pub fn el(ctx: *const Context, tag: []const u8) *Node {
        return node_mod.create(ctx.allocator, tag);
    }

    pub fn div(ctx: *const Context) *Node {
        return ctx.el("div");
    }

    pub fn span(ctx: *const Context) *Node {
        return ctx.el("span");
    }

    pub fn p(ctx: *const Context) *Node {
        return ctx.el("p");
    }

    pub fn h1(ctx: *const Context, t: []const u8) *Node {
        return ctx.el("h1").text(t);
    }

    pub fn h2(ctx: *const Context, t: []const u8) *Node {
        return ctx.el("h2").text(t);
    }

    pub fn h3(ctx: *const Context, t: []const u8) *Node {
        return ctx.el("h3").text(t);
    }

    pub fn h4(ctx: *const Context, t: []const u8) *Node {
        return ctx.el("h4").text(t);
    }

    pub fn a(ctx: *const Context, href: []const u8, t: []const u8) *Node {
        return ctx.el("a").href(href).text(t);
    }

    pub fn button(ctx: *const Context, label_text: []const u8) *Node {
        return ctx.el("button").text(label_text);
    }

    pub fn input(ctx: *const Context) *Node {
        return ctx.el("input");
    }

    pub fn form(ctx: *const Context, opts: FormOpts) *Node {
        const n = ctx.el("form");
        if (opts.post) |action| _ = n.attr("method", "post").attr("action", action);
        if (opts.get) |action| _ = n.attr("method", "get").attr("action", action);
        if (opts.class) |c| _ = n.class(c);
        return n;
    }

    pub fn ul(ctx: *const Context) *Node {
        return ctx.el("ul");
    }

    pub fn ol(ctx: *const Context) *Node {
        return ctx.el("ol");
    }

    pub fn li(ctx: *const Context) *Node {
        return ctx.el("li");
    }

    pub fn img(ctx: *const Context, src: []const u8, alt: []const u8) *Node {
        return ctx.el("img").src(src).alt(alt);
    }

    pub fn br(ctx: *const Context) *Node {
        return ctx.el("br");
    }

    pub fn hr(ctx: *const Context) *Node {
        return ctx.el("hr");
    }

    pub fn label(ctx: *const Context, for_id: []const u8, t: []const u8) *Node {
        return ctx.el("label").attr("for", for_id).text(t);
    }

    pub fn code(ctx: *const Context, t: []const u8) *Node {
        return ctx.el("code").text(t);
    }

    pub fn pre(ctx: *const Context) *Node {
        return ctx.el("pre");
    }

    pub fn nav(ctx: *const Context) *Node {
        return ctx.el("nav");
    }

    pub fn main_(ctx: *const Context) *Node {
        return ctx.el("main");
    }

    pub fn section(ctx: *const Context) *Node {
        return ctx.el("section");
    }

    pub fn header(ctx: *const Context) *Node {
        return ctx.el("header");
    }

    pub fn footer(ctx: *const Context) *Node {
        return ctx.el("footer");
    }

    pub fn article(ctx: *const Context) *Node {
        return ctx.el("article");
    }

    pub fn aside(ctx: *const Context) *Node {
        return ctx.el("aside");
    }

    pub fn strong(ctx: *const Context, t: []const u8) *Node {
        return ctx.el("strong").text(t);
    }

    pub fn em(ctx: *const Context, t: []const u8) *Node {
        return ctx.el("em").text(t);
    }

    pub fn small(ctx: *const Context, t: []const u8) *Node {
        return ctx.el("small").text(t);
    }

    pub fn textarea(ctx: *const Context) *Node {
        return ctx.el("textarea");
    }

    pub fn select(ctx: *const Context) *Node {
        return ctx.el("select");
    }

    pub fn option(ctx: *const Context, val: []const u8, t: []const u8) *Node {
        return ctx.el("option").value(val).text(t);
    }

    pub fn link(ctx: *const Context, rel: []const u8, href: []const u8) *Node {
        return ctx.el("link").attr("rel", rel).href(href);
    }

    pub fn meta(ctx: *const Context, key: []const u8, val: []const u8) *Node {
        return ctx.el("meta").attr(key, val);
    }

    pub fn title(ctx: *const Context, t: []const u8) *Node {
        return ctx.el("title").text(t);
    }

    pub fn style(ctx: *const Context, css: []const u8) *Node {
        return ctx.el("style").text(css);
    }

    pub fn script(ctx: *const Context, src: []const u8) *Node {
        return ctx.el("script").src(src);
    }
};

test "Context allocates signals in arena" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const ctx = Context.init(&arena);
    const sig = try ctx.useSignal(i32, 7);
    try std.testing.expectEqual(@as(i32, 7), sig.get());
    sig.set(8);
    try std.testing.expectEqual(@as(i32, 8), sig.get());
}

test "Context.div builds tag with class and child" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const ctx = Context.init(&arena);
    const node = try ctx.div().class("page")
        .children(.{ ctx.h1("hi") })
        .build();

    try std.testing.expectEqualStrings("div", node.tag);
    try std.testing.expectEqual(@as(usize, 1), node.attrs.items.len);
    try std.testing.expectEqualStrings("class", node.attrs.items[0].key);
    try std.testing.expectEqualStrings("page", node.attrs.items[0].value);
    try std.testing.expectEqual(@as(usize, 1), node.children_list.items.len);
    try std.testing.expectEqualStrings("h1", node.children_list.items[0].tag);
    try std.testing.expectEqualStrings("hi", node.children_list.items[0].text_content.?);
}

test "Context.form post sets method, action, class" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const ctx = Context.init(&arena);
    const node = try ctx.form(.{ .post = "/api/x", .class = "f" }).build();
    try std.testing.expectEqualStrings("form", node.tag);
    try std.testing.expectEqual(@as(usize, 3), node.attrs.items.len);
    try std.testing.expectEqualStrings("method", node.attrs.items[0].key);
    try std.testing.expectEqualStrings("post", node.attrs.items[0].value);
    try std.testing.expectEqualStrings("action", node.attrs.items[1].key);
    try std.testing.expectEqualStrings("/api/x", node.attrs.items[1].value);
    try std.testing.expectEqualStrings("class", node.attrs.items[2].key);
    try std.testing.expectEqualStrings("f", node.attrs.items[2].value);
}

test "Node.textInt formats integer into text_content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const ctx = Context.init(&arena);
    const node = try ctx.span().textInt(@as(i32, 42)).build();
    try std.testing.expectEqualStrings("42", node.text_content.?);
}
