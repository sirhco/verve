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

/// Which authoring surface is serializing. SSR rejects island-only
/// constructs (dynamic values, fn modifiers, ref-handle targets, callback
/// slots) — those reference wasm-side tables that don't exist for a
/// server-rendered descriptor.
pub const Surface = enum { ssr, island };

pub fn tweenToJson(alloc: std.mem.Allocator, t: *const tween_mod.Tween, surface: Surface) ![]const u8 {
    if (t.err) |e| return e;
    return grow(alloc, t, surface, writeTweenRoot);
}

pub fn timelineToJson(alloc: std.mem.Allocator, tl: *const timeline_mod.Timeline, surface: Surface) ![]const u8 {
    if (tl.err) |e| return e;
    return grow(alloc, tl, surface, writeTimelineRoot);
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

fn writeTweenRoot(w: *std.Io.Writer, t: *const tween_mod.Tween, surface: Surface) anyerror!void {
    try w.writeAll("{\"v\":1");
    try writeTweenBody(w, t, surface, null);
    try w.writeAll("}");
}

fn writeTimelineRoot(w: *std.Io.Writer, tl: *const timeline_mod.Timeline, surface: Surface) anyerror!void {
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
    try w.writeAll(",\"ch\":[");
    for (tl.entries.items, 0..) |e, i| {
        if (i != 0) try w.writeAll(",");
        if (!std.math.isFinite(e.start_s)) return error.InfinitePosition;
        try w.print("{{\"pos\":{d}", .{e.start_s});
        try writeTweenBody(w, e.tween, surface, e.start_s);
        try w.writeAll("}");
    }
    try w.writeAll("]}");
}

fn writeTweenBody(w: *std.Io.Writer, t: *const tween_mod.Tween, surface: Surface, pos: ?f64) anyerror!void {
    _ = pos;
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
    } else {
        try writeProps(w, t, surface);
    }

    if (t.stagger_opts) |s| try writeStagger(w, s);
    if (t.modifiers.items.len > 0) try writeModifiers(w, t.modifiers.items, surface);
    try writeCallbacks(w, t.on_complete_slot, t.on_start_slot, t.on_repeat_slot, t.cb_island, t.cb_complete_export, surface);
    try writeReducedMotion(w, t.reduced);
    if (!t.autoplay) try w.writeAll(",\"auto\":0");
}

fn writeProps(w: *std.Io.Writer, t: *const tween_mod.Tween, surface: Surface) anyerror!void {
    try w.writeAll(",\"p\":{");
    for (t.props.items, 0..) |p, i| {
        if (i != 0) try w.writeAll(",");
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
