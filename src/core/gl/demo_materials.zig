//! Framework demo custom shader material — wasm-safe, pure comptime.
//! Compiled into BOTH the server verve module and the gl_core wasm module
//! (both are rooted at src/core/gl/gl.zig via lazy analysis). Referenced
//! by GlSceneBuilder and (in later slices) by the GlScene wasm chunk.
//! No native-only imports; no allocators.
const gl = @import("gl.zig");

/// Holographic scanline material. All 5 hooks + custom texture:
///   vertex_displace — u_time sine wobble along Y.
///   vertex_normal   — recomputes surface normal to match displaced geometry.
///   frag_albedo     — blends PBR albedo toward `tint` along V; mixes in the
///                     noise custom texture (u_custom_tex0 / custom_tex0) at 40%.
///   frag_emissive   — u_time glow pulse tinted by `tint`.
///   frag_alpha      — dissolve driven by noise texture red channel; discards < 0.25.
///   frag_final      — animated scanline overlay.
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
    .vertex_displace = .{
        .glsl = "vrv_pos.y += sin(vrv_pos.x * 3.0 + u_time * 2.0) * 0.08;",
        .wgsl = "vrv_pos.y = vrv_pos.y + sin(vrv_pos.x * 3.0 + u_time * 2.0) * 0.08;",
    },
    .vertex_normal = .{
        .glsl = "vrv_normal = normalize(vrv_normal - vec3(3.0 * 0.08 * cos(vrv_pos.x * 3.0 + u_time * 2.0), 0.0, 0.0));",
        .wgsl = "vrv_normal = normalize(vrv_normal - vec3<f32>(3.0 * 0.08 * cos(vrv_pos.x * 3.0 + u_time * 2.0), 0.0, 0.0));",
    },
    .frag_albedo = .{
        .glsl = "vrv_albedo = mix(vrv_albedo, tint, v_uv.y); vrv_albedo = mix(vrv_albedo, texture(u_custom_tex0, v_uv).rgb, 0.4);",
        .wgsl = "vrv_albedo = mix(vrv_albedo, tint, in.uv.y); vrv_albedo = mix(vrv_albedo, textureSample(custom_tex0, samp, in.uv).rgb, 0.4);",
    },
    .frag_emissive = .{
        .glsl = "vrv_emissive = tint * (0.35 + 0.35 * sin(u_time * 3.0));",
        .wgsl = "vrv_emissive = tint * (0.35 + 0.35 * sin(u_time * 3.0));",
    },
    .frag_alpha = .{
        .glsl = "vrv_alpha = texture(u_custom_tex0, v_uv).r; if (vrv_alpha < 0.25) discard;",
        .wgsl = "vrv_alpha = textureSample(custom_tex0, samp, in.uv).r; if (vrv_alpha < 0.25) { discard; }",
    },
    .frag_final = .{
        .glsl = "vrv_color = vrv_color + tint * (0.5 + 0.5 * sin(u_time * 2.0 + v_world_pos.y * 4.0));",
        .wgsl = "vrv_color = vrv_color + tint * (0.5 + 0.5 * sin(u_time * 2.0 + in.world_pos.y * 4.0));",
    },
    .uniforms = .{ .tint = gl.Vec3 },
    .textures = .{ .noise = .{ .url = "/gl/demo.tex0.png" } },
});
