//! Descriptor wire-format writer ("v":1). Single source of truth for the
//! Zig <-> verve.js animation contract — the golden tests below double as
//! the JS interpreter's conformance fixtures.
//!
//! Freestanding-safe: builds via `std.Io.Writer.fixed` over an arena
//! buffer (NOT `Writer.Allocating` / `allocPrint` — the address-taken
//! drain collides with the shared indirect function table in island
//! chunks; see VizGraphInteractive.zig).

const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");
const tween_mod = @import("tween.zig");
const timeline_mod = @import("timeline.zig");
const scroll = @import("scroll.zig");
const path_mod = @import("path.zig");
const drag_mod = @import("drag.zig");

/// Which authoring surface is serializing. SSR rejects island-only
/// constructs (dynamic values, fn modifiers, ref-handle targets, callback
/// slots) — those reference wasm-side tables that don't exist for a
/// server-rendered descriptor.
pub const Surface = enum { ssr, island };

/// Derived wire data (path sampling / morph matching) resolved ONCE per
/// serialization, outside the grow() retry loop — buffer growth must not
/// re-run path math. Arena-owned.
const Extras = struct {
    mp: ?[]const path_mod.Sample = null,
    mp_rotate: bool = false,
    mp_ro: f64 = 0,
    mo: ?path_mod.MorphPair = null,
};

fn resolveExtras(alloc: std.mem.Allocator, t: *const tween_mod.Tween) !Extras {
    var ex: Extras = .{};
    if (t.motion_path) |mp| {
        var pd = path_mod.parse(alloc, mp.path) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.BadPath,
        };
        const n: usize = if (mp.samples == 0) 128 else @min(@max(@as(usize, mp.samples), 2), 512);
        const samples = path_mod.motionSamples(alloc, &pd, n, mp.start, mp.end) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.BadPath,
        };
        if (mp.align_to == .start) path_mod.alignSamplesToStart(samples);
        ex.mp = samples;
        ex.mp_rotate = mp.rotate;
        ex.mp_ro = mp.rotate_offset_deg;
    }
    if (t.morph_opts) |m| {
        var pa = path_mod.parse(alloc, m.from) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.BadPath,
        };
        var pb = path_mod.parse(alloc, m.to) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.BadPath,
        };
        ex.mo = path_mod.prepareMorph(alloc, &pa, &pb, .{}) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SubpathCountMismatch => return error.SubpathCountMismatch,
            error.EmptyPath => return error.BadPath,
        };
    }
    return ex;
}

const TweenCtx = struct {
    t: *const tween_mod.Tween,
    ex: Extras,
};

const TimelineCtx = struct {
    tl: *const timeline_mod.Timeline,
    exs: []const Extras,
};

pub fn tweenToJson(alloc: std.mem.Allocator, t: *const tween_mod.Tween, surface: Surface) ![]const u8 {
    if (t.err) |e| return e;
    const ctx = TweenCtx{ .t = t, .ex = try resolveExtras(alloc, t) };
    return grow(alloc, ctx, surface, writeTweenRoot);
}

pub fn timelineToJson(alloc: std.mem.Allocator, tl: *const timeline_mod.Timeline, surface: Surface) ![]const u8 {
    if (tl.err) |e| return e;
    const exs = try alloc.alloc(Extras, tl.entries.items.len);
    for (tl.entries.items, 0..) |e, i| exs[i] = try resolveExtras(alloc, e.tween);
    const ctx = TimelineCtx{ .tl = tl, .exs = exs };
    return grow(alloc, ctx, surface, writeTimelineRoot);
}

/// Tween-less trigger (`anim.reveal` / standalone island trigger):
/// `{"v":1,"sc":{...}}`. Routed by the JS interpreter straight to
/// trigger registration (no `p`/`k`/`ch` keys present).
pub fn triggerToJson(alloc: std.mem.Allocator, t: *const scroll.Trigger, surface: Surface) ![]const u8 {
    if (t.err) |e| return e;
    return grow(alloc, t, surface, writeTriggerRoot);
}

fn writeTriggerRoot(w: *std.Io.Writer, t: *const scroll.Trigger, surface: Surface) anyerror!void {
    try w.writeAll("{\"v\":1");
    try writeScrollTrigger(w, t.config, surface);
    try w.writeAll("}");
}

/// Drag descriptor: `{"v":1,"dr":{...}}` — stamped as `data-drag` on SSR,
/// handed to `verve_drag_create` on islands. Separate root from anim
/// descriptors (a draggable is not an animation; a node carries both).
pub fn dragToJson(alloc: std.mem.Allocator, d: *const drag_mod.Drag, surface: Surface) ![]const u8 {
    if (d.err) |e| return e;
    return grow(alloc, d, surface, writeDragRoot);
}

fn writeDragRoot(w: *std.Io.Writer, d: *const drag_mod.Drag, surface: Surface) anyerror!void {
    try w.writeAll("{\"v\":1");
    try writeDraggable(w, d.config, surface);
    try w.writeAll("}");
}

/// Emit the `,"dr":{...}` object. Defaults omitted: axis both, no
/// bounds/inertia/snap, threshold 3, cursor managed.
fn writeDraggable(w: *std.Io.Writer, dr: drag_mod.Draggable, surface: Surface) anyerror!void {
    try w.writeAll(",\"dr\":{");
    var first = true;
    if (dr.target_handle) |h| {
        if (surface == .ssr) return error.HandleRequiresIsland;
        try w.print("\"t\":{{\"h\":{d}}}", .{h});
        first = false;
    } else if (dr.target) |sel| {
        try w.writeAll("\"t\":{\"s\":");
        try writeJsonString(w, sel);
        try w.writeAll("}");
        first = false;
    }
    if (dr.handle) |sel| {
        try comma(w, &first);
        try w.writeAll("\"hd\":");
        try writeJsonString(w, sel);
    }
    if (dr.axis != .both) {
        try comma(w, &first);
        try w.print("\"ax\":{d}", .{@intFromEnum(dr.axis)});
    }
    switch (dr.bounds) {
        .none => {},
        .selector => |sel| {
            try comma(w, &first);
            try w.writeAll("\"b\":{\"s\":");
            try writeJsonString(w, sel);
            try w.writeAll("}");
        },
        .rect => |r| {
            try comma(w, &first);
            try w.print("\"b\":[{d},{d},{d},{d}]", .{ r.min_x, r.max_x, r.min_y, r.max_y });
        },
    }
    switch (dr.inertia) {
        .off => {},
        .on => {
            try comma(w, &first);
            try w.writeAll("\"in\":1");
        },
        // retention < 1 by validation, so "in":1 is unambiguously default
        .retention => |r| {
            try comma(w, &first);
            try w.print("\"in\":{d}", .{r});
        },
    }
    switch (dr.snap) {
        .none => {},
        .grid => |g| {
            try comma(w, &first);
            try w.print("\"sn\":{{\"g\":[{d},{d}]}}", .{ g.x, g.y });
        },
        .points => |pts| {
            try comma(w, &first);
            try w.writeAll("\"sn\":{\"p\":[");
            for (pts, 0..) |p, i| {
                if (i != 0) try w.writeAll(",");
                try w.print("{d},{d}", .{ p[0], p[1] });
            }
            try w.writeAll("]}");
        },
    }
    if (dr.threshold_px != 3) {
        try comma(w, &first);
        try w.print("\"th\":{d}", .{dr.threshold_px});
    }
    if (!dr.manage_cursor) {
        try comma(w, &first);
        try w.writeAll("\"cur\":0");
    }
    if (dr.toggle_class) |c| {
        try comma(w, &first);
        try w.writeAll("\"cls\":");
        try writeJsonString(w, c);
    }
    if (dr.zones) |sel| {
        try comma(w, &first);
        try w.writeAll("\"zn\":");
        try writeJsonString(w, sel);
    }
    if (dr.zone_class) |c| {
        try comma(w, &first);
        try w.writeAll("\"znc\":");
        try writeJsonString(w, c);
    }
    if (dr.disabled) {
        try comma(w, &first);
        try w.writeAll("\"dis\":1");
    }
    if (dr.hasSlots()) {
        if (surface == .ssr) return error.CallbackSlotRequiresIsland;
        try comma(w, &first);
        try w.writeAll("\"cb\":{");
        var cb_first = true;
        if (dr.on_start_slot) |s| try slotField(w, &cb_first, "sS", s);
        if (dr.on_drag_slot) |s| try slotField(w, &cb_first, "sD", s);
        if (dr.on_end_slot) |s| try slotField(w, &cb_first, "sE", s);
        if (dr.on_throw_complete_slot) |s| try slotField(w, &cb_first, "sT", s);
        if (dr.on_drop_slot) |s| try slotField(w, &cb_first, "sZ", s);
        try w.writeAll("}");
    }
    try w.writeAll("}");
}

/// Retry-on-overflow sizing: serialize into a fixed buffer, quadrupling on
/// `WriteFailed` up to 1 MiB. Arena allocator — abandoned buffers are
/// reclaimed with the arena.
fn grow(
    alloc: std.mem.Allocator,
    item: anytype,
    surface: Surface,
    comptime writeFn: fn (*std.Io.Writer, @TypeOf(item), Surface) anyerror!void,
) ![]const u8 {
    var size: usize = 1024;
    while (true) {
        const buf = try alloc.alloc(u8, size);
        var w: std.Io.Writer = .fixed(buf);
        if (writeFn(&w, item, surface)) {
            return w.buffered();
        } else |e| switch (e) {
            error.WriteFailed => {
                if (size >= 1 << 20) return error.DescriptorTooLarge;
                size *= 4;
            },
            else => return e,
        }
    }
}

fn writeTweenRoot(w: *std.Io.Writer, ctx: TweenCtx, surface: Surface) anyerror!void {
    try w.writeAll("{\"v\":1");
    try writeTweenBody(w, ctx.t, ctx.ex, surface);
    try w.writeAll("}");
}

fn writeTimelineRoot(w: *std.Io.Writer, ctx: TimelineCtx, surface: Surface) anyerror!void {
    const tl = ctx.tl;
    try w.writeAll("{\"v\":1,\"tl\":1");
    if (tl.id_name) |n| {
        try w.writeAll(",\"id\":");
        try writeJsonString(w, n);
    }
    if (tl.delay_s != 0) try w.print(",\"del\":{d}", .{tl.delay_s});
    if (tl.repeat_n != 0) try w.print(",\"rep\":{d}", .{tl.repeat_n});
    if (tl.yoyo_on) try w.writeAll(",\"yo\":1");
    try writeReducedMotion(w, tl.reduced);
    if (!tl.autoplay) try w.writeAll(",\"auto\":0");
    if (tl.labels.items.len > 0) {
        try w.writeAll(",\"lab\":{");
        for (tl.labels.items, 0..) |l, i| {
            if (i != 0) try w.writeAll(",");
            try writeJsonString(w, l.name);
            try w.print(":{d}", .{l.time_s});
        }
        try w.writeAll("}");
    }
    try writeCallbacks(w, tl.on_complete_slot, null, null, tl.cb_island, tl.cb_complete_export, surface);
    if (tl.scroll_trigger) |sc| try writeScrollTrigger(w, sc, surface);
    try w.writeAll(",\"ch\":[");
    for (tl.entries.items, 0..) |e, i| {
        if (i != 0) try w.writeAll(",");
        if (!std.math.isFinite(e.start_s)) return error.InfinitePosition;
        try w.print("{{\"pos\":{d}", .{e.start_s});
        try writeTweenBody(w, e.tween, ctx.exs[i], surface);
        try w.writeAll("}");
    }
    try w.writeAll("]}");
}

fn writeTweenBody(w: *std.Io.Writer, t: *const tween_mod.Tween, ex: Extras, surface: Surface) anyerror!void {
    if (t.id_name) |n| {
        try w.writeAll(",\"id\":");
        try writeJsonString(w, n);
    }
    if (t.target_handle) |h| {
        if (surface == .ssr) return error.HandleRequiresIsland;
        try w.print(",\"t\":{{\"h\":{d}}}", .{h});
    } else if (t.target) |sel| {
        try w.writeAll(",\"t\":{\"s\":");
        try writeJsonString(w, sel);
        try w.writeAll("}");
    }
    try w.print(",\"d\":{d}", .{t.duration_s});
    if (t.delay_s != 0) try w.print(",\"del\":{d}", .{t.delay_s});
    if (t.repeat_n != 0) try w.print(",\"rep\":{d}", .{t.repeat_n});
    if (t.repeat_delay_s != 0) try w.print(",\"rd\":{d}", .{t.repeat_delay_s});
    if (t.yoyo_on) try w.writeAll(",\"yo\":1");
    try w.writeAll(",\"e\":");
    try writeJsonString(w, t.ease_kind.wireName());

    if (t.steps.items.len > 0) {
        try writeSteps(w, t, surface);
    } else if (t.props.items.len > 0 or (ex.mp == null and ex.mo == null)) {
        // "p":{} suppressed when empty and a motion path / morph carries
        // the animation instead.
        try writeProps(w, t, surface);
    }
    if (ex.mp) |samples| try path_mod.writeMotionPath(w, samples, ex.mp_rotate, ex.mp_ro);
    if (ex.mo) |*pair| try path_mod.writeMorph(w, pair);

    if (t.stagger_opts) |s| try writeStagger(w, s);
    if (t.modifiers.items.len > 0) try writeModifiers(w, t.modifiers.items, surface);
    try writeCallbacks(w, t.on_complete_slot, t.on_start_slot, t.on_repeat_slot, t.cb_island, t.cb_complete_export, surface);
    if (t.scroll_trigger) |sc| try writeScrollTrigger(w, sc, surface);
    try writeReducedMotion(w, t.reduced);
    if (!t.autoplay) try w.writeAll(",\"auto\":0");
}

fn writeProps(w: *std.Io.Writer, t: *const tween_mod.Tween, surface: Surface) anyerror!void {
    try w.writeAll(",\"p\":{");
    for (t.props.items, 0..) |p, i| {
        if (i != 0) try w.writeAll(",");
        // GL-engine entries carry the reserved Zig-side name "@gl"; the
        // serialized KEY is suffixed with the decimal target_id
        // ("@gl:<id>") so two gl targets on one tween don't collide into a
        // single JSON key (JSON.parse would keep only the last, silently
        // dropping the first gl tween). The JS interpreter matches on the
        // "@gl" prefix. The value object emits the gl keys FIRST
        // ("gl":<target_id>,"gls":<setter_slot>) then to/f — gl == null
        // entries stay byte-identical to the pre-gl wire format.
        if (p.gl) |g| {
            try w.print("\"@gl:{d}\":{{\"gl\":{d},\"gls\":{d}", .{ g.target_id, g.target_id, g.setter_slot });
            var gl_first = false; // gl/gls already written, so to/f gets a comma
            switch (t.kind) {
                .to => {
                    try writeValueField(w, "to", p.to, surface, &gl_first);
                    if (p.from) |f| try writeValueField(w, "f", f, surface, &gl_first);
                },
                .from => {
                    try writeValueField(w, "f", p.to, surface, &gl_first);
                    if (p.from) |f| try writeValueField(w, "to", f, surface, &gl_first);
                },
            }
            try w.writeAll("}");
            continue;
        }
        try writeJsonString(w, p.name);
        try w.writeAll(":{");
        var first = true;
        // `.from` tweens: authored value is the start state; the end state
        // is read from the element at play time. `.to` tweens: authored
        // value is the end state. Explicit `propFrom` fills the other side.
        switch (t.kind) {
            .to => {
                try writeValueField(w, "to", p.to, surface, &first);
                if (p.from) |f| try writeValueField(w, "f", f, surface, &first);
            },
            .from => {
                try writeValueField(w, "f", p.to, surface, &first);
                if (p.from) |f| try writeValueField(w, "to", f, surface, &first);
            },
        }
        try w.writeAll("}");
    }
    try w.writeAll("}");
}

fn writeSteps(w: *std.Io.Writer, t: *const tween_mod.Tween, surface: Surface) anyerror!void {
    try w.writeAll(",\"k\":[");
    for (t.steps.items, 0..) |s, i| {
        if (i != 0) try w.writeAll(",");
        try w.print("{{\"o\":{d}", .{s.at_pct / 100.0});
        if (s.ease_kind) |e| {
            try w.writeAll(",\"e\":");
            try writeJsonString(w, e.wireName());
        }
        try w.writeAll(",\"p\":{");
        for (s.props.items, 0..) |p, j| {
            if (j != 0) try w.writeAll(",");
            try writeJsonString(w, p.name);
            try w.writeAll(":{");
            var first = true;
            try writeValueField(w, "v", p.to, surface, &first);
            try w.writeAll("}");
        }
        try w.writeAll("}}");
    }
    try w.writeAll("]");
}

/// Emit `"<key>":<value>` plus an optional `"u":"<unit>"` sibling. Colors
/// in string values are normalized to `{"c":[r,g,b,a]}` so the JS
/// interpreter lerps channels without its own author-format parser.
fn writeValueField(w: *std.Io.Writer, key: []const u8, v: types.Value, surface: Surface, first: *bool) anyerror!void {
    if (!first.*) try w.writeAll(",");
    first.* = false;
    switch (v) {
        .num => |n| try w.print("\"{s}\":{d}", .{ key, n }),
        .px => |n| try w.print("\"{s}\":{d},\"u\":\"px\"", .{ key, n }),
        .pct => |n| try w.print("\"{s}\":{d},\"u\":\"%\"", .{ key, n }),
        .deg => |n| try w.print("\"{s}\":{d},\"u\":\"deg\"", .{ key, n }),
        .rem => |n| try w.print("\"{s}\":{d},\"u\":\"rem\"", .{ key, n }),
        .str => |s| {
            if (util.parseColor(s)) |c| {
                try w.print("\"{s}\":{{\"c\":[{d},{d},{d},{d}]}}", .{ key, c.r, c.g, c.b, c.a });
            } else {
                try w.print("\"{s}\":", .{key});
                try writeJsonString(w, s);
            }
        },
        .dyn => |slot| {
            if (surface == .ssr) return error.DynRequiresIsland;
            try w.print("\"{s}\":{{\"dyn\":{d}}}", .{ key, slot });
        },
    }
}

fn writeStagger(w: *std.Io.Writer, s: types.Stagger) anyerror!void {
    try w.writeAll(",\"st\":{");
    var first = true;
    if (s.total) |total| {
        try w.print("\"total\":{d}", .{total});
        first = false;
    } else {
        try w.print("\"each\":{d}", .{s.each});
        first = false;
    }
    if (!first) try w.writeAll(",");
    switch (s.from) {
        .start => try w.writeAll("\"from\":\"start\""),
        .end => try w.writeAll("\"from\":\"end\""),
        .center => try w.writeAll("\"from\":\"center\""),
        .edges => try w.writeAll("\"from\":\"edges\""),
        .index => |i| try w.print("\"from\":{d}", .{i}),
    }
    if (s.grid) |g| try w.print(",\"grid\":[{d},{d}]", .{ g.cols, g.rows });
    if (s.axis) |a| try w.print(",\"axis\":\"{s}\"", .{switch (a) {
        .x => "x",
        .y => "y",
    }});
    if (s.ease) |e| {
        try w.writeAll(",\"e\":");
        try writeJsonString(w, e.wireName());
    }
    try w.writeAll("}");
}

fn writeModifiers(w: *std.Io.Writer, mods: []const types.Modifier, surface: Surface) anyerror!void {
    try w.writeAll(",\"mod\":[");
    for (mods, 0..) |m, i| {
        if (i != 0) try w.writeAll(",");
        try w.writeAll("{\"p\":");
        try writeJsonString(w, m.prop);
        switch (m.op) {
            .snap_to => |v| try w.print(",\"snap\":{d}", .{v}),
            .clamp => |c| try w.print(",\"clamp\":[{d},{d}]", .{ c.min, c.max }),
            .wrap => |c| try w.print(",\"wrap\":[{d},{d}]", .{ c.min, c.max }),
            .dyn => |slot| {
                if (surface == .ssr) return error.DynRequiresIsland;
                try w.print(",\"dyn\":{d}", .{slot});
            },
        }
        try w.writeAll("}");
    }
    try w.writeAll("]");
}

fn writeCallbacks(
    w: *std.Io.Writer,
    complete_slot: ?u32,
    start_slot: ?u32,
    repeat_slot: ?u32,
    cb_island: ?[]const u8,
    cb_complete_export: ?[]const u8,
    surface: Surface,
) anyerror!void {
    const has_slots = complete_slot != null or start_slot != null or repeat_slot != null;
    const has_export = cb_island != null and cb_complete_export != null;
    if (!has_slots and !has_export) return;
    if (has_slots and surface == .ssr) return error.CallbackSlotRequiresIsland;
    try w.writeAll(",\"cb\":{");
    var first = true;
    if (start_slot) |s| {
        try w.print("\"sS\":{d}", .{s});
        first = false;
    }
    if (complete_slot) |s| {
        if (!first) try w.writeAll(",");
        try w.print("\"sC\":{d}", .{s});
        first = false;
    }
    if (repeat_slot) |s| {
        if (!first) try w.writeAll(",");
        try w.print("\"sR\":{d}", .{s});
        first = false;
    }
    if (has_export) {
        if (!first) try w.writeAll(",");
        try w.writeAll("\"isl\":");
        try writeJsonString(w, cb_island.?);
        try w.writeAll(",\"nC\":");
        try writeJsonString(w, cb_complete_export.?);
    }
    try w.writeAll("}");
}

/// Emit the "sc" scroll-trigger object. Numeric encoding throughout —
/// the JS interpreter parses no position strings. Defaults are omitted:
/// start [0,1] ("top bottom"), end [1,0] ("bottom top"), actions
/// [1,0,0,0] ("play none none none").
fn writeScrollTrigger(w: *std.Io.Writer, sc: scroll.ScrollTrigger, surface: Surface) anyerror!void {
    try w.writeAll(",\"sc\":{");
    var first = true;
    if (sc.trigger_handle) |h| {
        if (surface == .ssr) return error.HandleRequiresIsland;
        try w.print("\"t\":{{\"h\":{d}}}", .{h});
        first = false;
    } else if (sc.trigger) |sel| {
        try w.writeAll("\"t\":{\"s\":");
        try writeJsonString(w, sel);
        try w.writeAll("}");
        first = false;
    }
    const sv = sc.start;
    if (sv.trigger.value() != 0 or sv.viewport.value() != 1 or sv.offset_px != 0) {
        try comma(w, &first);
        try writeSpecPair(w, "s", sv);
    }
    switch (sc.end) {
        .at => |e| {
            if (e.trigger.value() != 1 or e.viewport.value() != 0 or e.offset_px != 0) {
                try comma(w, &first);
                try writeSpecPair(w, "e", e);
            }
        },
        .rel_px => |px| {
            try comma(w, &first);
            try w.print("\"e\":{{\"r\":{d}}}", .{px});
        },
        .rel_vh => |vh| {
            try comma(w, &first);
            try w.print("\"e\":{{\"rv\":{d}}}", .{vh});
        },
    }
    switch (sc.scrub) {
        .off => {},
        .exact => {
            try comma(w, &first);
            try w.writeAll("\"scr\":true");
        },
        .smooth => |s| {
            try comma(w, &first);
            try w.print("\"scr\":{d}", .{s});
        },
    }
    switch (sc.pin) {
        .off => {},
        .self => {
            try comma(w, &first);
            try w.writeAll("\"pin\":1");
        },
        .selector => |s| {
            try comma(w, &first);
            try w.writeAll("\"pin\":{\"s\":");
            try writeJsonString(w, s);
            try w.writeAll("}");
        },
    }
    if (!sc.actions.isDefault()) {
        try comma(w, &first);
        try w.print("\"act\":[{d},{d},{d},{d}]", .{
            @intFromEnum(sc.actions.on_enter),
            @intFromEnum(sc.actions.on_leave),
            @intFromEnum(sc.actions.on_enter_back),
            @intFromEnum(sc.actions.on_leave_back),
        });
    }
    if (sc.once) {
        try comma(w, &first);
        try w.writeAll("\"once\":1");
    }
    if (sc.markers) {
        try comma(w, &first);
        try w.writeAll("\"mk\":1");
    }
    switch (sc.snap) {
        .none => {},
        .step => |s| {
            try comma(w, &first);
            try w.print("\"snap\":{d}", .{s});
        },
        .points => |pts| {
            try comma(w, &first);
            try w.writeAll("\"snap\":[");
            for (pts, 0..) |p, i| {
                if (i != 0) try w.writeAll(",");
                try w.print("{d}", .{p});
            }
            try w.writeAll("]");
        },
    }
    if (sc.snap != .none and sc.snap_duration != 0.4) {
        try comma(w, &first);
        try w.print("\"snapd\":{d}", .{sc.snap_duration});
    }
    if (sc.toggle_class) |c| {
        try comma(w, &first);
        try w.writeAll("\"cls\":");
        try writeJsonString(w, c);
    }
    if (sc.class_target) |c| {
        try comma(w, &first);
        try w.writeAll("\"ct\":");
        try writeJsonString(w, c);
    }
    if (sc.hasSlots() or sc.hasExports()) {
        if (sc.hasSlots() and surface == .ssr) return error.CallbackSlotRequiresIsland;
        try comma(w, &first);
        try w.writeAll("\"cb\":{");
        var cb_first = true;
        if (sc.on_enter_slot) |s| try slotField(w, &cb_first, "sE", s);
        if (sc.on_leave_slot) |s| try slotField(w, &cb_first, "sL", s);
        if (sc.on_enter_back_slot) |s| try slotField(w, &cb_first, "sEB", s);
        if (sc.on_leave_back_slot) |s| try slotField(w, &cb_first, "sLB", s);
        if (sc.on_update_slot) |s| try slotField(w, &cb_first, "sU", s);
        if (sc.hasExports()) {
            if (!cb_first) try w.writeAll(",");
            cb_first = false;
            try w.writeAll("\"isl\":");
            try writeJsonString(w, sc.cb_island.?);
            if (sc.cb_enter_export) |e| {
                try w.writeAll(",\"nE\":");
                try writeJsonString(w, e);
            }
            if (sc.cb_leave_export) |e| {
                try w.writeAll(",\"nL\":");
                try writeJsonString(w, e);
            }
        }
        try w.writeAll("}");
    }
    try w.writeAll("}");
}

fn comma(w: *std.Io.Writer, first: *bool) anyerror!void {
    if (!first.*) try w.writeAll(",");
    first.* = false;
}

fn slotField(w: *std.Io.Writer, first: *bool, key: []const u8, slot: u32) anyerror!void {
    if (!first.*) try w.writeAll(",");
    first.* = false;
    try w.print("\"{s}\":{d}", .{ key, slot });
}

fn writeSpecPair(w: *std.Io.Writer, key: []const u8, s: scroll.ScrollSpec) anyerror!void {
    if (s.offset_px != 0) {
        try w.print("\"{s}\":[{d},{d},{d}]", .{ key, s.trigger.value(), s.viewport.value(), s.offset_px });
    } else {
        try w.print("\"{s}\":[{d},{d}]", .{ key, s.trigger.value(), s.viewport.value() });
    }
}

fn writeReducedMotion(w: *std.Io.Writer, rm: types.ReducedMotion) anyerror!void {
    switch (rm) {
        .jump_to_end => {}, // wire default — omitted
        .play => try w.writeAll(",\"rm\":\"allow\""),
        .skip => try w.writeAll(",\"rm\":\"skip\""),
    }
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) anyerror!void {
    try w.writeAll("\"");
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (c < 0x20) {
            try w.print("\\u{x:0>4}", .{c});
        } else {
            try w.writeAll(&.{c});
        },
    };
    try w.writeAll("\"");
}

// ---- golden tests: the Zig <-> JS conformance contract --------------------

const testing = std.testing;

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
}

test "golden: minimal to-tween" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const t = tween_mod.to(a, ".box").x(120);
    const json = try tweenToJson(a, t, .ssr);
    try testing.expectEqualStrings(
        "{\"v\":1,\"t\":{\"s\":\".box\"},\"d\":0.5,\"e\":\"outQuad\",\"p\":{\"x\":{\"to\":120}}}",
        json,
    );
}

test "golden: multi-prop from with explicit values and id" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const t = tween_mod.from(a, null).named("card-in")
        .y(24).opacity(0)
        .duration(0.6).delay(0.1).ease(.out_cubic);
    const json = try tweenToJson(a, t, .ssr);
    try testing.expectEqualStrings(
        "{\"v\":1,\"id\":\"card-in\",\"d\":0.6,\"del\":0.1,\"e\":\"outCubic\"," ++
            "\"p\":{\"y\":{\"f\":24},\"opacity\":{\"f\":0}}}",
        json,
    );
}

test "golden: keyframed pulse with repeat and skip" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const t = tween_mod.to(a, ".pulse")
        .step(0).scale(1)
        .step(50).stepEase(.in_out_sine).scale(1.15)
        .step(100).scale(1)
        .duration(1.2).repeat(-1).reducedMotion(.skip);
    const json = try tweenToJson(a, t, .ssr);
    try testing.expectEqualStrings(
        "{\"v\":1,\"t\":{\"s\":\".pulse\"},\"d\":1.2,\"rep\":-1,\"e\":\"outQuad\"," ++
            "\"k\":[{\"o\":0,\"p\":{\"scale\":{\"v\":1}}}," ++
            "{\"o\":0.5,\"e\":\"inOutSine\",\"p\":{\"scale\":{\"v\":1.15}}}," ++
            "{\"o\":1,\"p\":{\"scale\":{\"v\":1}}}],\"rm\":\"skip\"}",
        json,
    );
}

test "golden: stagger grid + units + yoyo" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const t = tween_mod.from(a, ".card")
        .opacity(0).scale(0.9).prop("left", types.Value{ .pct = 10 })
        .duration(0.5).ease(.out_back).yoyo(true)
        .stagger(.{ .each = 0.06, .from = .center, .grid = .{ .cols = 4, .rows = 2 }, .ease = .out_quad });
    const json = try tweenToJson(a, t, .ssr);
    try testing.expectEqualStrings(
        "{\"v\":1,\"t\":{\"s\":\".card\"},\"d\":0.5,\"yo\":1,\"e\":\"outBack\"," ++
            "\"p\":{\"opacity\":{\"f\":0},\"scale\":{\"f\":0.9},\"left\":{\"f\":10,\"u\":\"%\"}}," ++
            "\"st\":{\"each\":0.06,\"from\":\"center\",\"grid\":[4,2],\"e\":\"outQuad\"}}",
        json,
    );
}

test "golden: color normalization" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const t = tween_mod.to(a, ".btn").prop("background-color", "#ff8800");
    const json = try tweenToJson(a, t, .ssr);
    try testing.expectEqualStrings(
        "{\"v\":1,\"t\":{\"s\":\".btn\"},\"d\":0.5,\"e\":\"outQuad\"," ++
            "\"p\":{\"background-color\":{\"to\":{\"c\":[255,136,0,1]}}}}",
        json,
    );
}

test "golden: modifiers and island callbacks/dyn" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const t = tween_mod.to(a, "#deck")
        .x(types.Value{ .dyn = 3 }).prop("rotate", 720)
        .modifier(.{ .prop = "rotate", .op = .{ .wrap = .{ .min = 0, .max = 360 } } })
        .modifier(.{ .prop = "x", .op = .{ .dyn = 1 } })
        .onCompleteSlot(17).onStartSlot(16);
    const json = try tweenToJson(a, t, .island);
    try testing.expectEqualStrings(
        "{\"v\":1,\"t\":{\"s\":\"#deck\"},\"d\":0.5,\"e\":\"outQuad\"," ++
            "\"p\":{\"x\":{\"to\":{\"dyn\":3}},\"rotate\":{\"to\":720}}," ++
            "\"mod\":[{\"p\":\"rotate\",\"wrap\":[0,360]},{\"p\":\"x\",\"dyn\":1}]," ++
            "\"cb\":{\"sS\":16,\"sC\":17}}",
        json,
    );
}

test "golden: timeline with labels and resolved positions" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const tl = timeline_mod.timeline(a).named("intro")
        .add(tween_mod.from(a, ".hero h1").y(40).opacity(0).duration(0.6).ease(.out_expo), .end)
        .addLabel("mid", .{ .abs = 0.8 })
        .add(tween_mod.to(a, "#cta").scale(1.05).duration(0.4), .{ .label = "mid" })
        .onCompleteExport("Hero", "introDone");
    const json = try timelineToJson(a, tl, .ssr);
    try testing.expectEqualStrings(
        "{\"v\":1,\"tl\":1,\"id\":\"intro\",\"lab\":{\"mid\":0.8}," ++
            "\"cb\":{\"isl\":\"Hero\",\"nC\":\"introDone\"},\"ch\":[" ++
            "{\"pos\":0,\"t\":{\"s\":\".hero h1\"},\"d\":0.6,\"e\":\"outExpo\"," ++
            "\"p\":{\"y\":{\"f\":40},\"opacity\":{\"f\":0}}}," ++
            "{\"pos\":0.8,\"t\":{\"s\":\"#cta\"},\"d\":0.4,\"e\":\"outQuad\"," ++
            "\"p\":{\"scale\":{\"to\":1.05}}}]}",
        json,
    );
}

test "ssr rejects island-only constructs" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();

    const dyn = tween_mod.to(a, ".x").x(types.Value{ .dyn = 0 });
    try testing.expectError(error.DynRequiresIsland, tweenToJson(a, dyn, .ssr));

    const slot = tween_mod.to(a, ".x").x(1).onCompleteSlot(5);
    try testing.expectError(error.CallbackSlotRequiresIsland, tweenToJson(a, slot, .ssr));

    const mod_dyn = tween_mod.to(a, ".x").x(1).modifier(.{ .prop = "x", .op = .{ .dyn = 2 } });
    try testing.expectError(error.DynRequiresIsland, tweenToJson(a, mod_dyn, .ssr));
}

test "golden: scroll-gated tween with class toggle and actions" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const t = tween_mod.from(a, ".card").opacity(0).y(40).duration(0.6).ease(.out_cubic)
        .scrollTrigger(.{
        .start = .{ .trigger = .top, .viewport = .{ .pct = 80 } },
        .actions = .{ .on_enter = .play, .on_leave_back = .reverse },
        .toggle_class = "in-view",
    });
    const json = try tweenToJson(a, t, .ssr);
    try testing.expectEqualStrings(
        "{\"v\":1,\"t\":{\"s\":\".card\"},\"d\":0.6,\"e\":\"outCubic\"," ++
            "\"p\":{\"opacity\":{\"f\":0},\"y\":{\"f\":40}}," ++
            "\"sc\":{\"s\":[0,0.8],\"act\":[1,0,0,4],\"cls\":\"in-view\"}}",
        json,
    );
}

test "golden: scrub + pin + rel_vh end" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const t = tween_mod.to(a, ".progress").scaleX(1).duration(1)
        .scrollTrigger(.{
        .start = .{ .viewport = .top },
        .end = .{ .rel_vh = 2 },
        .scrub = .{ .smooth = 0.4 },
        .pin = .self,
        .markers = true,
    });
    const json = try tweenToJson(a, t, .ssr);
    try testing.expectEqualStrings(
        "{\"v\":1,\"t\":{\"s\":\".progress\"},\"d\":1,\"e\":\"outQuad\"," ++
            "\"p\":{\"scaleX\":{\"to\":1}}," ++
            "\"sc\":{\"s\":[0,0],\"e\":{\"rv\":2},\"scr\":0.4,\"pin\":1,\"mk\":1}}",
        json,
    );
}

test "golden: timeline-level exact scrub" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const tl = timeline_mod.timeline(a)
        .add(tween_mod.to(a, ".panel").x(-400).duration(1), .end)
        .scrollTrigger(.{ .trigger = ".story", .scrub = .exact });
    const json = try timelineToJson(a, tl, .ssr);
    try testing.expectEqualStrings(
        "{\"v\":1,\"tl\":1,\"sc\":{\"t\":{\"s\":\".story\"},\"scr\":true}," ++
            "\"ch\":[{\"pos\":0,\"t\":{\"s\":\".panel\"},\"d\":1,\"e\":\"outQuad\"," ++
            "\"p\":{\"x\":{\"to\":-400}}}]}",
        json,
    );
}

test "golden: standalone reveal trigger (anim-less)" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const tr = scroll.reveal(a, "in-view", .{
        .start = .{ .viewport = .{ .pct = 85 } },
        .once = true,
    });
    const json = try triggerToJson(a, tr, .ssr);
    try testing.expectEqualStrings(
        "{\"v\":1,\"sc\":{\"s\":[0,0.85],\"once\":1,\"cls\":\"in-view\"}}",
        json,
    );
}

test "golden: island sc callback slots + handle trigger" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const tr = scroll.trigger(a, .{
        .trigger = "#sec",
        .on_enter_slot = 21,
        .on_leave_slot = 22,
        .on_update_slot = 23,
    });
    const json = try triggerToJson(a, tr, .island);
    try testing.expectEqualStrings(
        "{\"v\":1,\"sc\":{\"t\":{\"s\":\"#sec\"},\"cb\":{\"sE\":21,\"sL\":22,\"sU\":23}}}",
        json,
    );

    const handle_t = tween_mod.to(a, ".x").x(1)
        .scrollTrigger(.{ .trigger_handle = 12 });
    const hj = try tweenToJson(a, handle_t, .island);
    try testing.expect(std.mem.indexOf(u8, hj, "\"sc\":{\"t\":{\"h\":12}}") != null);
}

test "golden: sc named-export callbacks on SSR" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const tr = scroll.trigger(a, .{
        .trigger = "#hero",
        .cb_island = "Hero",
        .cb_enter_export = "hero_enter",
    });
    const json = try triggerToJson(a, tr, .ssr);
    try testing.expectEqualStrings(
        "{\"v\":1,\"sc\":{\"t\":{\"s\":\"#hero\"},\"cb\":{\"isl\":\"Hero\",\"nE\":\"hero_enter\"}}}",
        json,
    );
}

test "golden: scrub with full-step snap" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const t = tween_mod.to(a, ".bar").scaleX(1).duration(1)
        .scrollTrigger(.{ .scrub = .exact, .snap = .{ .step = 1 } });
    const json = try tweenToJson(a, t, .ssr);
    try testing.expect(std.mem.indexOf(u8, json, "\"sc\":{\"scr\":true,\"snap\":1}") != null);
}

test "golden: snap points + non-default duration" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const t = tween_mod.to(a, ".bar").scaleX(1).duration(1)
        .scrollTrigger(.{
        .scrub = .{ .smooth = 0.3 },
        .snap = .{ .points = &.{ 0, 0.25, 0.5, 1 } },
        .snap_duration = 0.6,
    });
    const json = try tweenToJson(a, t, .ssr);
    try testing.expect(std.mem.indexOf(u8, json, "\"snap\":[0,0.25,0.5,1],\"snapd\":0.6") != null);
}

test "golden: snap on anim-less reveal trigger" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const tr = scroll.reveal(a, "in-view", .{ .snap = .{ .step = 1 } });
    try testing.expectEqualStrings(
        "{\"v\":1,\"sc\":{\"snap\":1,\"cls\":\"in-view\"}}",
        try triggerToJson(a, tr, .ssr),
    );
}

test "snap validation defers through builder" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const t = tween_mod.to(a, ".x").x(1).scrollTrigger(.{ .snap = .{ .step = 2 } });
    try testing.expectEqual(@as(?anyerror, error.SnapStepOutOfRange), t.err);
}

test "ssr rejects sc island-only constructs" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();

    const slot_t = tween_mod.to(a, ".x").x(1).scrollTrigger(.{ .on_enter_slot = 5 });
    try testing.expectError(error.CallbackSlotRequiresIsland, tweenToJson(a, slot_t, .ssr));

    const handle_t = tween_mod.to(a, ".x").x(1).scrollTrigger(.{ .trigger_handle = 3 });
    try testing.expectError(error.HandleRequiresIsland, tweenToJson(a, handle_t, .ssr));
}

test "golden: motion path straight line, no rotate" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const t = tween_mod.to(a, ".dot").motionPath(.{ .path = "M0,0 L10,0", .samples = 3 });
    const json = try tweenToJson(a, t, .ssr);
    try testing.expectEqualStrings(
        "{\"v\":1,\"t\":{\"s\":\".dot\"},\"d\":0.5,\"e\":\"outQuad\"," ++
            "\"mp\":{\"pts\":[0,0,5,0,10,0]}}",
        json,
    );
}

test "golden: motion path with rotate + offset on a corner path" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const t = tween_mod.to(a, ".dot").motionPath(.{
        .path = "M0,0 L10,0 L10,10",
        .rotate = true,
        .rotate_offset_deg = 90,
        .samples = 3,
    });
    const json = try tweenToJson(a, t, .ssr);
    // u=0 on the horizontal leg (angle 0), u=0.5 at the corner, u=1 on
    // the vertical leg (angle 90, SVG y-down)
    try testing.expect(std.mem.indexOf(u8, json, "\"rot\":1,\"ro\":90}") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"mp\":{\"pts\":[0,0,0,") != null);
    try testing.expect(std.mem.indexOf(u8, json, ",10,10,90]") != null);
}

test "golden: motion path align start re-bases on first sample" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const t = tween_mod.to(a, ".dot").motionPath(.{
        .path = "M100,50 L110,50",
        .align_to = .start,
        .samples = 3,
    });
    const json = try tweenToJson(a, t, .ssr);
    try testing.expect(std.mem.indexOf(u8, json, "\"mp\":{\"pts\":[0,0,5,0,10,0]}") != null);
}

test "golden: morph of two lines (1/3-2/3 control contract)" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const t = tween_mod.to(a, "#shape").morph(.{ .from = "M0,0 L10,0", .to = "M0,0 L0,10" });
    const json = try tweenToJson(a, t, .ssr);
    try testing.expectEqualStrings(
        "{\"v\":1,\"t\":{\"s\":\"#shape\"},\"d\":0.5,\"e\":\"outQuad\"," ++
            "\"mo\":{\"a\":[0,0,3.33,0,6.67,0,10,0],\"b\":[0,0,0,3.33,0,6.67,0,10],\"sp\":[1]}}",
        json,
    );
}

test "golden: closed morph emits z; props alongside morph" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const t = tween_mod.to(a, "#shape")
        .morph(.{ .from = "M0,0 L10,0 L5,10 Z", .to = "M0,0 L10,0 L5,-10 Z" })
        .opacity(0.5);
    const json = try tweenToJson(a, t, .ssr);
    try testing.expect(std.mem.indexOf(u8, json, "\"p\":{\"opacity\":{\"to\":0.5}}") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"z\":[1]") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"sp\":[3]") != null);
}

test "mp/mo legal on both surfaces; bad d deferred to serialize" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();

    const t = tween_mod.to(a, ".dot").motionPath(.{ .path = "M0,0 L10,0", .samples = 2 });
    _ = try tweenToJson(a, t, .island);

    const bad = tween_mod.to(a, ".dot").motionPath(.{ .path = "garbage" });
    try testing.expectError(error.BadPath, tweenToJson(a, bad, .ssr));
    const bad2 = tween_mod.to(a, ".dot").motionPath(.{ .path = "garbage" });
    try testing.expectError(error.BadPath, tweenToJson(a, bad2, .island));

    const mismatch = tween_mod.to(a, "#s").morph(.{
        .from = "M0,0 L1,0",
        .to = "M0,0 L1,0 M2,0 L3,0",
    });
    try testing.expectError(error.SubpathCountMismatch, tweenToJson(a, mismatch, .ssr));
}

test "golden: motion path inside a timeline child" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const tl = timeline_mod.timeline(a)
        .add(tween_mod.to(a, ".dot").motionPath(.{ .path = "M0,0 L10,0", .samples = 2 }).duration(1), .end);
    const json = try timelineToJson(a, tl, .ssr);
    try testing.expect(std.mem.indexOf(u8, json, "\"ch\":[{\"pos\":0,\"t\":{\"s\":\".dot\"},\"d\":1,\"e\":\"outQuad\",\"mp\":{\"pts\":[0,0,10,0]}}]") != null);
}

test "golden: minimal drag (carrying element, all defaults)" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const d = drag_mod.draggable(a, .{});
    try testing.expectEqualStrings("{\"v\":1,\"dr\":{}}", try dragToJson(a, d, .ssr));
}

test "golden: drag axis lock + bounds rect" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const d = drag_mod.draggable(a, .{
        .axis = .x,
        .bounds = .{ .rect = .{ .min_x = 0, .max_x = 600 } },
    });
    try testing.expectEqualStrings(
        "{\"v\":1,\"dr\":{\"ax\":1,\"b\":[0,600,0,0]}}",
        try dragToJson(a, d, .ssr),
    );
}

test "golden: drag bounds selector + inertia + grid snap + class" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const d = drag_mod.draggable(a, .{
        .bounds = .{ .selector = ".pen" },
        .inertia = .on,
        .snap = .{ .grid = .{ .x = 40, .y = 40 } },
        .toggle_class = "dragging",
    });
    try testing.expectEqualStrings(
        "{\"v\":1,\"dr\":{\"b\":{\"s\":\".pen\"},\"in\":1,\"sn\":{\"g\":[40,40]},\"cls\":\"dragging\"}}",
        try dragToJson(a, d, .ssr),
    );
}

test "golden: drag target + grip + retention + snap points + threshold" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const pts = [_][2]f64{ .{ 0, 0 }, .{ 120, 80 } };
    const d = drag_mod.draggable(a, .{
        .target = ".card",
        .handle = ".grip",
        .inertia = .{ .retention = 0.3 },
        .snap = .{ .points = &pts },
        .threshold_px = 6,
        .manage_cursor = false,
    });
    try testing.expectEqualStrings(
        "{\"v\":1,\"dr\":{\"t\":{\"s\":\".card\"},\"hd\":\".grip\",\"in\":0.3," ++
            "\"sn\":{\"p\":[0,0,120,80]},\"th\":6,\"cur\":0}}",
        try dragToJson(a, d, .ssr),
    );
}

test "golden: drag island callback slots + handle target" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const d = drag_mod.draggable(a, .{
        .target_handle = 7,
        .inertia = .on,
        .on_start_slot = 21,
        .on_drag_slot = 22,
        .on_end_slot = 23,
        .on_throw_complete_slot = 24,
    });
    try testing.expectEqualStrings(
        "{\"v\":1,\"dr\":{\"t\":{\"h\":7},\"in\":1,\"cb\":{\"sS\":21,\"sD\":22,\"sE\":23,\"sT\":24}}}",
        try dragToJson(a, d, .island),
    );
}

test "golden: drag drop zones + hover class (SSR-legal)" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const d = drag_mod.draggable(a, .{
        .zones = ".dz",
        .zone_class = "drop-hover",
    });
    try testing.expectEqualStrings(
        "{\"v\":1,\"dr\":{\"zn\":\".dz\",\"znc\":\"drop-hover\"}}",
        try dragToJson(a, d, .ssr),
    );
}

test "golden: drag on_drop slot (island) + SSR rejection" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const d = drag_mod.draggable(a, .{ .zones = ".dz", .on_drop_slot = 31 });
    try testing.expectEqualStrings(
        "{\"v\":1,\"dr\":{\"zn\":\".dz\",\"cb\":{\"sZ\":31}}}",
        try dragToJson(a, d, .island),
    );

    const ssr = drag_mod.draggable(a, .{ .zones = ".dz", .on_drop_slot = 31 });
    try testing.expectError(error.CallbackSlotRequiresIsland, dragToJson(a, ssr, .ssr));
}

test "ssr rejects dr island-only constructs; validate propagates" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();

    const slots = drag_mod.draggable(a, .{ .inertia = .on, .on_end_slot = 5 });
    try testing.expectError(error.CallbackSlotRequiresIsland, dragToJson(a, slots, .ssr));

    const handle = drag_mod.draggable(a, .{ .target_handle = 3 });
    try testing.expectError(error.HandleRequiresIsland, dragToJson(a, handle, .ssr));

    const bad = drag_mod.draggable(a, .{ .bounds = .{ .rect = .{ .min_x = 9, .max_x = 1 } } });
    try testing.expectError(error.InvertedBounds, dragToJson(a, bad, .ssr));
}

test "builder error propagates through toJson" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const bad = tween_mod.to(a, ".x").opacity(1).step(0);
    try testing.expectError(error.StepAfterProps, tweenToJson(a, bad, .ssr));
}

test "selector with quotes serialized safely" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const t = tween_mod.to(a, "[data-name=\"a\"]").x(1);
    const json = try tweenToJson(a, t, .ssr);
    try testing.expect(std.mem.indexOf(u8, json, "[data-name=\\\"a\\\"]") != null);
}

// ---- gl-target wire format (gl/gls keys) ----------------------------------
// The serialized KEY is "@gl:<target_id-decimal>" (the PropEntry name stays
// "@gl" Zig-side); the value object emits gl keys FIRST then to/f. The JS
// interpreter (next task) matches on the "@gl" prefix.

test "golden: gl-target tween emits gl/gls/to" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    // 0x01000101 = 16777473 (1<<24 | 1<<8 | 1)
    const t = tween_mod.to(a, null).glTarget(0x01000101, 7, 0.8);
    const json = try tweenToJson(a, t, .island);
    try testing.expectEqualStrings(
        "{\"v\":1,\"d\":0.5,\"e\":\"outQuad\"," ++
            "\"p\":{\"@gl:16777473\":{\"gl\":16777473,\"gls\":7,\"to\":0.8}}}",
        json,
    );
}

test "golden: gl-target-from emits f alongside to" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    // glTargetFrom sets to=0 (placeholder), from=0.25 -> .to kind emits
    // "to":0 then "f":0.25.
    const t = tween_mod.to(a, null).glTargetFrom(3, 4, 0.25);
    const json = try tweenToJson(a, t, .island);
    try testing.expectEqualStrings(
        "{\"v\":1,\"d\":0.5,\"e\":\"outQuad\"," ++
            "\"p\":{\"@gl:3\":{\"gl\":3,\"gls\":4,\"to\":0,\"f\":0.25}}}",
        json,
    );
    try testing.expect(std.mem.indexOf(u8, json, "\"f\":0.25") != null);
}

test "golden: two gl-targets get distinct @gl:<id> keys" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const t = tween_mod.to(a, null).glTarget(1, 0, 1.0).glTarget(2, 1, 2.0);
    const json = try tweenToJson(a, t, .island);
    try testing.expectEqualStrings(
        "{\"v\":1,\"d\":0.5,\"e\":\"outQuad\"," ++
            "\"p\":{\"@gl:1\":{\"gl\":1,\"gls\":0,\"to\":1}," ++
            "\"@gl:2\":{\"gl\":2,\"gls\":1,\"to\":2}}}",
        json,
    );
    // both keys present, neither dropped
    try testing.expect(std.mem.indexOf(u8, json, "\"@gl:1\":") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"@gl:2\":") != null);
}

test "golden: gl props compose with normal props" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const t = tween_mod.to(a, ".card").opacity(0.5).glTarget(5, 2, 0.8);
    const json = try tweenToJson(a, t, .island);
    try testing.expectEqualStrings(
        "{\"v\":1,\"t\":{\"s\":\".card\"},\"d\":0.5,\"e\":\"outQuad\"," ++
            "\"p\":{\"opacity\":{\"to\":0.5},\"@gl:5\":{\"gl\":5,\"gls\":2,\"to\":0.8}}}",
        json,
    );
}

test "frozen: non-gl tween serializes byte-identically (regression guard)" {
    // Belt-and-braces copy of "golden: minimal to-tween" — proves the gl
    // additive path left the gl == null wire format untouched.
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const t = tween_mod.to(a, ".box").x(120);
    const json = try tweenToJson(a, t, .ssr);
    try testing.expectEqualStrings(
        "{\"v\":1,\"t\":{\"s\":\".box\"},\"d\":0.5,\"e\":\"outQuad\",\"p\":{\"x\":{\"to\":120}}}",
        json,
    );
}
