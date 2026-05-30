//! HTML serializer. Streams Node tree to any Io.Writer.

const std = @import("std");
const Writer = std.Io.Writer;
const node_mod = @import("node.zig");
const Context = @import("context.zig").Context;
const Node = node_mod.Node;
const stream_context = @import("stream_context.zig");
const Registry = stream_context.Registry;
const Slot = stream_context.Slot;

/// Per-render CSP nonce. The server sets this before serialization
/// so the renderer can stamp `nonce="…"` on every emitted `<script>`
/// / `<style>` tag that doesn't already carry one — required when
/// the response's CSP uses `'strict-dynamic'` (the framework default).
///
/// Empty string disables auto-stamping.
pub threadlocal var current_nonce: []const u8 = "";

pub const Renderer = struct {
    /// Phase 14B — chunked render that flushes the shell first, then
    /// drains every Suspense boundary that registered a continuation.
    /// `reg` is wired through `stream_context.current` for the duration
    /// of the call so deeply-nested `suspense()` invocations can pick
    /// up the slot allocator without threading the registry through
    /// every closure.
    ///
    /// Output shape per draining continuation:
    ///   <template id="verve-vs-{id}">{real content}</template>
    ///   <script>verveSwap({id})</script>
    ///
    /// The script tag carries no nonce by default — server callers
    /// that run under a strict CSP should stamp `current_nonce` before
    /// invoking; the inline script then picks the nonce up the same
    /// way every other emitted script does.
    pub fn streamRender(
        w: *Writer,
        io: std.Io,
        node: *const Node,
        reg: *Registry,
    ) Writer.Error!void {
        const prev = stream_context.current;
        stream_context.current = reg;
        defer stream_context.current = prev;

        try render(w, node);

        const slots = reg.pending();
        if (slots.len == 0) return;

        // Tag carried back from a worker: the id of the slot whose
        // resources finished awaiting. Workers only block on futures
        // (via Resolver.awaitFn → Resource.awaitFuture), staging the
        // result; NO Signal mutation / arena alloc / node render runs
        // off-thread. The main thread (below) applies the staged
        // results and re-renders in COMPLETION order.
        const U = union(enum) { done: u32 };

        // Allocate the select queue buffer. On OOM, fall back to a
        // sequential drain so correctness never depends on the
        // concurrent path being available.
        const buf = reg.allocator.alloc(U, slots.len) catch
            return drainSequential(w, io, slots);

        var select = std.Io.Select(U).init(io, buf);
        for (slots) |slot| {
            select.async(.done, resolveSlot, .{ io, slot });
        }

        // Emit one boundary per completed await, in completion order.
        var i: usize = 0;
        while (i < slots.len) : (i += 1) {
            const u = select.await() catch break;
            const id = u.done;
            const slot = findSlot(slots, id) orelse continue;
            try emitSlot(w, slot);
        }
    }

    pub fn render(w: *Writer, node: *const Node) Writer.Error!void {
        // Outlet placeholder for nested routing — expand into the
        // child route's rendered tree (or emit nothing when no child
        // matched).
        if (std.mem.eql(u8, node.tag, "__outlet__")) {
            if (node.outlet_content) |c| try render(w, c);
            return;
        }
        // Redirect sentinel — never renders to HTML; the server is
        // expected to intercept it before reaching the renderer. Safe
        // fallback: skip silently.
        if (std.mem.eql(u8, node.tag, "__redirect__")) return;

        // Text node — escaped character data with no wrapping element. The
        // building block for highlighted token streams (core/highlight.zig)
        // and inline markdown runs (core/markdown.zig) that interleave bare
        // text with element children. Goes through the same escaper as
        // `text_content`, so it is safe by default.
        if (std.mem.eql(u8, node.tag, "__text__")) {
            if (node.text_content) |t| try escapeHtml(w, t);
            return;
        }

        // Empty tag → fragment. Emit only raw_inner (if set) or children;
        // attrs/bindings/text on a fragment are silently ignored.
        if (node.tag.len == 0) {
            if (node.raw_inner) |inner| {
                try w.writeAll(inner);
                return;
            }
            for (node.children_list.items) |c| try render(w, c);
            return;
        }

        try w.print("<{s}", .{node.tag});

        var has_nonce: bool = false;
        for (node.attrs.items) |a| {
            if (std.mem.eql(u8, a.key, "nonce")) has_nonce = true;
            try w.print(" {s}=\"", .{a.key});
            try escapeAttr(w, a.value);
            try w.writeAll("\"");
        }
        // Auto-stamp the per-request CSP nonce onto script/style tags
        // when the renderer's threadlocal is set and the node doesn't
        // already carry one. Required for CSP `'strict-dynamic'`.
        if (!has_nonce and current_nonce.len > 0 and
            (std.mem.eql(u8, node.tag, "script") or std.mem.eql(u8, node.tag, "style")))
        {
            try w.writeAll(" nonce=\"");
            try escapeAttr(w, current_nonce);
            try w.writeAll("\"");
        }
        if (node.z_bind_name) |bind| {
            try w.writeAll(" z-bind=\"");
            try escapeAttr(w, bind);
            try w.writeAll("\"");
            // Phase 12 hydration marker. Stamped alongside the legacy
            // `z-bind` so the client runtime can walk a stable
            // attribute name (the existing selector remains the
            // pre-Phase-12 path).
            try w.writeAll(" data-vh=\"");
            try escapeAttr(w, bind);
            try w.writeAll("\"");
            // Phase 14 auto-walker: typed-binding metadata. The bridge
            // JS reads `data-vh-type` + `data-vh-initial` (+ optional
            // `data-vh-class` for bool) after main wasm instantiation
            // and calls the matching `verve_register_<kind>` export.
            if (node.z_bind_kind) |kind| {
                try w.print(" data-vh-type=\"{s}\"", .{kind.attrName()});
                switch (kind) {
                    .i32 => if (node.z_bind_initial_i32) |v| {
                        try w.print(" data-vh-initial=\"{d}\"", .{v});
                    },
                    .str => if (node.z_bind_initial_str) |s| {
                        try w.writeAll(" data-vh-initial=\"");
                        try escapeAttr(w, s);
                        try w.writeAll("\"");
                    },
                    .bool => {
                        if (node.z_bind_initial_bool) |b| {
                            try w.print(" data-vh-initial=\"{s}\"", .{if (b) "1" else "0"});
                        }
                        if (node.z_bind_class) |c| {
                            try w.writeAll(" data-vh-class=\"");
                            try escapeAttr(w, c);
                            try w.writeAll("\"");
                        }
                    },
                    .f32 => if (node.z_bind_initial_f32) |v| {
                        try w.print(" data-vh-initial=\"{d}\"", .{v});
                    },
                }
            }
        }
        if (node.template_name) |tname| {
            // Phase 16 — named template. The wrapping `<template>` tag
            // is already this node's tag (set by `ctx.template(...)`);
            // we just stamp the discovery attribute the bridge JS uses
            // to find the prototype.
            try w.writeAll(" data-vt=\"");
            try escapeAttr(w, tname);
            try w.writeAll("\"");
        }
        if (node.slot_name) |sname| {
            // Phase 16 — slot marker inside a named template.
            try w.writeAll(" data-vt-slot=\"");
            try escapeAttr(w, sname);
            try w.writeAll("\"");
        }
        if (node.z_on_click_action) |action| {
            try w.writeAll(" z-on-click=\"");
            try escapeAttr(w, action);
            try w.writeAll("\"");
        }
        if (node.z_on_click_id) |id| {
            try w.print(" z-on-click-id=\"{d}\"", .{id});
        }
        if (node.z_on_submit_id) |id| {
            try w.print(" z-on-submit-id=\"{d}\"", .{id});
        }
        if (node.z_on_input_id) |id| {
            try w.print(" z-on-input-id=\"{d}\"", .{id});
        }
        if (node.z_on_change_id) |id| {
            try w.print(" z-on-change-id=\"{d}\"", .{id});
        }
        if (node.z_on_keydown_id) |id| {
            try w.print(" z-on-keydown-id=\"{d}\"", .{id});
        }

        if (node_mod.isVoidTag(node.tag)) {
            try w.writeAll(">");
            return;
        }

        try w.writeAll(">");

        if (node.raw_inner) |inner| {
            try w.writeAll(inner);
        } else {
            if (node.text_content) |t| {
                try escapeHtml(w, t);
            }
            for (node.children_list.items) |c| {
                try render(w, c);
            }
        }

        try w.print("</{s}>", .{node.tag});
    }
};

/// WORKER-SAFE drain task. Blocks on every resolver future the boundary
/// depends on (staging each result inside its Resource) and returns the
/// slot id. Touches ONLY future/staged fields — no Signal mutation, no
/// arena allocation, no node rendering happens here.
fn resolveSlot(io: std.Io, slot: Slot) u32 {
    for (slot.resolvers) |r| r.awaitFn(r.ctx, io);
    return slot.id;
}

fn findSlot(slots: []const Slot, id: u32) ?Slot {
    for (slots) |slot| if (slot.id == id) return slot;
    return null;
}

/// MAIN-THREAD emission for one drained boundary: apply staged resolver
/// results to settle the reactive Signals, re-render the real subtree,
/// and write the `<template>` + verveSwap script. Nonce handling matches
/// the rest of the renderer.
fn emitSlot(w: *Writer, slot: Slot) Writer.Error!void {
    // Apply staged results on the main thread → state.ready/.err.
    for (slot.resolvers) |r| r.applyFn(r.ctx);
    const real = slot.render_real(slot.ctx) catch return;
    try w.print("<template id=\"verve-vs-{d}\">", .{slot.id});
    try Renderer.render(w, real);
    try w.writeAll("</template>");
    if (current_nonce.len > 0) {
        try w.writeAll("<script nonce=\"");
        try escapeAttr(w, current_nonce);
        try w.print("\">verveSwap({d})</script>", .{slot.id});
    } else {
        try w.print("<script>verveSwap({d})</script>", .{slot.id});
    }
}

/// Fallback drain used when the concurrent select buffer can't be
/// allocated. Awaits + emits each boundary sequentially in registration
/// order. Correctness-equivalent to the concurrent path, minus the
/// out-of-order completion ordering.
fn drainSequential(w: *Writer, io: std.Io, slots: []const Slot) Writer.Error!void {
    for (slots) |slot| {
        for (slot.resolvers) |r| r.awaitFn(r.ctx, io);
        try emitSlot(w, slot);
    }
}

/// Escape user text appearing inside an element body.
pub fn escapeHtml(w: *Writer, text: []const u8) Writer.Error!void {
    var start: usize = 0;
    for (text, 0..) |c, i| {
        const replacement: ?[]const u8 = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            else => null,
        };
        if (replacement) |r| {
            if (i > start) try w.writeAll(text[start..i]);
            try w.writeAll(r);
            start = i + 1;
        }
    }
    if (start < text.len) try w.writeAll(text[start..]);
}

/// Escape text appearing inside a double-quoted attribute value.
pub fn escapeAttr(w: *Writer, text: []const u8) Writer.Error!void {
    var start: usize = 0;
    for (text, 0..) |c, i| {
        const replacement: ?[]const u8 = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            else => null,
        };
        if (replacement) |r| {
            if (i > start) try w.writeAll(text[start..i]);
            try w.writeAll(r);
            start = i + 1;
        }
    }
    if (start < text.len) try w.writeAll(text[start..]);
}

test "renders basic element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    const node = try ctx.h1("hello").build();
    try Renderer.render(&w, node);
    try std.testing.expectEqualStrings("<h1>hello</h1>", w.buffered());
}

test "renders nested element with attrs and z-bind" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    var buf: [512]u8 = undefined;
    var w: Writer = .fixed(&buf);
    const tree = try ctx.div().class("card")
        .children(.{
            ctx.span().bind("count").text("0"),
            ctx.button("+").onClick("increment"),
        })
        .build();
    try Renderer.render(&w, tree);
    try std.testing.expectEqualStrings(
        \\<div class="card"><span z-bind="count" data-vh="count">0</span><button z-on-click="increment">+</button></div>
    , w.buffered());
}

test "ctx.template wraps inner subtree with data-vt + slot stamps data-vt-slot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    var buf: [512]u8 = undefined;
    var w: Writer = .fixed(&buf);
    const tree = try ctx.template(
        "todo-row",
        try ctx.el("li").class("todo").children(.{
            ctx.span().slot("text"),
            ctx.button("✕").slot("delete").onClick("delete_todo"),
        }).build(),
    ).build();
    try Renderer.render(&w, tree);
    try std.testing.expectEqualStrings(
        "<template data-vt=\"todo-row\"><li class=\"todo\"><span data-vt-slot=\"text\"></span><button data-vt-slot=\"delete\" z-on-click=\"delete_todo\">✕</button></li></template>",
        w.buffered(),
    );
}

test "streamRender emits placeholder + template + verveSwap for a suspended boundary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    var reg = @import("stream_context.zig").Registry.init(arena.allocator());
    defer reg.deinit();

    const Inner = struct {
        var hits: u32 = 0;
        fn render(c: *const Context) anyerror!*Node {
            hits += 1;
            // Suspend on the first render so the boundary parks a
            // continuation + emits a placeholder; subsequent runs
            // (driven by the drain pump) deliver the real content.
            if (hits == 1) @import("suspense.zig").markSuspended();
            return c.div().class("real-content").text("ok").build();
        }
    };
    Inner.hits = 0;

    // Activate the registry before building the tree — suspense()
    // is eager (it runs the child during tree construction), so the
    // threadlocal must be live during that call, not just during
    // the writer walk.
    stream_context.current = &reg;
    const fallback = ctx.div().class("loading");
    const root = try @import("suspense.zig").suspense(&ctx, .{ .fallback = fallback }, &ctx, Inner.render);
    stream_context.current = null;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var buf: [1024]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try Renderer.streamRender(&w, io, root, &reg);

    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "data-vs=\"0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "loading") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<template id=\"verve-vs-0\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "real-content") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "verveSwap(0)") != null);
}

test "streamRender drains suspended boundaries in completion order, not registration order" {
    const resource_mod = @import("resource.zig");
    const Owner = @import("owner.zig").Owner;
    const effect_mod = @import("effect.zig");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    var owner = Owner.init(std.testing.allocator);
    effect_mod.setPendingAllocator(owner.allocator());
    defer owner.dispose();

    // Real threaded Io so the fetcher sleeps run concurrently across the
    // two boundaries' drain tasks.
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Fetcher that sleeps a configured duration, then returns a value.
    const SleepFetcher = struct {
        io: std.Io,
        ms: i64,
        value: u32,
        fn run(self: *@This()) anyerror!u32 {
            std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(self.ms), .awake) catch {};
            return self.value;
        }
    };
    // SLOW boundary registers FIRST (id 0); FAST boundary second (id 1).
    var slow_fetcher: SleepFetcher = .{ .io = io, .ms = 60, .value = 100 };
    var fast_fetcher: SleepFetcher = .{ .io = io, .ms = 1, .value = 200 };

    const slow_res = try resource_mod.create(u32, io, &owner, &slow_fetcher, SleepFetcher.run);
    const fast_res = try resource_mod.create(u32, io, &owner, &fast_fetcher, SleepFetcher.run);

    // Build the two boundaries with the registry active so resolvers
    // get captured during the child render. Each boundary's child reads
    // its resource (suspends + captures the resolver) and renders a
    // uniquely-classed div once ready.
    var reg = stream_context.Registry.init(arena.allocator());
    defer reg.deinit();

    const SlowCtx = struct {
        c: *const Context,
        r: *resource_mod.Resource(u32),
        fn render(self: *@This()) anyerror!*Node {
            if (self.r.get()) |v| {
                return self.c.div().class("slow-real").attrFmt("data-v", "{d}", .{v}).build();
            }
            return self.c.div().class("slow-pending").build();
        }
    };
    const FastCtx = struct {
        c: *const Context,
        r: *resource_mod.Resource(u32),
        fn render(self: *@This()) anyerror!*Node {
            if (self.r.get()) |v| {
                return self.c.div().class("fast-real").attrFmt("data-v", "{d}", .{v}).build();
            }
            return self.c.div().class("fast-pending").build();
        }
    };
    var slow_ctx: SlowCtx = .{ .c = &ctx, .r = slow_res };
    var fast_ctx: FastCtx = .{ .c = &ctx, .r = fast_res };

    stream_context.current = &reg;
    const slow_fallback = ctx.div().class("slow-fallback");
    const fast_fallback = ctx.div().class("fast-fallback");
    const slow_node = try @import("suspense.zig").suspense(&ctx, .{ .fallback = slow_fallback }, &slow_ctx, SlowCtx.render);
    const fast_node = try @import("suspense.zig").suspense(&ctx, .{ .fallback = fast_fallback }, &fast_ctx, FastCtx.render);
    stream_context.current = null;

    const root = try ctx.div().children(.{ slow_node, fast_node }).build();

    // Sanity: slow registered first (id 0), fast second (id 1).
    try std.testing.expectEqual(@as(usize, 2), reg.pending().len);
    try std.testing.expectEqual(@as(u32, 0), reg.pending()[0].id);
    try std.testing.expectEqual(@as(u32, 1), reg.pending()[1].id);

    var buf: [2048]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try Renderer.streamRender(&w, io, root, &reg);
    const out = w.buffered();

    // Both templates present.
    const fast_tmpl = std.mem.indexOf(u8, out, "verve-vs-1");
    const slow_tmpl = std.mem.indexOf(u8, out, "verve-vs-0");
    try std.testing.expect(fast_tmpl != null);
    try std.testing.expect(slow_tmpl != null);
    // FAST (id 1, registered second) completes first → its template
    // appears BEFORE the SLOW (id 0) template on the wire. Completion
    // order, not registration order.
    try std.testing.expect(fast_tmpl.? < slow_tmpl.?);
    try std.testing.expect(std.mem.indexOf(u8, out, "fast-real") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "slow-real") != null);
}

test "escapes HTML entities in text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    const node = try ctx.p().text("<script>alert(1)</script> & co").build();
    try Renderer.render(&w, node);
    try std.testing.expectEqualStrings(
        "<p>&lt;script&gt;alert(1)&lt;/script&gt; &amp; co</p>",
        w.buffered(),
    );
}

test "escapes quotes in attribute values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    const node = try ctx.input().value("a\"b<c").build();
    try Renderer.render(&w, node);
    try std.testing.expectEqualStrings(
        "<input value=\"a&quot;b&lt;c\">",
        w.buffered(),
    );
}

test "void elements omit closing tag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    var buf: [128]u8 = undefined;
    var w: Writer = .fixed(&buf);
    const node = try ctx.br().build();
    try Renderer.render(&w, node);
    try std.testing.expectEqualStrings("<br>", w.buffered());
}

test "raw inner HTML bypasses escaping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    const node = try ctx.el("script").raw("if (a < b && c > 0) {}").build();
    try Renderer.render(&w, node);
    try std.testing.expectEqualStrings(
        "<script>if (a < b && c > 0) {}</script>",
        w.buffered(),
    );
}

test "ctx.raw fragment emits bytes verbatim with no wrapper tag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    var buf: [512]u8 = undefined;
    var w: Writer = .fixed(&buf);
    const xml =
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<urlset><url><loc>https://example.com/</loc></url></urlset>
    ;
    const node = try ctx.raw(xml).contentType("application/xml").build();
    try Renderer.render(&w, node);
    try std.testing.expectEqualStrings(xml, w.buffered());
    try std.testing.expectEqualStrings("application/xml", node.content_type_override.?);
}

test "raw_inner takes precedence over text and children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    const node = try ctx.div()
        .text("should not appear")
        .children(.{ctx.span().text("nope")})
        .raw("<i>raw</i>")
        .build();
    try Renderer.render(&w, node);
    try std.testing.expectEqualStrings("<div><i>raw</i></div>", w.buffered());
}
