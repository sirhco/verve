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

fn introHandle() verve.AnimHandle {
    return .{ .id = intro_id };
}

fn onIntroDone() void {
    verve.signalSetStr(STATUS, "intro complete");
}

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = props_ptr;
    _ = props_len;
    _ = root_id;
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

// Imperative MorphSVG (phase 3): build a morph tween in the chunk arena
// per click, alternating direction. Demonstrates path math running
// wasm-side — prepareMorph executes in the chunk at animPlay.

const STAR: []const u8 =
    "M50,5 L61,38 L95,38 L67,58 L78,91 L50,71 L22,91 L33,58 L5,38 L39,38 Z";
const BLOB: []const u8 =
    "M10,50 A40,40 0 0 1 90,50 A40,40 0 0 1 10,50 Z";

var island_morphed = false;

export fn anim_morph_toggle() void {
    const mark = verve.chunkArenaMark();
    defer verve.chunkArenaReset(mark);
    const a = verve.chunkArena();

    const t = anim.to(a, "#morph-island")
        .morph(if (island_morphed)
            .{ .from = BLOB, .to = STAR }
        else
            .{ .from = STAR, .to = BLOB })
        .duration(0.8).ease(.in_out_sine);
    if (verve.animPlay(t) == null) return;
    island_morphed = !island_morphed;
    verve.signalSetStr(STATUS, if (island_morphed) "morphed to circle" else "morphed to star");
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
