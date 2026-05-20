//! Per-render context. Owns an arena that is wiped at end of request.
//! Element factory methods allocate fresh `*Node` instances from the
//! arena so components can write HTML-shaped chains:
//!
//!     return ctx.div().class("page")
//!         .children(.{ ctx.h1("Hello") })
//!         .build();

const std = @import("std");
const node_mod = @import("node.zig");
const signal_mod = @import("signal.zig");
const effect_mod = @import("effect.zig");
const owner_mod = @import("owner.zig");
const noderef_mod = @import("noderef.zig");
const context_di = @import("context_di.zig");
const head_mod = @import("head.zig");
const fetch_mod = @import("fetch.zig");
const request_meta_mod = @import("request_meta.zig");
const location_mod = @import("location.zig");

const Node = node_mod.Node;
const Signal = signal_mod.Signal;
const Owner = owner_mod.Owner;
const Effect = effect_mod.Effect;
const RequestMeta = request_meta_mod.RequestMeta;
const Location = location_mod.Location;

/// Looks up a hashed asset URL for a public-asset path. Phase 0 plumbs
/// this as an opaque function pointer + state so the context module
/// stays decoupled from build-time asset generation; the server module
/// supplies an implementation that consults the embedded manifest.
/// `arena` is the per-request allocator the resolver may format into;
/// returned slice lives until end of request.
pub const AssetResolver = struct {
    state: *const anyopaque,
    lookup: *const fn (state: *const anyopaque, path: []const u8, arena: std.mem.Allocator) std.mem.Allocator.Error!?[]const u8,
};

pub const Context = struct {
    arena: *std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
    /// Optional process Io handle, populated by the server when rendering
    /// a request. Components that need to perform external I/O (HTTP, file)
    /// can pick this up. Tests and non-server callers may leave it null.
    io: ?std.Io = null,
    /// Captured path parameters from the matched route. Set by the server
    /// before invoking the render function; empty for routes without
    /// parameter segments. Slices point into the request path buffer.
    params: *const std.StringHashMapUnmanaged([]const u8) = &empty_params,
    /// Current URL view (path, query, fragment). Populated by the server.
    /// Field is a pointer so the server can hand out per-request location
    /// data without invalidating the Context literal between requests.
    location: ?*Location = null,
    /// Request header snapshot (cookies, Accept-Language, User-Agent, ...).
    /// Null during tests or library use without a live HTTP request.
    request_meta: ?*const RequestMeta = null,
    /// Asset path → hashed-URL resolver. Null when no resolver was wired,
    /// in which case `assetHref` returns the raw `/public/<name>` path
    /// (unhashed fallback).
    asset_resolver: ?*const AssetResolver = null,
    /// Reactive ownership scope for this render. Signals and effects
    /// created via `ctx.useSignal` / `ctx.useEffect` register with this
    /// owner; the server disposes it at end of request. Null in test
    /// contexts that don't need reactivity.
    owner: ?*Owner = null,
    /// Per-request `<head>` accumulator. Components push title, meta,
    /// link, json-ld entries here during render; the shell drains them
    /// in priority order before emitting the body.
    head: ?*head_mod.Head = null,
    /// Current CSRF token (base64). Populated by the server before
    /// invoking render; `ctx.csrfField()` emits a matching hidden form
    /// input. Empty when the framework couldn't initialize a token.
    csrf_token: []const u8 = "",
    /// Per-request CSP nonce. Stamped onto inline scripts/styles and
    /// echoed in the response's Content-Security-Policy header.
    csp_nonce: []const u8 = "",

    /// Shared empty StringHashMap exposed as the default `params` pointer
    /// so the field is always dereferenceable.
    var empty_params: std.StringHashMapUnmanaged([]const u8) = .empty;

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

    /// Convenience accessor for a captured path parameter. Returns null
    /// when the route did not declare `:name`.
    pub fn param(ctx: *const Context, name: []const u8) ?[]const u8 {
        return ctx.params.get(name);
    }

    /// Hashed-asset URL for a public-asset path. When no resolver was
    /// wired (or the path is unknown), falls back to the unhashed URL —
    /// safe for development and for routes that haven't built a manifest.
    pub fn assetHref(ctx: *const Context, path: []const u8) ![]const u8 {
        if (ctx.asset_resolver) |res| {
            if (try res.lookup(res.state, path, ctx.allocator)) |hashed| return hashed;
        }
        return std.fmt.allocPrint(ctx.allocator, "/public/{s}", .{path});
    }

    /// Returns `active_class` when `href` matches the current location
    /// path (trailing slash normalized), otherwise an empty string. Used
    /// for nav highlight without forcing every component to plumb the
    /// current path through props.
    pub fn activeClass(ctx: *const Context, href: []const u8, active_class: []const u8) []const u8 {
        const loc = ctx.location orelse return "";
        return if (loc.isActive(href)) active_class else "";
    }

    /// Render-time error boundary. If `inner` accumulated an allocation
    /// or builder error during its chain, the boundary substitutes
    /// `fallback` instead. Phase 1 will extend this to catch render-time
    /// (writer-side) errors and to expose a reactive error signal.
    pub fn errorBoundary(ctx: *const Context, inner: *Node, fallback: *Node) *Node {
        _ = ctx;
        if (inner.err != null) return fallback;
        return inner;
    }

    /// Allocate a Signal in the arena. Returned pointer is valid until the
    /// arena is reset/deinit. When the Context has an owner the signal's
    /// subscriber list is allocated under the owner's arena; otherwise it
    /// falls back to the request arena.
    pub fn useSignal(self: *const Context, comptime T: type, initial: T) !*Signal(T) {
        const sig = try self.allocator.create(Signal(T));
        const sub_alloc = if (self.owner) |o| o.allocator() else self.allocator;
        sig.* = Signal(T).init(initial, sub_alloc);
        return sig;
    }

    /// Register a reactive effect on the current owner. The effect runs
    /// eagerly once to collect dependencies, then again whenever any
    /// signal it read changes. Disposing the owner cleans it up.
    pub fn useEffect(
        self: *const Context,
        ctx_ptr: anytype,
        comptime f: fn (@TypeOf(ctx_ptr)) void,
    ) !*Effect {
        const owner = self.owner orelse return error.NoOwner;
        return effect_mod.createEffect(owner, ctx_ptr, f);
    }

    /// Allocate a typed NodeRef in the arena. The returned handle is
    /// applied to a `Node` via `.ref(noderef)` and resolved on the
    /// client by `verveQueryRef("<id>")`. Ids must be unique within a
    /// rendered page.
    pub fn nodeRef(
        self: *const Context,
        comptime tag: noderef_mod.Tag,
        id: []const u8,
    ) noderef_mod.NodeRef(tag) {
        _ = self;
        return noderef_mod.NodeRef(tag).init(id);
    }

    /// Store a typed value on the current owner. Descendant components
    /// resolve it via `ctx.use(T)`. Errors out when no owner is wired.
    pub fn provide(self: *const Context, comptime T: type, value: T) !void {
        const owner = self.owner orelse return error.NoOwner;
        try context_di.provide(owner, T, value);
    }

    /// Look up a previously-provided value of type T. Walks the owner
    /// chain from the current scope upward; returns null when nothing
    /// matches.
    pub fn use(self: *const Context, comptime T: type) ?T {
        const owner = self.owner orelse return null;
        return context_di.use(owner, T);
    }

    /// Pointer variant of `use` — mutable handle into the stored value.
    pub fn usePtr(self: *const Context, comptime T: type) ?*T {
        const owner = self.owner orelse return null;
        return context_di.usePtr(owner, T);
    }

    // ---- head helpers ----------------------------------------------------
    //
    // Each helper pushes into `ctx.head` (replace-not-append for title and
    // meta). The shell calls `ctx.head.render(...)` before emitting the
    // body so entries arrive in priority order regardless of which
    // component contributed them.

    /// Set the page title. Last writer wins, so a layout can set a
    /// default and any child component can override. (`title` itself
    /// is taken by the element factory that builds `<title>` nodes.)
    pub fn setTitle(self: *const Context, t: []const u8) !void {
        const h = self.head orelse return error.NoHead;
        h.setTitle(t);
    }

    /// Layout-friendly default: only sets the title when no prior
    /// `setTitle` has been called. Pages that want to override should
    /// call `ctx.setTitle("...")` themselves.
    pub fn setTitleIfUnset(self: *const Context, t: []const u8) !void {
        const h = self.head orelse return error.NoHead;
        h.setTitleIfUnset(t);
    }

    /// Add or replace a `<meta name=...>` entry.
    pub fn metaTag(self: *const Context, opts: head_mod.Meta) !void {
        const h = self.head orelse return error.NoHead;
        try h.meta(opts);
    }

    /// Add a `<link rel=... href=...>` entry. Use `canonical` for the
    /// page's canonical URL; for stylesheets prefer `ctx.assetHref` to
    /// route through cache-busted asset URLs.
    pub fn linkTag(self: *const Context, opts: head_mod.Link) !void {
        const h = self.head orelse return error.NoHead;
        try h.link(opts);
    }

    /// Append a JSON-LD `<script type=application/ld+json>` block.
    pub fn jsonLd(self: *const Context, json: []const u8) !void {
        const h = self.head orelse return error.NoHead;
        try h.jsonLd(json);
    }

    /// Server-side outbound HTTP. Body lives in the request arena and is
    /// freed at end of render. Wasm-client builds return
    /// `error.UnsupportedOnClient` — use a Server Function (Phase 3+)
    /// for client-side outbound work.
    pub fn fetch(self: *const Context, url: []const u8, opts: fetch_mod.FetchOptions) !fetch_mod.FetchResponse {
        return fetch_mod.fetch(self.allocator, url, opts);
    }

    /// Build a hidden `<input>` carrying the current CSRF token. Add
    /// this to every `<form>` that posts to an Action; the server-side
    /// `api_handler` rejects POST requests whose form field doesn't
    /// match the `__verve_csrf` cookie.
    pub fn csrfField(self: *const Context) *Node {
        return self.el("input")
            .type_("hidden")
            .name("__csrf")
            .value(self.csrf_token);
    }

    /// `<ActionForm>` analog. Builds a `<form method=post action=...>`
    /// pre-wired with a hidden CSRF field. Components add their own
    /// `<input>` fields via `.children(...)`. Progressive enhancement
    /// (client-side dispatch via `action.dispatch`) lands with the
    /// island runtime; for now the form posts native HTML.
    pub fn actionForm(self: *const Context, opts: FormOpts) *Node {
        const n = self.form(opts);
        return n.children(.{self.csrfField()});
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

    /// Fragment node — no tag wrapper, emits the given bytes verbatim.
    /// Use for non-HTML page responses (sitemap.xml, feed.xml, OG SVG).
    /// Pair with `.contentType("application/xml")` on the same node so the
    /// server emits the correct Content-Type header.
    pub fn raw(ctx: *const Context, bytes: []const u8) *Node {
        const n = node_mod.create(ctx.allocator, "");
        return n.raw(bytes);
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

test "Context.param returns captured path parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var params: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer params.deinit(std.testing.allocator);
    try params.put(std.testing.allocator, "slug", "hello");

    var ctx = Context.init(&arena);
    ctx.params = &params;
    try std.testing.expectEqualStrings("hello", ctx.param("slug").?);
    try std.testing.expect(ctx.param("missing") == null);
}

test "Context.activeClass returns class when href matches location" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var loc = Location.parse("/work/abc");
    var ctx = Context.init(&arena);
    ctx.location = &loc;
    try std.testing.expectEqualStrings("nav-active", ctx.activeClass("/work/abc", "nav-active"));
    try std.testing.expectEqualStrings("", ctx.activeClass("/other", "nav-active"));
}

test "Context.errorBoundary swaps to fallback when inner has err" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const ctx = Context.init(&arena);

    // Inner with an error in the chain.
    const bad = ctx.div();
    bad.err = error.OutOfMemory;
    const fallback = ctx.div().class("fb");

    const result = ctx.errorBoundary(bad, fallback);
    try std.testing.expect(result == fallback);

    // Inner without error returns itself.
    const good = ctx.div().class("ok");
    const result2 = ctx.errorBoundary(good, fallback);
    try std.testing.expect(result2 == good);
}

test "Context.assetHref falls back to /public/<name> without resolver" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const ctx = Context.init(&arena);
    const href = try ctx.assetHref("style.css");
    try std.testing.expectEqualStrings("/public/style.css", href);
}

test "Context.assetHref uses resolver when wired" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const HashedLookup = struct {
        fn lookup(state: *const anyopaque, path: []const u8, alloc: std.mem.Allocator) std.mem.Allocator.Error!?[]const u8 {
            _ = state;
            _ = alloc;
            if (std.mem.eql(u8, path, "style.css")) return "/public/style-a1b2c3d4.css";
            return null;
        }
    };
    var unused: u8 = 0;
    const resolver: AssetResolver = .{
        .state = @as(*const anyopaque, @ptrCast(&unused)),
        .lookup = HashedLookup.lookup,
    };

    var ctx = Context.init(&arena);
    ctx.asset_resolver = &resolver;
    try std.testing.expectEqualStrings(
        "/public/style-a1b2c3d4.css",
        try ctx.assetHref("style.css"),
    );
    // Unknown asset falls back to the raw path.
    try std.testing.expectEqualStrings(
        "/public/unknown.js",
        try ctx.assetHref("unknown.js"),
    );
}
