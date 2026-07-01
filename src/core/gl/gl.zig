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
pub const material = @import("material.zig");
pub const demo_materials = @import("demo_materials.zig");
/// Pure-Zig BC7 mode-6 texture encoder (KTX2/BC7 compressed-texture pipeline).
/// Build/comptime + native-test only; no runtime/wasm references.
pub const bc7 = @import("bc7.zig");
/// Minimal KTX2 container writer + reader wrapping BC7 mip levels.
/// Build/comptime + native-test only; no runtime/wasm references.
pub const ktx2 = @import("ktx2.zig");
/// PNG → BC7 → KTX2 pipeline helper used by gl_asset_gen to emit `.ktx2`
/// siblings next to externalized textures. Build/test only; no runtime/wasm.
pub const tex_encode = @import("tex_encode.zig");
/// Framework demo holographic custom material. Importable from app code
/// and wasm chunks. Provides a comptime `MaterialDesc` with a non-zero `.id`
/// (fnv32 of its assembled shader source) and `.flags == variant_pbr | variant_custom`.
pub const example_holo = demo_materials.example_holo;

pub const Scene = scene.Scene;
pub const Encoder = command.Encoder;
pub const Registry = registry.Registry;
pub const Orbit = orbit.Orbit;
pub const OrbitInput = orbit.OrbitInput;
pub const Ray = ray.Ray;
pub const Material = material.Material;
pub const MaterialDesc = material.MaterialDesc;
pub const UniformSlot = material.UniformSlot;
pub const UniformKind = material.UniformKind;
pub const TextureRef = material.TextureRef;
pub const Vec2 = math.Vec2;
pub const Vec3 = math.Vec3;
pub const Vec4 = math.Vec4;

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
    _ = material;
    _ = demo_materials;
    _ = bc7;
    _ = ktx2;
    _ = tex_encode;
}
