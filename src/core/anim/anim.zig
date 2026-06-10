//! verve.anim — descriptor-building animation engine. Zig builds and
//! serializes tween/timeline descriptors; the verve.js interpreter runs
//! the rAF loop and writes styles. See docs/23-animation.md.
//!
//! Two authoring surfaces:
//!   - SSR declarative: `node.animate(anim.from(ctx.allocator, null)...)`
//!     stamps a `data-anim` attribute the bridge auto-runs after hydrate.
//!   - Island imperative: build with the chunk arena, hand to
//!     `verve.animPlay(...)`, control via the returned `AnimHandle`.
//!
//! Target-agnostic: every file here compiles native and
//! wasm32-freestanding. Island chunks import this surface as `anim_core`
//! (see client_core.zig).

pub const types = @import("types.zig");
pub const Ease = types.Ease;
pub const Value = types.Value;
pub const ReducedMotion = types.ReducedMotion;
pub const Stagger = types.Stagger;
pub const Position = types.Position;
pub const Modifier = types.Modifier;
pub const value = types.value;

pub const Tween = @import("tween.zig").Tween;
pub const Timeline = @import("timeline.zig").Timeline;
pub const to = @import("tween.zig").to;
pub const from = @import("tween.zig").from;
pub const timeline = @import("timeline.zig").timeline;

pub const serialize = @import("serialize.zig");
pub const ease = @import("ease.zig");
pub const staggerDelay = @import("stagger.zig").delayFor;

// Math utilities (also re-exported flat for ergonomics).
pub const util = @import("util.zig");
pub const clamp = util.clamp;
pub const lerp = util.lerp;
pub const mapRange = util.mapRange;
pub const interpolate = util.interpolate;
pub const interpolateColor = util.interpolateColor;
pub const Color = util.Color;
pub const parseColor = util.parseColor;
pub const snap = util.snap;
pub const wrap = util.wrap;
pub const pipe = util.pipe;

test {
    _ = types;
    _ = @import("ease.zig");
    _ = @import("util.zig");
    _ = @import("stagger.zig");
    _ = @import("tween.zig");
    _ = @import("timeline.zig");
    _ = @import("serialize.zig");
}
