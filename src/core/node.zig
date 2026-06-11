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

/// Kind tag on a typed binding. Mirrored on the rendered element as
/// `data-vh-type="<lower>"` for the bridge JS auto-walker to dispatch.
pub const BindKind = enum {
    i32,
    str,
    bool,
    f32,

    pub fn attrName(self: BindKind) []const u8 {
        return switch (self) {
            .i32 => "i32",
            .str => "str",
            .bool => "bool",
            .f32 => "f32",
        };
    }
};

pub const Node = struct {
    arena: ?std.mem.Allocator = null,
    tag: []const u8,
    text_content: ?[]const u8 = null,
    /// Raw inner HTML — when set, emitted verbatim without escaping in
    /// place of `text_content` and `children_list`. The enclosing tag is
    /// still produced. Use `ctx.raw(bytes)` (tag="") to emit a body with
    /// no wrapping tag (sitemap, feed, OG SVG responses).
    raw_inner: ?[]const u8 = null,
    /// Optional response Content-Type override. Only honored when this
    /// node is the root of the page tree (read by the server before
    /// writing the response headers). Routes that render non-HTML
    /// (XML, Atom, SVG) set this via `.contentType()`.
    content_type_override: ?[]const u8 = null,
    z_bind_name: ?[]const u8 = null,
    /// Typed-binding metadata for the auto-walker (Phase 14). When set,
    /// the renderer stamps `data-vh-type="<kind>"` plus the matching
    /// initial-value form so the bridge JS can call the right
    /// `verve_register_<kind>` export at boot without per-bind glue.
    /// `null` keeps the legacy `.bind()` behavior (caller registers
    /// manually via `verve_init_<name>` + `verve_hydrate`).
    z_bind_kind: ?BindKind = null,
    z_bind_initial_i32: ?i32 = null,
    z_bind_initial_str: ?[]const u8 = null,
    z_bind_initial_bool: ?bool = null,
    z_bind_initial_f32: ?f32 = null,
    /// CSS class toggled by a bool binding. Only meaningful when
    /// `z_bind_kind == .bool` — paired with `z_bind_initial_bool` for
    /// the initial-state attribute on render.
    z_bind_class: ?[]const u8 = null,
    /// Phase 16 named-template metadata. `template_name` flips the
    /// renderer to wrap this node in `<template data-vt="<name>">`
    /// instead of emitting it as a live element — the inner subtree
    /// stays parsed but not rendered until a chunk clones it via
    /// `verve.cloneTemplate`. `slot_name` marks fillable children
    /// inside a template with `data-vt-slot="<name>"` so chunks can
    /// reach them via `verve.slotText` / `verve.slotAttr` without
    /// polluting the document's `data-ref` namespace.
    template_name: ?[]const u8 = null,
    slot_name: ?[]const u8 = null,
    z_on_click_action: ?[]const u8 = null,
    /// Closure-style event slot ids. Each corresponds to a `*const fn
    /// () void` registered via `verve.registerEvent(...)` in the wasm
    /// runtime. The renderer stamps `z-on-<event>-id="<n>"` and the JS
    /// bridge's delegated listener for that event type dispatches the
    /// id through `verve_event_dispatch(n)`. Handler runs in WASM with
    /// whatever state it captured at registration; input/change
    /// handlers typically read the new value via `refValueI32` /
    /// `refValueF32` against a co-stamped NodeRef.
    z_on_click_id: ?u32 = null,
    z_on_submit_id: ?u32 = null,
    z_on_input_id: ?u32 = null,
    z_on_change_id: ?u32 = null,
    z_on_keydown_id: ?u32 = null,
    /// Phase 2b — pointer/wheel event handlers (named-export form, like
    /// `z_on_click_action`). Stamped as `z-on-<event>="<name>"`; the bridge's
    /// delegated listeners dispatch them to the matching island chunk export.
    /// Power the interactive viz island (zoom/pan/drag/hover).
    z_on_wheel_action: ?[]const u8 = null,
    z_on_pointerdown_action: ?[]const u8 = null,
    z_on_pointermove_action: ?[]const u8 = null,
    z_on_pointerup_action: ?[]const u8 = null,
    z_on_pointerover_action: ?[]const u8 = null,
    z_on_pointerout_action: ?[]const u8 = null,
    z_on_pointercancel_action: ?[]const u8 = null,
    z_on_dblclick_action: ?[]const u8 = null,
    /// When set, the server short-circuits rendering and sends a
    /// redirect response (302/303) instead of HTML. Populated via
    /// `ctx.redirect("/login")`.
    redirect: ?@import("route.zig").Redirect = null,
    /// Slot that nested routing fills with the matched child's
    /// rendered tree. When this node is itself an outlet placeholder
    /// (tag = `__outlet__`), the renderer emits this subtree in its
    /// place; null outlet placeholders render to nothing.
    outlet_content: ?*Node = null,
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

    /// Phase 16 — mark this node as a fillable slot inside a
    /// `ctx.template(...)` subtree. Renderer stamps
    /// `data-vt-slot="<name>"`; wasm chunks reach it after cloning
    /// via `verve.slotText(handle, "<name>", text)` /
    /// `verve.slotAttr(handle, "<name>", attr, val)`. Slot names
    /// must be unique within a template; nested-template re-use of
    /// the same slot name resolves to the first match in
    /// document order on the cloned fragment.
    pub fn slot(self: *Node, slot_name: []const u8) *Node {
        if (self.err != null) return self;
        self.slot_name = slot_name;
        return self;
    }

    /// Typed binding for the Phase-14 auto-walker. Stamps `z-bind` +
    /// `data-vh` (existing behavior) plus `data-vh-type="i32"` +
    /// `data-vh-initial="<n>"`. The bridge JS reads those after main
    /// instantiation and calls `verve_register_i32(name, initial)` so
    /// the app no longer needs a `verve_init_<name>` export per slot.
    pub fn bindI32(self: *Node, signal_name: []const u8, initial: i32) *Node {
        if (self.err != null) return self;
        self.z_bind_name = signal_name;
        self.z_bind_kind = .i32;
        self.z_bind_initial_i32 = initial;
        return self;
    }

    pub fn bindStr(self: *Node, signal_name: []const u8, initial: []const u8) *Node {
        if (self.err != null) return self;
        self.z_bind_name = signal_name;
        self.z_bind_kind = .str;
        self.z_bind_initial_str = initial;
        return self;
    }

    /// Bool binding — `class_name` is the CSS class toggled on/off as
    /// the signal flips. Stamped as `data-vh-class="<class>"` so the
    /// walker can pass it to `verve_register_bool`.
    pub fn bindBool(self: *Node, signal_name: []const u8, class_name: []const u8, initial: bool) *Node {
        if (self.err != null) return self;
        self.z_bind_name = signal_name;
        self.z_bind_kind = .bool;
        self.z_bind_initial_bool = initial;
        self.z_bind_class = class_name;
        return self;
    }

    pub fn bindF32(self: *Node, signal_name: []const u8, initial: f32) *Node {
        if (self.err != null) return self;
        self.z_bind_name = signal_name;
        self.z_bind_kind = .f32;
        self.z_bind_initial_f32 = initial;
        return self;
    }

    pub fn onClick(self: *Node, action: []const u8) *Node {
        if (self.err != null) return self;
        self.z_on_click_action = action;
        return self;
    }

    /// Closure-style click binding. `id` is the index returned by
    /// `verve.registerEvent(handler)` in the wasm runtime. The
    /// renderer stamps `z-on-click-id="<id>"` and the JS bridge
    /// dispatches it through `verve_event_dispatch(id)` — handler
    /// runs in WASM with whatever state it captured at registration.
    pub fn onClickFn(self: *Node, slot_id: u32) *Node {
        if (self.err != null) return self;
        self.z_on_click_id = slot_id;
        return self;
    }

    /// Closure-style `submit` handler. Renderer stamps
    /// `z-on-submit-id="<slot_id>"`; the bridge's delegated submit
    /// listener calls `verve_event_dispatch(slot_id)` and
    /// `preventDefault()` so the native form post does not fire.
    pub fn onSubmitFn(self: *Node, slot_id: u32) *Node {
        if (self.err != null) return self;
        self.z_on_submit_id = slot_id;
        return self;
    }

    /// Closure-style `input` handler. Fires on every keystroke against
    /// `<input>` / `<textarea>` — the bridge does NOT call
    /// `preventDefault()` so the input still updates natively. Read the
    /// new value via `verve.refValueI32` / `refValueF32` against a
    /// co-stamped NodeRef.
    pub fn onInputFn(self: *Node, slot_id: u32) *Node {
        if (self.err != null) return self;
        self.z_on_input_id = slot_id;
        return self;
    }

    /// Closure-style `change` handler. Fires when an input commits
    /// (blur / Enter on text inputs, selection on `<select>` /
    /// checkbox / radio). No `preventDefault()`.
    pub fn onChangeFn(self: *Node, slot_id: u32) *Node {
        if (self.err != null) return self;
        self.z_on_change_id = slot_id;
        return self;
    }

    /// Closure-style `keydown` handler. No `preventDefault()` — the
    /// native key handling still runs.
    pub fn onKeydownFn(self: *Node, slot_id: u32) *Node {
        if (self.err != null) return self;
        self.z_on_keydown_id = slot_id;
        return self;
    }

    /// Pointer/wheel event handlers (named-export form). Each stamps
    /// `z-on-<event>="<name>"`; the bridge dispatches the named export on the
    /// island chunk. Used by the interactive viz graph.
    pub fn onWheel(self: *Node, action: []const u8) *Node {
        if (self.err != null) return self;
        self.z_on_wheel_action = action;
        return self;
    }

    pub fn onPointerDown(self: *Node, action: []const u8) *Node {
        if (self.err != null) return self;
        self.z_on_pointerdown_action = action;
        return self;
    }

    pub fn onPointerMove(self: *Node, action: []const u8) *Node {
        if (self.err != null) return self;
        self.z_on_pointermove_action = action;
        return self;
    }

    pub fn onPointerUp(self: *Node, action: []const u8) *Node {
        if (self.err != null) return self;
        self.z_on_pointerup_action = action;
        return self;
    }

    pub fn onPointerOver(self: *Node, action: []const u8) *Node {
        if (self.err != null) return self;
        self.z_on_pointerover_action = action;
        return self;
    }

    pub fn onPointerOut(self: *Node, action: []const u8) *Node {
        if (self.err != null) return self;
        self.z_on_pointerout_action = action;
        return self;
    }

    pub fn onPointerCancel(self: *Node, action: []const u8) *Node {
        if (self.err != null) return self;
        self.z_on_pointercancel_action = action;
        return self;
    }

    pub fn onDblClick(self: *Node, action: []const u8) *Node {
        if (self.err != null) return self;
        self.z_on_dblclick_action = action;
        return self;
    }

    /// Stamp `data-ref="<id>"` onto this node. The client-side runtime
    /// resolves the id back to a live DOM Element via `verveQueryRef`,
    /// letting WASM effects observe or mutate a specific element
    /// without scanning the whole tree.
    ///
    /// `noderef` is a `NodeRef(Tag)` — see core/noderef.zig. The Tag is
    /// not enforced at render time but downstream `use:` directives
    /// can require a specific element kind.
    pub fn ref(self: *Node, noderef: anytype) *Node {
        if (self.err != null) return self;
        // Accept any NodeRef(...) — duck-type on the .id field rather
        // than importing the noderef module here (which would create a
        // circular import via the renderer chain).
        return self.attr("data-ref", noderef.id);
    }

    // ---- animation ---------------------------------------------------------

    /// Attach a declarative animation. `a` is any value exposing
    /// `err: ?anyerror` and `toJson(alloc) ![]const u8` — i.e. a
    /// `*verve.anim.Tween` or `*verve.anim.Timeline` (duck-typed so this
    /// file stays decoupled from the anim module, same stance as
    /// islands.zig vs `verve.island`). The descriptor is serialized into
    /// the node arena and stamped as `data-anim`; the bridge JS scans
    /// `[data-anim]` after hydrate and runs it — no island required.
    /// JSON quoting is handled by the renderer's escapeAttr.
    ///
    /// A null tween target animates this element; a selector target is
    /// scoped to this element's descendants. One animation per node —
    /// compose with a Timeline for more.
    pub fn animate(self: *Node, a: anytype) *Node {
        if (self.err != null) return self;
        if (a.err) |e| {
            self.err = e;
            return self;
        }
        const json = a.toJson(self.arena.?) catch |e| {
            self.err = e;
            return self;
        };
        return self.animateJson(json);
    }

    /// Escape hatch: attach a pre-serialized descriptor (cached or
    /// hand-rolled wire JSON).
    pub fn animateJson(self: *Node, json: []const u8) *Node {
        if (self.err != null) return self;
        for (self.attrs.items) |at| {
            if (std.mem.eql(u8, at.key, "data-anim")) {
                self.err = error.DuplicateAnimation;
                return self;
            }
        }
        return self.attr("data-anim", json);
    }

    /// Attach a declarative draggable (verve's pointer-drag engine — NOT
    /// the native HTML5 `draggable="true"` attribute; use
    /// `.attr("draggable","true")` for that). `d` is any value exposing
    /// `err: ?anyerror` and `toJson(alloc) ![]const u8` — i.e. a
    /// `*verve.anim.drag.Drag` (duck-typed like `animate`). Serialized
    /// into the node arena and stamped as `data-drag`; the bridge scans
    /// `[data-drag]` after hydrate — no island required. A null config
    /// target drags this element; a selector target is scoped to this
    /// element's descendants. One draggable per node.
    pub fn draggable(self: *Node, d: anytype) *Node {
        if (self.err != null) return self;
        if (d.err) |e| {
            self.err = e;
            return self;
        }
        const json = d.toJson(self.arena.?) catch |e| {
            self.err = e;
            return self;
        };
        return self.draggableJson(json);
    }

    /// Split this node's text_content into animatable spans (verve.anim
    /// SplitText — chars/words/lines for typographic reveals). Pure
    /// node-tree surgery; semantics, a11y, and errors live in
    /// anim/split.zig. Spans need `display:inline-block` CSS for
    /// transforms to apply.
    pub fn splitText(self: *Node, opts: @import("anim/split.zig").Options) *Node {
        @import("anim/split.zig").apply(self, opts);
        return self;
    }

    /// Escape hatch: attach a pre-serialized drag descriptor.
    pub fn draggableJson(self: *Node, json: []const u8) *Node {
        if (self.err != null) return self;
        for (self.attrs.items) |at| {
            if (std.mem.eql(u8, at.key, "data-drag")) {
                self.err = error.DuplicateDraggable;
                return self;
            }
        }
        return self.attr("data-drag", json);
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

    /// Set raw inner HTML — bytes emitted verbatim, NOT escaped.
    /// Replaces `text` and `children` if both are present. Used for
    /// inline `<script>` bodies, server-rendered SVG, and the fragment
    /// (`tag = ""`) form returned from non-HTML SEO routes.
    pub fn raw(self: *Node, bytes: []const u8) *Node {
        if (self.err != null) return self;
        self.raw_inner = bytes;
        return self;
    }

    /// Override the HTTP Content-Type emitted for this response. Only
    /// effective on the root node returned from a page route. Combine
    /// with `ctx.raw(bytes).contentType("application/xml")` to serve
    /// sitemaps, Atom feeds, or SVG OG images from the same router.
    pub fn contentType(self: *Node, t: []const u8) *Node {
        if (self.err != null) return self;
        self.content_type_override = t;
        return self;
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

test "animate stamps data-anim and rejects duplicates" {
    const anim = @import("anim/anim.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const n = create(a, "div").animate(anim.from(a, null).opacity(0).y(24).duration(0.6));
    try std.testing.expect(n.err == null);
    try std.testing.expectEqualStrings("data-anim", n.attrs.items[0].key);
    try std.testing.expect(std.mem.startsWith(u8, n.attrs.items[0].value, "{\"v\":1"));

    const dup = create(a, "div")
        .animateJson("{\"v\":1}")
        .animateJson("{\"v\":1}");
    try std.testing.expectEqual(@as(?anyerror, error.DuplicateAnimation), dup.err);
}

test "animate surfaces builder and serialize errors" {
    const anim = @import("anim/anim.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bad = create(a, "div").animate(anim.to(a, ".x").opacity(1).step(0));
    try std.testing.expectEqual(@as(?anyerror, error.StepAfterProps), bad.err);

    // dyn values are island-only — SSR serialize rejects them
    const dyn = create(a, "div").animate(anim.to(a, ".x").x(anim.Value{ .dyn = 0 }));
    try std.testing.expectEqual(@as(?anyerror, error.DynRequiresIsland), dyn.err);
}

test "draggable stamps data-drag and rejects duplicates" {
    const anim = @import("anim/anim.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const n = create(a, "div").draggable(anim.draggable(a, .{ .inertia = .on }));
    try std.testing.expect(n.err == null);
    try std.testing.expectEqualStrings("data-drag", n.attrs.items[0].key);
    try std.testing.expect(std.mem.startsWith(u8, n.attrs.items[0].value, "{\"v\":1,\"dr\":{"));

    const dup = create(a, "div").draggableJson("{\"v\":1}").draggableJson("{\"v\":1}");
    try std.testing.expectEqual(@as(?anyerror, error.DuplicateDraggable), dup.err);

    // validate + SSR-strict errors propagate through the chain
    const bad = create(a, "div").draggable(anim.draggable(a, .{ .on_end_slot = 5, .inertia = .on }));
    try std.testing.expectEqual(@as(?anyerror, error.CallbackSlotRequiresIsland), bad.err);
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
