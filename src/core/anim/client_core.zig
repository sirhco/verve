//! `anim_core` — the wasm32-freestanding module root island chunks import
//! for animation building (wired in build.zig next to viz_core). Same
//! surface as anim.zig; kept as a separate root so the chunk build is the
//! regression gate that nothing here drags in renderer/server code.
//!
//! Freestanding constraints (same contract as viz/client_core.zig): no
//! node.zig/context.zig imports, allocator always a parameter, and no
//! `std.fmt.allocPrint` / `Writer.Allocating` in any code path — the
//! address-taken drain collides with the shared indirect function table.

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
