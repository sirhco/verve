//! verve.gl — native 3D engine (spec:
//! docs/superpowers/specs/2026-06-11-verve-gl-design.md). P1 surface:
//! math, SoA scene graph, binary command stream, unit cube. Pure Zig,
//! target-agnostic; compiles native (tests) and wasm32-freestanding
//! (island chunks import it as `gl_core`).

pub const math = @import("math.zig");
pub const scene = @import("scene.zig");
pub const command = @import("command.zig");
pub const mesh = @import("mesh.zig");

pub const Scene = scene.Scene;
pub const Encoder = command.Encoder;

test {
    _ = math;
    _ = scene;
    _ = command;
    _ = mesh;
}
