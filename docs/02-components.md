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
    z_bind_name: ?[]const u8 = null,
    z_on_click_action: ?[]const u8 = null,
    attrs: std.ArrayList(Attr) = .empty,
    children_list: std.ArrayList(*Node) = .empty,
    err: ?anyerror = null,

    pub fn class(self: *Node, val: []const u8) *Node;
    pub fn id(self: *Node, val: []const u8) *Node;
    pub fn href(self: *Node, val: []const u8) *Node;
    pub fn attr(self: *Node, key: []const u8, val: []const u8) *Node;
    pub fn attrFmt(self: *Node, key, comptime fmt, args) *Node;

    pub fn bind(self: *Node, signal_name: []const u8) *Node;
    pub fn onClick(self: *Node, action: []const u8) *Node;

    pub fn text(self: *Node, t: []const u8) *Node;
    pub fn textFmt(self: *Node, comptime fmt, args) *Node;
    pub fn textInt(self: *Node, n: anytype) *Node;

    // Variadic children — accepts an anonymous tuple of *Node, a slice
    // ([]*Node / []const *Node), or a single *Node. See below.
    pub fn children(self: *Node, args: anytype) *Node;

    pub fn build(self: *Node) !*Node;   // surfaces any deferred error
};
```

`Attr` and `Node` are both `pub`'d through `src/verve.zig` so user code gets
at them as `verve.Attr` / `verve.Node`.

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
ctx.h1(text) / ctx.h2(text) / ctx.h3(text)
ctx.a(href, text)
ctx.button(label)
ctx.input() / ctx.textarea() / ctx.select() / ctx.option(value, text)
ctx.form(.{ .post = "/api/...", .class = "..." })
ctx.img(src, alt) / ctx.br() / ctx.hr()
ctx.label(for_id, text) / ctx.code(text) / ctx.pre()
ctx.title(text) / ctx.meta(key, val) / ctx.style(css) / ctx.script(src)

ctx.el(tag)   // escape hatch for any tag without a dedicated helper
```

## Render functions

Pages live in `src/app/components.zig`. They take a `*const Context`,
which carries the per-request `ArenaAllocator`:

```zig
pub fn home(ctx: *const verve.Context) !*verve.Node {
    return ctx.main_().class("home").children(.{
        ctx.h1("Verve"),
        ctx.p().text("Full-stack Zig web framework."),
        ctx.p().children(.{ ctx.a("/counter", "Counter demo →") }),
    }).build();
}
```

Notes:

1. **Return `!*verve.Node`.** Allocation can fail; surface it via `try` at
   the terminus `.build()`.
2. **Children are passed as a tuple to `.children(.{ ... })`.** No
   per-child method call — the tree shape on screen matches the DOM shape.
3. **Dynamic strings live in the arena.** `.textInt(n)` and `.textFmt(...)`
   `allocPrint` into the arena and stash the result on `text_content`. No
   fixed buffers, no `dupe`.

## Wrapping a body in the page shell

`components.page` adds `<html><head>` boilerplate and includes the JS
bridge `<script src="/verve.js">`:

```zig
fn renderHome(ctx: *const verve.Context) !*verve.Node {
    const body = try components.home(ctx);
    return components.page(ctx, body);
}
```

## How the renderer works

`src/core/renderer.zig`:

```zig
pub const Renderer = struct {
    pub fn render(w: *Writer, node: *const Node) Writer.Error!void {
        try w.print("<{s}", .{node.tag});
        for (node.attrs.items) |a| {
            try w.print(" {s}=\"", .{a.key});
            try escapeAttr(w, a.value);
            try w.writeAll("\"");
        }
        // z-bind / z-on-click written as plain attrs (escapeAttr'd)
        if (node_mod.isVoidTag(node.tag)) {
            try w.writeAll(">");
            return;
        }
        try w.writeAll(">");
        if (node.text_content) |t| try escapeHtml(w, t);
        for (node.children_list.items) |c| try render(w, c);
        try w.print("</{s}>", .{node.tag});
    }
};
```

- **Void tags** (`br`, `img`, `input`, ...) get no closing tag.
- **`escapeHtml`** replaces `&` `<` `>` in element body text.
- **`escapeAttr`** also handles `"` since attribute values are
  double-quoted.
- The writer is `*std.Io.Writer`, so the renderer composes with
  whatever output stream you hand it — TCP socket for the server,
  `Allocating` buffer for tests, `fixed` buffer for in-memory checks.

## Context lifetime

A `Context` is created once per request, holding an `ArenaAllocator`
that lives until the response is fully written. Every `*Node` returned
by a factory is allocated in that arena and freed in one shot when the
request ends — no manual `defer`s inside render functions.

## Conditional and repeated content

You're writing Zig — `if`, `for`, `while` work as expected. Incremental
construction inside a loop uses the same `.children(.{ ... })` form, one
call per iteration:

```zig
const list = ctx.ul().class("nav");
for (items) |*item| {
    _ = list.children(.{
        ctx.li().children(.{ ctx.a(item.url, item.title) }),
    });
}
return list.build();
```

For pages that branch on data:

```zig
const root = ctx.main_().children(.{ ctx.h1("Hi") });
if (user.is_admin) {
    _ = root.children(.{ ctx.a("/admin", "Admin →") });
}
return root.build();
```

## Escaping is automatic

Every text content and every attribute value is escaped on its way out.
You never need to escape by hand on the server side. If you have a wasm
client emitting `innerHTML` strings directly, see
[`12-wasm-client.md`](12-wasm-client.md) for the matching helper.

## Next

- [03 — Actions](03-actions.md) — handling form / JSON POSTs.
- [05 — Reactivity](05-reactivity.md) — `z-bind` and `z-on-click` for
  client-side updates.
