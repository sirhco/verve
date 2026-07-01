//! Framework demo custom shader material — wasm-safe, pure comptime.
//! Compiled into BOTH the server verve module and the gl_core wasm module
//! (both are rooted at src/core/gl/gl.zig via lazy analysis). Referenced
//! by GlSceneBuilder and (in later slices) by the GlScene wasm chunk.
//! No native-only imports; no allocators.
const gl = @import("gl.zig");

/// Holographic scanline material. Blends the PBR albedo toward `tint`
/// along the V axis (frag_albedo hook) and adds a time-animated scanline
/// pulse in the final-color hook.
///
/// Uniform layout (std140 lane order):
///   params[0].xyz = tint  (vec3, vec4_index 0, lanes x/y/z; lane w = pad)
///
/// A Vec3 occupies a FULL vec4 slot (4 floats, lane 3 = padding) in std140.
/// Pass the packed lanes, padding lane 3:
///   `GlSceneBuilder.material(gl.example_holo, &.{ r, g, b, 0 })`.
/// (Multi-uniform materials must pad each Vec3/Vec4 to its 4-float slot — the
/// chunk's data-glmat parser reads floats straight into params[] by lane.)
pub const example_holo = gl.Material(.{
    .frag_albedo = .{
        .glsl = "vrv_albedo = mix(vrv_albedo, tint, v_uv.y);",
        .wgsl = "vrv_albedo = mix(vrv_albedo, tint, in.uv.y);",
    },
    .frag_final = .{
        .glsl = "vrv_color = vrv_color + tint * (0.5 + 0.5 * sin(u_time * 2.0 + v_world_pos.y * 4.0));",
        .wgsl = "vrv_color = vrv_color + tint * (0.5 + 0.5 * sin(u_time * 2.0 + in.world_pos.y * 4.0));",
    },
    .uniforms = .{ .tint = gl.Vec3 },
});
