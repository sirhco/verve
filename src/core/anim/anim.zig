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

// MotionPath + MorphSVG (phase 3): SVG path math (parser, cubic
// normalization, arc-length sampling, morph matching) — all Zig-side.
pub const path = @import("path.zig");
pub const MotionPath = types.MotionPath;
pub const Morph = types.Morph;

// SplitText (phase 5): server-side text splitting into animatable spans.
// (SSR-only — operates on *Node; not re-exported from client_core.)
pub const split = @import("split.zig");

// FLIP (phase 5): play-options for layout-change animation (island-only;
// capture/play via verve.flipCapture/flipPlay in the client runtime).
pub const flip = @import("flip.zig");
pub const FlipOpts = flip.FlipOpts;

// Draggable (phase 4): pointer drag with grip/axis/bounds/snap/inertia.
pub const drag = @import("drag.zig");
pub const Draggable = drag.Draggable;
pub const DragAxis = drag.Axis;
pub const DragBounds = drag.Bounds;
pub const DragInertia = drag.Inertia;
pub const DragSnap = drag.Snap;
pub const draggable = drag.draggable;

// ScrollTrigger (phase 2): gate/scrub/pin animations by scroll position.
pub const scroll = @import("scroll.zig");
pub const ScrollTrigger = scroll.ScrollTrigger;
pub const ScrollSpec = scroll.ScrollSpec;
pub const Frac = scroll.Frac;
pub const EndSpec = scroll.EndSpec;
pub const Scrub = scroll.Scrub;
pub const Pin = scroll.Pin;
pub const Action = scroll.Action;
pub const ToggleActions = scroll.ToggleActions;
pub const reveal = scroll.reveal;

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
    _ = @import("scroll.zig");
    _ = @import("path.zig");
    _ = @import("drag.zig");
    _ = @import("split.zig");
    _ = @import("flip.zig");
}
