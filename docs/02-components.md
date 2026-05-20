# 02 — Component model

A Verve page is a function that returns a `*Node` tree. Components compose
with a fluent chain — methods on `Node` mutate the underlying arena-backed
tree and return `*Node` so every call links into the next. No virtual DOM,
no diffing, no macros.

## The two primitives

Both live in `src/core/node.zig`:

```zig
pub const Attr = struct {
    key: []const u8,
    value: []const u8,
};

pub const Node = struct {
    arena: ?std.mem.Allocator = null,
    tag: []const u8,
    text_content: ?[]const u8 = null,
    raw_inner: ?[]const u8 = null,
    content_type_override: ?[]const u8 = null,
    z_bind_name: ?[]const u8 = null,
    z_on_click_action: ?[]const u8 = null,
    redirect: ?verve.Redirect = null,
    outlet_content: ?*Node = null,
    attrs: std.ArrayList(Attr) = .empty,
    children_list: std.ArrayList(*Node) = .empty,
    err: ?anyerror = null,

    // attributes
    pub fn class(self: *Node, val: []const u8) *Node;
    pub fn id(self: *Node, val: []const u8) *Node;
    pub fn href(self: *Node, val: []const u8) *Node;
    pub fn attr(self: *Node, key, val) *Node;
    pub fn attrFmt(self: *Node, key, comptime fmt, args) *Node;

    // a11y sugar
    pub fn role(self: *Node, val: []const u8) *Node;
    pub fn ariaLabel(self: *Node, val: []const u8) *Node;
    pub fn ariaCurrent(self: *Node, val: []const u8) *Node;
    pub fn ariaPressed/Expanded/Hidden(self: *Node, val: bool) *Node;

    // legacy bindings (z-bind path)
    pub fn bind(self: *Node, signal_name: []const u8) *Node;
    pub fn onClick(self: *Node, action: []const u8) *Node;

    // text
    pub fn text(self: *Node, t: []const u8) *Node;
    pub fn textFmt(self: *Node, comptime fmt, args) *Node;
    pub fn textInt(self: *Node, n: anytype) *Node;

    // raw inner HTML / response control
    pub fn raw(self: *Node, bytes: []const u8) *Node;
    pub fn contentType(self: *Node, t: []const u8) *Node;

    // reactive NodeRef (typed handle the wasm client can resolve)
    pub fn ref(self: *Node, noderef: anytype) *Node;

    // children (tuple / slice / single)
    pub fn children(self: *Node, args: anytype) *Node;
    pub fn build(self: *Node) !*Node;
};
```

Failures inside a chain (allocation, formatting) are recorded on `self.err`
and short-circuit later methods. The terminus call `.build()` returns the
error if one was recorded, otherwise the pointer. This lets the chain stay
free of intermediate `try`.

## Adding children

`children()` is comptime-polymorphic over the input shape:

```zig
.children(.{ a, b, c })   // anonymous tuple — most common
.children(slice)          // []*Node or []const *Node
.children(node)           // single *Node (rarely needed; the tuple form is preferred)
```

Any other input type (e.g. `.children(42)`) raises a `@compileError` naming
the offending type and listing the accepted shapes. There is no `.child(x)`
— write `.children(.{ x })` for a single child.

## Element factories on Context

`src/core/context.zig` exposes one factory per common HTML tag so you
don't need to write `ctx.el("div")` for every node:

```zig
ctx.div() / ctx.span() / ctx.p() / ctx.ul() / ctx.li() / ctx.nav()
ctx.main_() / ctx.section() / ctx.header() / ctx.footer() / ctx.article()
ctx.h1(text) / ctx.h2(text) / ctx.h3(text) / ctx.h4(text)
ctx.a(href, text)
ctx.button(label)
ctx.input() / ctx.textarea() / ctx.select() / ctx.option(value, text)
ctx.form(.{ .post = "/api/...", .class = "..." })
ctx.actionForm(.{ .post = "/api/...", .class = "..." })  // form + auto CSRF
ctx.img(src, alt) / ctx.br() / ctx.hr()
ctx.label(for_id, text) / ctx.code(text) / ctx.pre()
ctx.title(text) / ctx.meta(key, val) / ctx.style(css) / ctx.script(src)

ctx.el(tag)            // escape hatch for any tag without a dedicated helper
ctx.raw(bytes)         // fragment node — emits bytes verbatim (sitemap.xml, OG SVG)
```

## Context surface

Beyond element factories, the context is the gateway to most framework
services per request:

```zig
// Path matching
ctx.param("slug")              // ?[]const u8 (route-captured)
ctx.location                   // ?*Location { path, raw_query, fragment }
ctx.activeClass(href, cls)     // "active" if location matches href

// Reactive primitives (see 05-reactivity)
ctx.useSignal(T, initial)
ctx.useEffect(state_ptr, fn)
ctx.nodeRef(.tag, "id")
ctx.provide(T, value) / ctx.use(T) / ctx.usePtr(T)

// Head accumulator (see "Head slots" below)
ctx.setTitle("…")
ctx.setTitleIfUnset("Verve")
ctx.metaTag(.{ .name = "…", .content = "…" })
ctx.linkTag(.{ .rel = "…", .href = "…" })
ctx.jsonLd("{…}")

// Server functions / outbound HTTP
ctx.serverFn(app.Actions.fn, args)
ctx.fetch(url, opts)

// Forms / auth
ctx.csrfField()                // hidden <input> with current CSRF token
ctx.actionForm(opts)           // <form> + auto-inject CSRF field

// Control flow
ctx.outlet()                   // nested-route slot
ctx.redirect("/login")
ctx.errorBoundary(inner, fallback)

// Assets
ctx.assetHref("style.css")     // → /public/style-<hash>.css
```

## Render functions

Pages live in `src/app/components.zig`. They take a `*verve.Context`,
which carries the per-request `ArenaAllocator` and per-request reactive
owner:

```zig
pub fn home(ctx: *const verve.Context) !*verve.Node {
    return ctx.main_().class("home").children(.{
        ctx.h1("Verve"),
        ctx.p().text("Full-stack Zig web framework."),
        ctx.p().children(.{ verve.link(ctx, "/counter", "Counter demo →", .{}) }),
    }).build();
}
```

Notes:

1. **Return `!*verve.Node`.** Allocation can fail; surface it via `try`
   at the terminus `.build()`.
2. **Children are passed as a tuple to `.children(.{ ... })`.** No
   per-child method call.
3. **Dynamic strings live in the arena.** `.textInt(n)` and
   `.textFmt(...)` `allocPrint` into the arena and stash the result.
4. **Route render fns take `*verve.Context` (mutable).** Components
   they invoke can take `*const Context` since they don't mutate
   per-request fields directly.

## Head slots

Components contribute to `<head>` through `ctx.setTitle / metaTag /
linkTag / jsonLd`. The framework's shell drains the accumulated
entries into `<head>` in a stable priority order (charset → title →
canonical → meta → link → script → JSON-LD), with replace-not-append
semantics so a child can override what a layout set:

```zig
pub fn workDetail(ctx: *const verve.Context, slug: []const u8) !*verve.Node {
    try ctx.setTitle(try std.fmt.allocPrint(ctx.alloc(), "Work — {s}", .{slug}));
    try ctx.metaTag(.{ .name = "description", .content = "Per-page meta." });
    try ctx.linkTag(.{ .rel = "canonical", .href = canonical });
    try ctx.metaTag(.{ .name = "og:title", .content = slug,
                       .is_property = true, .priority = 40 });
    try ctx.jsonLd(json_payload);

    return ctx.main_().children(.{ /* body */ }).build();
}
```

`components.page` calls `ctx.setTitleIfUnset("Verve")` so pages that
don't set a title fall back to the default.

## Slots (named children)

For components that accept multiple labeled children, `verve.Slot` +
`verve.SlotMap` provide a named-children API:

```zig
const Card = struct {
    pub const slots = struct {
        pub const header: verve.Slot = .{ .name = "header" };
        pub const body:   verve.Slot = .{ .name = "body" };
        pub const action: verve.Slot = .{ .name = "action" };
    };

    pub fn render(ctx: *const verve.Context, m: *const verve.SlotMap) !*verve.Node {
        return ctx.section().class("card").children(.{
            ctx.header().children(.{ m.find(slots.header) orelse ctx.span() }),
            ctx.div().class("body").children(.{ m.find(slots.body) orelse ctx.span() }),
            // … multi-fill via m.findAll(...) for action lists
        }).build();
    }
};
```

Caller fills slots before invoking the component:

```zig
var slots = verve.SlotMap.init(ctx.alloc());
try slots.fill(Card.slots.header, ctx.h2("Hello"));
try slots.fill(Card.slots.body,   ctx.p().text("Greetings."));
const card = try Card.render(ctx, &slots);
```

## NodeRef — typed DOM handle

```zig
const ref = ctx.nodeRef(.input, "email-field");

return ctx.input().type_("email").ref(ref).required();
```

Renderer emits `data-ref="email-field"`. Client-side
`verveQueryRef("email-field")` returns the live element.

## Wrapping a body in the page shell

`components.page` adds `<html><head>` boilerplate, drains
`ctx.head`, and includes the JS bridge `<script src="/verve.js">`:

```zig
fn renderHome(ctx: *verve.Context) !*verve.Node {
    const body = try components.home(ctx);
    return components.page(ctx, body);
}
```

## How the renderer works

`src/core/renderer.zig` walks the tree depth-first:

- `__outlet__` placeholders expand into `node.outlet_content`
  (nested-route slot).
- `__redirect__` sentinels render to nothing; the server intercepts
  the redirect before it reaches the renderer.
- Empty-tag fragments emit `raw_inner` (or children) verbatim.
- Regular tags emit `<tag attr1=… attr2=…>…children…</tag>`, with
  void tags omitting the close tag.
- `escapeHtml` replaces `& < >` in element body text.
- `escapeAttr` also handles `"` since attribute values are
  double-quoted.
- `raw_inner` (set via `.raw(bytes)`) bypasses escaping — use for
  inline `<script>` bodies or pre-rendered SVG.

The writer is `*std.Io.Writer`, so the renderer composes with
whatever output stream you hand it — TCP socket for the server,
`Allocating` buffer for tests, `fixed` buffer for in-memory checks.

## Non-HTML responses

The fragment idiom (`ctx.raw(bytes)` with `.contentType(...)`)
emits the bytes verbatim and instructs the server to use the
specified Content-Type. Useful for sitemap.xml, RSS/Atom, SVG OG
images:

```zig
fn renderSitemap(ctx: *verve.Context) !*verve.Node {
    return ctx.raw(sitemap_xml).contentType("application/xml").build();
}
```

## Context lifetime

A `Context` is created once per request, holding an `ArenaAllocator`
that lives until the response is fully written. Every `*Node` returned
by a factory is allocated in that arena and freed in one shot when the
request ends — no manual `defer`s inside render functions.

The reactive `Owner` follows the same lifecycle: signals, effects,
provided DI values created during render are all reclaimed when the
arena disposes.

## Conditional and repeated content

You're writing Zig — `if`, `for`, `while` work as expected:

```zig
const list = ctx.ul().class("nav");
for (items) |*item| {
    _ = list.children(.{
        ctx.li().children(.{ ctx.a(item.url, item.title) }),
    });
}
return list.build();
```

For data-driven branches, prefer the helper:

```zig
verve.show(ctx, user.is_admin, admin_panel, null);
verve.forEach(ctx, Item, items, &state, keyFn, renderFn);
```

The helpers emit stable `data-vkey`/`data-vlink` annotations the
client reconciler will use once Phase 8 hydration lands.

## Escaping is automatic

Every text content and every attribute value is escaped on its way
out. You never need to escape by hand on the server side. The
exceptions:

- `.raw(bytes)` opts out (e.g. inline scripts you fully control).
- `ctx.jsonLd(json)` emits the JSON verbatim — caller is responsible
  for valid JSON.

## Next

- [03 — Actions](03-actions.md) — form / JSON POST handling.
- [05 — Reactivity](05-reactivity.md) — Owner, Signal, Effect, Store.
- [13 — Security](13-security.md) — CSRF / CSP / Origin checks.
