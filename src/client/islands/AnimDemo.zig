//! verve.anim demo island — exercises the imperative animation surface:
//! a named timeline with a staggered entrance, control buttons
//! (pause/play/reverse/restart/timeScale), an onComplete callback into a
//! signal, and a dynamic-value + fn-modifier tween.
//!
//! Descriptors are built in the chunk arena and serialized at
//! `animPlay`; the JS interpreter copies the bytes at the boundary, so
//! the arena resets immediately after. Only the plain-u32 handle id
//! survives in chunk static state.

const std = @import("std");
const verve = @import("verve");
const anim = verve.anim;

const STATUS: []const u8 = "anim_status";

/// Live timeline handle id (0 = none yet). Plain u32 — safe across frames.
var intro_id: u32 = 0;
/// Standalone scroll-trigger + observer handle ids (phase 2 demo).
var probe_id: u32 = 0;
var obs_id: u32 = 0;
/// Island vid from hydrate — needed to vid-suffix bind names for
/// listDiff (signals auto-scope; the keyed reconciler does NOT).
var island_vid: u32 = 0;

fn introHandle() verve.AnimHandle {
    return .{ .id = intro_id };
}

fn onIntroDone() void {
    verve.signalSetStr(STATUS, "intro complete");
}

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = props_ptr;
    _ = props_len;
    island_vid = root_id;
    verve.registerStr(STATUS, "playing intro");

    const mark = verve.chunkArenaMark();
    defer verve.chunkArenaReset(mark);
    const a = verve.chunkArena();

    const title = anim.from(a, ".anim-title")
        .opacity(0).y(-16)
        .duration(0.4).ease(.out_cubic);
    const cards = verve.animOnComplete(
        anim.from(a, ".anim-card")
            .opacity(0).y(30).scale(0.92)
            .duration(0.55).ease(.out_back)
            .stagger(.{ .each = 0.08, .from = .center }),
        &onIntroDone,
    );
    const tl = anim.timeline(a).named("anim-intro")
        .add(title, .end)
        .add(cards, .{ .rel = -0.15 });

    const h = verve.animPlay(tl) orelse return;
    intro_id = h.id;

    // Phase 2: standalone scroll trigger with wasm callbacks on the
    // #scroll-probe block, plus a wheel/touch Observer velocity readout.
    verve.registerStr("scroll_state", "scroll down…");
    verve.registerStr("scroll_prog", "0%");
    verve.registerStr("obs_vel", "0 px/s");
    if (verve.scrollTrigger(.{ .trigger = "#scroll-probe" }, .{
        .on_enter = &onProbeEnter,
        .on_leave = &onProbeLeave,
        .on_leave_back = &onProbeLeave,
        .on_update = &onProbeUpdate,
    })) |st| probe_id = st.id;
    if (verve.observe(.{ .wheel = true, .touch = true }, &onObserved)) |ob| obs_id = ob.id;

    verve.registerStr("drag_state", "idle");
    verve.registerStr("drag_pos", "0, 0");
    verve.registerStr("drag_vel", "0 px/s");
    if (verve.draggable(.{
        .target = "#drag-probe",
        .inertia = .on,
        .zones = ".drop-zone",
        .zone_class = "drop-hover",
    }, .{
        .on_start = &onDragStart,
        .on_drag = &onDragMove,
        .on_end = &onDragEnd,
        .on_throw_complete = &onThrowDone,
        .on_drop = &onDrop,
    })) |dh| drag_id = dh.id;
}

fn onProbeEnter() void {
    verve.signalSetStr("scroll_state", "probe in view");
}

fn onProbeLeave() void {
    verve.signalSetStr("scroll_state", "probe out of view");
}

fn onProbeUpdate() void {
    const st: verve.ScrollTriggerHandle = .{ .id = probe_id };
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d:.0}%", .{st.progress() * 100.0}) catch return;
    verve.signalSetStr("scroll_prog", s);
}

fn onObserved() void {
    const ob: verve.ObserverHandle = .{ .id = obs_id };
    var buf: [48]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d:.0} px/s", .{ob.velocityY()}) catch return;
    verve.signalSetStr("obs_vel", s);
}

// Imperative MorphSVG (phase 3 + phase 7 morph-from-current): read the
// path's LIVE d via refGetAttrArena and morph FROM it — no authored
// from-string bookkeeping. prepareMorph executes in the chunk at
// animPlay.

const STAR: []const u8 =
    "M50,5 L61,38 L95,38 L67,58 L78,91 L50,71 L22,91 L33,58 L5,38 L39,38 Z";
const BLOB: []const u8 =
    "M10,50 A40,40 0 0 1 90,50 A40,40 0 0 1 10,50 Z";

var island_morphed = false;

// Imperative Draggable (phase 4): callbacks stream state into signals;
// position/velocity read through the DragHandle.

var drag_id: u32 = 0;

fn dragHandle() verve.DragHandle {
    return .{ .id = drag_id };
}

fn onDragStart() void {
    verve.signalSetStr("drag_state", "dragging");
}

fn onDragMove() void {
    const dh = dragHandle();
    var buf: [48]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d:.0}, {d:.0}", .{ dh.x(), dh.y() }) catch return;
    verve.signalSetStr("drag_pos", s);
    var vbuf: [48]u8 = undefined;
    const v = std.fmt.bufPrint(&vbuf, "{d:.0} px/s", .{dh.velocityX()}) catch return;
    verve.signalSetStr("drag_vel", v);
}

fn onDragEnd() void {
    verve.signalSetStr("drag_state", "released");
}

fn onThrowDone() void {
    verve.signalSetStr("drag_state", "settled");
}

fn onDrop() void {
    const dh = dragHandle();
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "dropped in zone {d}", .{dh.dropZone()}) catch return;
    verve.signalSetStr("drag_state", s);
}

// FLIP shuffle (phase 5): capture the grid, reorder it through the keyed
// reconciler (all keys persist => moves only, so the html slices are
// never read — the listDiff invariant this demo relies on), then play.

var flip_keys = [8][]const u8{ "c1", "c2", "c3", "c4", "c5", "c6", "c7", "c8" };
/// How many of flip_keys are currently in the DOM (the remove/restore
/// toggle drops/re-adds the last one).
var flip_count: usize = 8;
var rng_state: u32 = 0x9e3779b9;

fn xorshift() u32 {
    var x = rng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    rng_state = x;
    return x;
}

fn onFlipDone() void {
    verve.signalSetStr(STATUS, "shuffle settled");
}

/// listDiff bind names are NOT vid-scoped automatically — the SSR
/// rewrote this island's z-bind to "flip_list__v<vid>", so suffix it
/// ourselves (VizGraphInteractive's vidName precedent).
fn flipBind(buf: []u8) ?[]const u8 {
    if (island_vid == 0) return "flip_list";
    return std.fmt.bufPrint(buf, "flip_list__v{d}", .{island_vid}) catch null;
}

export fn anim_shuffle() void {
    const state = verve.flipCapture(".flip-grid .fcard") orelse return;

    var old: [8][]const u8 = undefined;
    @memcpy(old[0..flip_count], flip_keys[0..flip_count]);
    // Fisher-Yates over the present keys
    var i: usize = flip_count - 1;
    while (i > 0) : (i -= 1) {
        const j = xorshift() % @as(u32, @intCast(i + 1));
        const tmp = flip_keys[i];
        flip_keys[i] = flip_keys[j];
        flip_keys[j] = tmp;
    }
    const empty_html = [8][]const u8{ "", "", "", "", "", "", "", "" };
    var bind_buf: [48]u8 = undefined;
    const bind = flipBind(&bind_buf) orelse return;
    verve.listDiff(bind, old[0..flip_count], flip_keys[0..flip_count], empty_html[0..flip_count]);

    if (verve.flipPlay(state, .{
        .duration = 0.45,
        .ease = .out_cubic,
        .stagger = 0.015,
    }, .{ .on_complete = &onFlipDone }) == null) return;
    verve.signalSetStr(STATUS, "shuffling…");
}

// Remove/restore the last card through the keyed reconciler — exercises
// the FLIP enter/leave callbacks and the entered-element fade-in path
// the shuffle never hits.

fn onCardLeft() void {
    verve.signalSetStr(STATUS, "card left");
}

fn onCardEntered() void {
    verve.signalSetStr(STATUS, "card entered (fading in)");
}

export fn anim_flip_card_toggle() void {
    const state = verve.flipCapture(".flip-grid .fcard") orelse return;

    var old: [8][]const u8 = undefined;
    @memcpy(old[0..flip_count], flip_keys[0..flip_count]);
    var html = [8][]const u8{ "", "", "", "", "", "", "", "" };

    if (flip_count == 8) {
        // remove the last present key
        flip_count = 7;
    } else {
        // restore: re-create needs the card's HTML (insert op)
        flip_count = 8;
        var hbuf: [96]u8 = undefined;
        const k = flip_keys[7];
        html[7] = std.fmt.bufPrint(
            &hbuf,
            "<div class=\"anim-card fcard\" data-vkey=\"{s}\">{s}</div>",
            .{ k, k[1..] },
        ) catch return;
    }

    var bind_buf: [48]u8 = undefined;
    const bind = flipBind(&bind_buf) orelse return;
    const old_count: usize = if (flip_count == 7) 8 else 7;
    verve.listDiff(bind, old[0..old_count], flip_keys[0..flip_count], html[0..flip_count]);

    _ = verve.flipPlay(state, .{
        .duration = 0.4,
        .ease = .out_cubic,
        .stagger = 0.01,
    }, .{ .on_enter = &onCardEntered, .on_leave = &onCardLeft });
}

export fn anim_morph_toggle() void {
    const mark = verve.chunkArenaMark();
    defer verve.chunkArenaReset(mark);
    const a = verve.chunkArena();

    // morph-from-current: the FROM is whatever the path looks like NOW
    // (mid-morph clicks morph from the in-flight shape). Pass the RAW
    // data-ref id — verve.queryRef auto-scopes it to this island's vid
    // (unlike listDiff, which needs manual suffixing).
    const h = verve.queryRef(@as([]const u8, "morph-path")) orelse return;
    const current = verve.refGetAttrArena(h, "d") orelse return;
    const target: []const u8 = if (island_morphed) STAR else BLOB;
    const t = anim.to(a, "#morph-island")
        .morph(.{ .from = current, .to = target })
        .duration(0.8).ease(.in_out_sine);
    if (verve.animPlay(t) == null) return;
    island_morphed = !island_morphed;
    verve.signalSetStr(STATUS, if (island_morphed) "morphing to circle" else "morphing to star");
}

// Control buttons — stamped via `z-on-click="<export>"` in the SSR'd
// island content; the bridge dispatches them to this chunk directly.

export fn anim_pause() void {
    introHandle().pause();
    verve.signalSetStr(STATUS, "paused");
}

export fn anim_play() void {
    introHandle().play();
    verve.signalSetStr(STATUS, "playing");
}

export fn anim_reverse() void {
    introHandle().reverse();
    verve.signalSetStr(STATUS, "reversed");
}

export fn anim_restart() void {
    introHandle().restart();
    verve.signalSetStr(STATUS, "restarted");
}

export fn anim_half_speed() void {
    introHandle().timeScale(0.5);
    verve.signalSetStr(STATUS, "0.5x");
}

export fn anim_full_speed() void {
    introHandle().timeScale(1.0);
    verve.signalSetStr(STATUS, "1x");
}

// Dynamic value: per-card end offset, evaluated per target at tween
// start. Fn modifier: snap the interpolated x to an 8px grid each frame.

fn slideX(i: u32, n: u32) f64 {
    _ = n;
    return 24.0 * (@as(f64, @floatFromInt(i)) + 1.0);
}

fn snapTo8(v: f64) f64 {
    return anim.snap(v, 8.0);
}

export fn anim_scatter() void {
    const mark = verve.chunkArenaMark();
    defer verve.chunkArenaReset(mark);
    const a = verve.chunkArena();

    const t = anim.to(a, ".anim-card")
        .x(verve.animDyn(&slideX))
        .duration(0.6).ease(.in_out_quad)
        .yoyo(true).repeat(1)
        .modifier(verve.animModFn("x", &snapTo8));
    _ = verve.animPlay(t);
    verve.signalSetStr(STATUS, "scatter (dyn + snap modifier)");
}
