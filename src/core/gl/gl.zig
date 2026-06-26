//! verve.gl — native 3D engine (spec:
//! docs/superpowers/specs/2026-06-11-verve-gl-design.md). P1 surface:
//! math, SoA scene graph, binary command stream, unit cube. P2 adds the
//! asset pipeline: .vmesh format, PNG codec, glb parser, fixture builder.
//! Pure Zig, target-agnostic; compiles native (tests) and
//! wasm32-freestanding (island chunks import it as `gl_core`).

pub const math = @import("math.zig");
pub const scene = @import("scene.zig");
pub const command = @import("command.zig");
pub const mesh = @import("mesh.zig");
pub const vmesh = @import("vmesh.zig");
pub const venv = @import("venv.zig");
pub const tangent = @import("tangent.zig");
pub const orbit = @import("orbit.zig");
pub const ray = @import("ray.zig");
pub const bvh = @import("bvh.zig");
pub const cull = @import("cull.zig");
pub const decal = @import("decal.zig");
pub const registry = @import("registry.zig");
pub const anim_target = @import("anim_target.zig");
// Native-side asset pipeline (std.json / decoder allocations). Island
// chunks must not reference these — Zig's lazy analysis makes the bare
// import free; only actual references would pull them into wasm.
pub const png = @import("png.zig");
pub const gltf = @import("gltf.zig");
pub const hdr = @import("hdr.zig");
pub const ibl = @import("ibl.zig");
pub const fixture = @import("fixture.zig");
// LTC (Linearly Transformed Cosines) LUT data for rect area lights. Pure data
// (two [16384]f32 arrays); the native ltc gen tool imports this to pack ltc.bin.
// Lazy import — island chunks never reference it, so it stays out of the wasm.
pub const ltc_data = @import("ltc_data.zig");

pub const Scene = scene.Scene;
pub const Encoder = command.Encoder;
pub const Registry = registry.Registry;
pub const Orbit = orbit.Orbit;
pub const OrbitInput = orbit.OrbitInput;
pub const Ray = ray.Ray;

test {
    _ = math;
    _ = scene;
    _ = command;
    _ = mesh;
    _ = vmesh;
    _ = venv;
    _ = tangent;
    _ = orbit;
    _ = ray;
    _ = bvh;
    _ = cull;
    _ = decal;
    _ = registry;
    _ = anim_target;
    _ = png;
    _ = gltf;
    _ = hdr;
    _ = ibl;
    _ = fixture;
}
