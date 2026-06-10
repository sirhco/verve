//! verve.anim demo island — exercises the imperative animation surface:
//! a named timeline with a staggered entrance, control buttons
//! (pause/play/reverse/restart/timeScale), an onComplete callback into a
//! signal, and a dynamic-value + fn-modifier tween.
//!
//! Descriptors are built in the chunk arena and serialized at
//! `animPlay`; the JS interpreter copies the bytes at the boundary, so
//! the arena resets immediately after. Only the plain-u32 handle id
//! survives in chunk static state.

const verve = @import("verve");
const anim = verve.anim;

const STATUS: []const u8 = "anim_status";

/// Live timeline handle id (0 = none yet). Plain u32 — safe across frames.
var intro_id: u32 = 0;

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
