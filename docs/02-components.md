# 02 — Component model

A Verve page is a function that returns a tree of `Node` values. The
renderer walks the tree depth-first and streams escaped HTML to the
socket. No virtual DOM, no diffing, no macros.

## The two primitives

Both live in `src/core/node.zig`:

```zig
pub const Attr = struct {
    key: []const u8,
    value: []const u8,
};

pub const Node = struct {
    tag: []const u8,                   // "div", "h1", "input", ...
    attrs: []const Attr = &.{},
    children: []const Node = &.{},
    text: ?[]const u8 = null,          // body text (mutually exclusive with children for most uses)
    z_bind: ?[]const u8 = null,        // names the element for reactive updates
    z_on_click: ?[]const u8 = null,    // dispatches to wasm export by name
};
```

`Attr` and `Node` are both `pub`'d through `src/verve.zig` so user code
gets at them as `verve.Attr` / `verve.Node`.

## Render functions

Pages live in `src/app/components.zig`. They take a `*const Context`,
which carries the per-request `ArenaAllocator`:

```zig
pub fn home(ctx: *const verve.Context) !verve.Node {
    const alloc = ctx.alloc();
    const kids = try alloc.alloc(verve.Node, 2);
    kids[0] = .{ .tag = "h1", .text = "Verve" };
    kids[1] = .{ .tag = "p", .text = "Full-stack Zig web framework." };
    return .{ .tag = "main", .children = kids };
}
```

Three patterns matter here:

1. **Allocate `children` slices explicitly with `alloc.alloc`.** Don't
   use anonymous array literals (`&.{...}`) for runtime values — they
   live on the stack frame and dangle after the function returns. The
   linter won't catch this; it manifests as garbage in the rendered
   output.
2. **Comptime-constant attrs are fine inline.** `.attrs = &.{.{ .key
   = "class", .value = "card" }}` is OK because Zig promotes the
   literal to static storage. The moment any field is a runtime value
   (e.g. a duped string), allocate with `alloc.alloc(verve.Attr, N)`.
3. **`!verve.Node` return type.** Allocation can fail; surface it.

## Wrapping a body in the page shell

`components.page` adds `<html><head>` boilerplate and includes the JS
bridge `<script src="/verve.js">`:

```zig
fn renderHome(ctx: *const verve.Context) !verve.Node {
    const body = try components.home(ctx);
    return components.page(ctx, body);
}
```

The `page` helper is small — about 35 lines, including the embedded
CSS string. Copy and customize.

## How the renderer works

`src/core/renderer.zig`:

```zig
pub const Renderer = struct {
    pub fn render(w: *Writer, node: Node) Writer.Error!void {
        try w.print("<{s}", .{node.tag});
        for (node.attrs) |attr| {
            try w.print(" {s}=\"", .{attr.key});
            try escapeAttr(w, attr.value);
            try w.writeAll("\"");
        }
        // z-bind / z-on-click written as plain attrs (escapeAttr'd)
        if (node_mod.isVoidTag(node.tag)) {
            try w.writeAll(">");
            return;
        }
        try w.writeAll(">");
        if (node.text) |t| try escapeHtml(w, t);
        for (node.children) |child| try render(w, child);
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

## Streaming vs buffered

Verve's server renders into a `std.Io.Writer.Allocating` buffer first,
then sends the whole body in one fixed-length response (or compresses
to gzip when the client accepts it). The streaming variant —
`request.respondStreaming` — is used internally for SSE on `/events`
where you need indefinite-length chunked output.

For app code, you almost always want the buffered path. Streaming
adds chunk-encoder flushing complexity (see `flushBodyWriter` in
`src/server/main.zig`) that's a footgun unless you need it.

## Context lifetime

A `Context` is created once per request, holding an `ArenaAllocator`
that lives until the response is fully written. Everything you allocate
through `ctx.alloc()` is freed in one shot when the request ends — no
manual `defer`s needed inside render functions.

```zig
pub fn doStuff(ctx: *const verve.Context) !verve.Node {
    const alloc = ctx.alloc();
    const name = try alloc.dupe(u8, computeName());      // freed at end of request
    const kids = try alloc.alloc(verve.Node, 1);         // ditto
    kids[0] = .{ .tag = "span", .text = name };
    return .{ .tag = "div", .children = kids };
}
```

## Conditional and repeated content

There's no template DSL — you're writing Zig:

```zig
const link_kids = try alloc.alloc(verve.Node, items.len);
for (items, 0..) |item, i| {
    link_kids[i] = .{
        .tag = "a",
        .text = item.title,
        .attrs = &.{.{ .key = "href", .value = item.url }},
    };
}
const body = verve.Node{ .tag = "nav", .children = link_kids };
```

Conditionals are plain `if` / `switch`. `std.ArrayList(Node).empty`
works when you want incremental construction:

```zig
var kids: std.ArrayList(verve.Node) = .empty;
try kids.append(alloc, .{ .tag = "h1", .text = "Hi" });
if (user.is_admin) {
    try kids.append(alloc, .{ .tag = "a", .text = "Admin", .attrs = ... });
}
return .{ .tag = "main", .children = try kids.toOwnedSlice(alloc) };
```

## Escaping is automatic

Every `text` and every attribute `value` is escaped on its way out. You
never need to escape by hand on the server side. If you have a wasm
client emitting `innerHTML` strings directly, see
[`12-wasm-client.md`](12-wasm-client.md) for the matching helper.

## Next

- [03 — Actions](03-actions.md) — handling form / JSON POSTs.
- [05 — Reactivity](05-reactivity.md) — `z-bind` and `z-on-click` for
  client-side updates.
