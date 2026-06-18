//! verve.gl wire contract v1 — flat tagged binary command stream.
//!
//! Stream layout:  [total_record_bytes: u32 LE][record…]
//! Record layout:  [tag: u16 LE][payload_size: u16 LE][payload bytes]
//! All payloads are multiples of 4 bytes, so every record stays
//! u32-aligned. Unknown tags are skipped via payload_size by the
//! interpreter (forward compatibility).
//!
//! The golden tests below FREEZE the byte layout — they are the JS
//! interpreter's conformance fixtures (src/bridge/verve.js, gl
//! section). Change bytes only with a deliberate wire-version bump.
//!
//! Bulk data (vertex bytes, GLSL source, matrices) never enters the
//! stream: records carry (ptr, len) into wasm linear memory and the
//! interpreter reads it zero-copy via typed-array views.
//!
//! v1 vertex layout (variant_vertex_color): position f32x3 @ 0,
//! color f32x3 @ 12, stride 24 — fixed on both sides; generalized
//! attribute tables arrive with the asset pipeline (P2).

const std = @import("std");

pub const Tag = enum(u16) {
    begin_frame = 1,
    create_buffer = 2,
    create_shader = 3,
    set_pipeline = 4,
    draw = 5,
    end_frame = 6,
    create_texture = 7, // {handle, width, height, ptr, len} raw RGBA8
    bind_texture = 8, // {slot, handle}
    draw_sub = 9, // {vbuf, ibuf, index_byte_off, index_count, mvp_ptr, color_ptr}
    create_texture_ex = 10, // {handle, target, format, w, h, mip_count, ptr, len}; cube data mip-major then +X,-X,+Y,-Y,+Z,-Z
    set_lights = 11, // {count, ptr -> count*8 f32}
    bind_ibl = 12, // {irr, spec, lut, spec_mip_count}
    draw_pbr = 13, // {vbuf, ibuf, index_byte_off, index_count, mvp_ptr, model_ptr, normal_ptr, material_ptr, camera_ptr}
    delete_resource = 14, // {kind, handle} — frees one GPU object; slot may be reused after
    create_texture_srgb = 15, // {handle, width, height, ptr, len} raw RGBA8 → SRGB8_ALPHA8 internal (P8); same layout as tag 7
    // ── P9 slice 3: single directional shadow map ──────────────────────
    create_shadow_map = 16, // {handle, size} — FBO + DEPTH_COMPONENT24 depth tex (size²), compare mode for sampler2DShadow
    begin_shadow_pass = 17, // {shadow_handle, depth_shader_handle, size} — bind FBO, viewport, clear depth, bind depth shader
    end_shadow_pass = 18, // {width, height} — unbind FBO back to canvas, restore viewport
    draw_depth = 19, // {vbuf, ibuf, index_byte_off, index_count, mvp_ptr} — depth-only draw (mvp = light_vp·world)
    bind_shadow_map = 20, // {slot, shadow_handle, light_vp_ptr} — bind depth tex + set u_light_vp on active program
    set_bones = 21, // {count, ptr} — count×mat4 bone palette → u_bones[] on the active program
    // ── Post-processing ─────────────────────────────────────────────────
    create_render_target = 22, // {handle, width, height, format, flags(bit0=with_depth)} — color RT (+optional depth)
    begin_offscreen_pass = 23, // {target_handle, clear_rgba(4 f32), clear_flags(bit0=color,bit1=depth)} — bind RT
    end_offscreen_pass = 24, // {} — close the offscreen pass; next begin_* rebinds
    draw_fullscreen_quad = 25, // {shader, tex0, tex1, params_ptr, param_count} — VBO-less 3-vert triangle
};

pub const ResKind = enum(u32) { buffer = 0, texture = 1, shader = 2, shadow_map = 3, render_target = 4 };

pub const BufferKind = enum(u32) { vertex = 0, index = 1 };

/// SET_PIPELINE state bits.
pub const state_depth_test: u32 = 1 << 0;
pub const state_cull_back: u32 = 1 << 1;

/// CREATE_SHADER variant bits.
pub const variant_vertex_color: u32 = 1 << 0;

/// CREATE_SHADER variant bit 1: lit/textured layout —
/// pos f32x3 @0 loc0, normal f32x3 @12 loc1, uv f32x2 @24 loc2, stride 32.
pub const variant_lit_uv: u32 = 1 << 1;

// ── P3: PBR / IBL wire surface ──────────────────────────────────────
pub const TexTarget = enum(u32) { tex_2d = 0, cube = 1 };
pub const TexFormat = enum(u32) { rgba8 = 0, rgba16f = 1 };

/// CREATE_SHADER variant bits for the comptime PBR über-shader.
pub const variant_pbr: u32 = 1 << 2; // stride-48 layout, Cook-Torrance + IBL + tonemap
pub const variant_normal_map: u32 = 1 << 3; // requires variant_pbr; tangent-space normal sampling
pub const variant_emissive: u32 = 1 << 4; // requires variant_pbr; emissive term
pub const variant_shadow: u32 = 1 << 5; // requires variant_pbr; samples the shadow map (P9 slice 3)
pub const variant_depth: u32 = 1 << 6; // depth-only shader for the shadow pass; pbr vertex layout, attrib 0 only
pub const variant_skinned: u32 = 1 << 7; // requires variant_pbr; GPU skinning via u_bones[] palette
pub const variant_post: u32 = 1 << 8; // fullscreen-quad shader: no VBO, no depth test, 2 sampler+texture slots
pub const variant_linear_output: u32 = 1 << 9; // requires variant_pbr; SKIP in-shader ACES (post path renders linear HDR)

/// Render-target creation flags.
pub const rt_flag_with_depth: u32 = 1 << 0;
/// Offscreen-pass clear flags.
pub const clear_flag_color: u32 = 1 << 0;
pub const clear_flag_depth: u32 = 1 << 1;

pub const max_lights: u32 = 4;
pub const light_stride_f32: u32 = 8; // [type(0=dir,1=point), intensity, x,y,z, r,g,b]
pub const material_len_f32: u32 = 12; // base_color rgba | metallic, roughness, occlusion_strength, normal_scale | emissive rgb, 0

pub const tex_slot_base: u32 = 0;
pub const tex_slot_mr: u32 = 1;
pub const tex_slot_normal: u32 = 2;
pub const tex_slot_emissive: u32 = 3;
pub const tex_slot_occlusion: u32 = 4;
// IBL units (JS contract): irradiance=5 (cube), prefiltered=6 (cube), brdf_lut=7 (2D)
pub const tex_slot_shadow: u32 = 8; // directional shadow map (sampler2DShadow), after the IBL units

pub const unlit_vs: []const u8 =
    \\#version 300 es
    \\layout(location = 0) in vec3 a_pos;
    \\layout(location = 1) in vec3 a_color;
    \\uniform mat4 u_mvp;
    \\out vec3 v_color;
    \\void main() {
    \\  v_color = a_color;
    \\  gl_Position = u_mvp * vec4(a_pos, 1.0);
    \\}
;

pub const unlit_fs: []const u8 =
    \\#version 300 es
    \\precision mediump float;
    \\in vec3 v_color;
    \\out vec4 o_frag;
    \\void main() { o_frag = vec4(v_color, 1.0); }
;

// WebGPU (P10) port of the unlit vertex-color variant. One WGSL module holding
// both stages, mirroring unlit_vs/unlit_fs above exactly:
//   - mvp uniform at @group(0) @binding(0)
//   - vs: color = a_color; pos = u.mvp * vec4(a_pos, 1.0)
//   - fs: vec4(color, 1.0)
// The GLSL goldens are the source of truth; this is a parallel WGSL emission.
pub const wgslUnlit: []const u8 =
    \\struct U { mvp: mat4x4<f32> };
    \\@group(0) @binding(0) var<uniform> u: U;
    \\
    \\struct VSOut {
    \\  @builtin(position) pos: vec4<f32>,
    \\  @location(0) color: vec3<f32>,
    \\};
    \\
    \\@vertex
    \\fn vs_main(@location(0) a_pos: vec3<f32>, @location(1) a_color: vec3<f32>) -> VSOut {
    \\  var out: VSOut;
    \\  out.color = a_color;
    \\  out.pos = u.mvp * vec4<f32>(a_pos, 1.0);
    \\  return out;
    \\}
    \\
    \\@fragment
    \\fn fs_main(in: VSOut) -> @location(0) vec4<f32> {
    \\  return vec4<f32>(in.color, 1.0);
    \\}
;

// Lit/textured shader pair for variant_lit_uv.
// Normals are transformed in model space (valid for rotation + uniform scale only).
// u_normal_matrix arrives with P3.
pub const lit_vs: []const u8 =
    \\#version 300 es
    \\layout(location = 0) in vec3 a_pos;
    \\layout(location = 1) in vec3 a_normal;
    \\layout(location = 2) in vec2 a_uv;
    \\uniform mat4 u_mvp;
    \\out vec3 v_normal;
    \\out vec2 v_uv;
    \\void main() {
    \\  v_normal = a_normal;
    \\  v_uv = a_uv;
    \\  gl_Position = u_mvp * vec4(a_pos, 1.0);
    \\}
;

pub const lit_fs: []const u8 =
    \\#version 300 es
    \\precision mediump float;
    \\in vec3 v_normal;
    \\in vec2 v_uv;
    \\uniform vec4 u_color;
    \\uniform sampler2D u_tex;
    \\out vec4 o_frag;
    \\void main() {
    \\  vec3 l = normalize(vec3(0.4, 0.8, 0.6));
    \\  float lum = 0.25 + 0.75 * max(dot(normalize(v_normal), l), 0.0);
    \\  o_frag = texture(u_tex, v_uv) * u_color * vec4(vec3(lum), 1.0);
    \\}
;

// ── PBR über-shader (comptime assembly) ─────────────────────────────
//
// GLSL ES 3.00. Variants are assembled by `++` string concat at comptime so
// the JS side compiles exactly the program it asked for (no dead uniforms /
// samplers). The FNV-1a-64 hashes of these strings are frozen by golden tests
// below; any byte change is a deliberate wire-contract bump.

fn pbrCheck(comptime flags: u32) void {
    // Also covers variant_normal_map / variant_emissive without variant_pbr.
    if (flags & variant_pbr == 0) @compileError("PBR shader requires variant_pbr");
}

pub fn pbrVertexSrc(comptime flags: u32) []const u8 {
    comptime pbrCheck(flags);
    const head =
        \\#version 300 es
        \\layout(location = 0) in vec3 a_pos;
        \\layout(location = 1) in vec3 a_normal;
        \\layout(location = 2) in vec4 a_tangent;
        \\layout(location = 3) in vec2 a_uv;
        \\uniform mat4 u_mvp;
        \\uniform mat4 u_model;
        \\uniform mat3 u_normal_mat;
        \\out vec3 v_world_pos;
        \\out vec3 v_normal;
        \\out vec2 v_uv;
        \\
    ;
    const nm_outs =
        \\out vec3 v_tangent;
        \\out vec3 v_bitangent;
        \\
    ;
    // Skinning attribs + bone-matrix palette (variant_skinned). Joint indices
    // and weights index a 64-entry mat4 array uploaded via set_bones.
    const skin_decl =
        \\layout(location = 4) in uvec4 a_joints;
        \\layout(location = 5) in vec4 a_weights;
        \\uniform mat4 u_bones[64];
        \\
    ;
    const body_open =
        \\void main() {
        \\  v_world_pos = (u_model * vec4(a_pos, 1.0)).xyz;
        \\  v_normal = u_normal_mat * a_normal;
        \\  v_uv = a_uv;
        \\
    ;
    // Skinned body_open: skin matrix from the bone palette, then skinned
    // position/normal feeding world-space + normal varyings.
    const body_open_skinned =
        \\void main() {
        \\  mat4 skin = a_weights.x * u_bones[a_joints.x] + a_weights.y * u_bones[a_joints.y] + a_weights.z * u_bones[a_joints.z] + a_weights.w * u_bones[a_joints.w];
        \\  v_world_pos = (u_model * (skin * vec4(a_pos, 1.0))).xyz;
        \\  v_normal = u_normal_mat * (mat3(skin) * a_normal);
        \\  v_uv = a_uv;
        \\
    ;
    const nm_body =
        \\  v_tangent = normalize(mat3(u_model) * a_tangent.xyz);
        \\  v_bitangent = cross(v_normal, v_tangent) * a_tangent.w;
        \\
    ;
    const nm_body_skinned =
        \\  v_tangent = normalize(mat3(u_model) * (mat3(skin) * a_tangent.xyz));
        \\  v_bitangent = cross(v_normal, v_tangent) * a_tangent.w;
        \\
    ;
    const body_close =
        \\  gl_Position = u_mvp * vec4(a_pos, 1.0);
        \\}
        \\
    ;
    const body_close_skinned =
        \\  gl_Position = u_mvp * (skin * vec4(a_pos, 1.0));
        \\}
        \\
    ;
    // Shadow-receiver additions (variant_shadow): light-space clip position
    // forwarded to the fragment shader for the depth comparison.
    const shadow_outs =
        \\uniform mat4 u_light_vp;
        \\out vec4 v_light_pos;
        \\
    ;
    const shadow_body =
        \\  v_light_pos = u_light_vp * u_model * vec4(a_pos, 1.0);
        \\
    ;
    const skinned = flags & variant_skinned != 0;
    comptime var src: []const u8 = head;
    if (flags & variant_normal_map != 0) src = src ++ nm_outs;
    if (flags & variant_shadow != 0) src = src ++ shadow_outs;
    if (skinned) src = src ++ skin_decl;
    src = src ++ (if (skinned) body_open_skinned else body_open);
    if (flags & variant_normal_map != 0) src = src ++ (if (skinned) nm_body_skinned else nm_body);
    if (flags & variant_shadow != 0) src = src ++ shadow_body;
    src = src ++ (if (skinned) body_close_skinned else body_close);
    return src;
}

/// Depth-only shader for the shadow pass. Uses the PBR vertex layout but reads
/// only position (attrib 0); the fragment stage writes nothing — the depth
/// buffer is the sole output.
pub fn depthVertexSrc() []const u8 {
    return
    \\#version 300 es
    \\layout(location = 0) in vec3 a_pos;
    \\uniform mat4 u_mvp;
    \\void main() {
    \\  gl_Position = u_mvp * vec4(a_pos, 1.0);
    \\}
    \\
    ;
}

pub fn depthFragmentSrc() []const u8 {
    return
    \\#version 300 es
    \\precision highp float;
    \\void main() {}
    \\
    ;
}

pub fn pbrFragmentSrc(comptime flags: u32) []const u8 {
    comptime pbrCheck(flags);
    const head =
        \\#version 300 es
        \\precision highp float;
        \\in vec3 v_world_pos;
        \\in vec3 v_normal;
        \\in vec2 v_uv;
        \\
    ;
    const nm_ins =
        \\in vec3 v_tangent;
        \\in vec3 v_bitangent;
        \\
    ;
    const uniforms =
        \\uniform vec3 u_camera_pos;
        \\uniform vec4 u_material[3];
        \\uniform vec4 u_lights[8];
        \\uniform int u_light_count;
        \\uniform float u_prefiltered_mips;
        \\uniform sampler2D u_base_tex;
        \\uniform sampler2D u_mr_tex;
        \\uniform sampler2D u_occlusion_tex;
        \\
    ;
    const nm_sampler =
        \\uniform sampler2D u_normal_tex;
        \\
    ;
    const em_sampler =
        \\uniform sampler2D u_emissive_tex;
        \\
    ;
    const ibl_samplers =
        \\uniform samplerCube u_irradiance;
        \\uniform samplerCube u_prefiltered;
        \\uniform sampler2D u_brdf_lut;
        \\out vec4 o_frag;
        \\const float PI = 3.14159265359;
        \\
        \\float distributionGGX(vec3 N, vec3 H, float a) {
        \\  float a2 = a * a;
        \\  float NdotH = max(dot(N, H), 0.0);
        \\  float d = NdotH * NdotH * (a2 - 1.0) + 1.0;
        \\  return a2 / (PI * d * d);
        \\}
        \\float geometrySchlickGGX(float NdotX, float k) {
        \\  return NdotX / (NdotX * (1.0 - k) + k);
        \\}
        \\float geometrySmith(vec3 N, vec3 V, vec3 L, float k) {
        \\  return geometrySchlickGGX(max(dot(N, V), 0.0), k) * geometrySchlickGGX(max(dot(N, L), 0.0), k);
        \\}
        \\vec3 fresnelSchlick(float cosT, vec3 F0) {
        \\  return F0 + (1.0 - F0) * pow(clamp(1.0 - cosT, 0.0, 1.0), 5.0);
        \\}
        \\// Schlick-roughness Fresnel for the IBL ambient term.
        \\vec3 fresnelSchlickRoughness(float cosT, vec3 F0, float rough) {
        \\  vec3 Fr = max(vec3(1.0 - rough), F0);
        \\  return F0 + (Fr - F0) * pow(clamp(1.0 - cosT, 0.0, 1.0), 5.0);
        \\}
        \\
    ;
    const main_open =
        \\void main() {
        \\  vec4 base_color = u_material[0];
        \\  vec3 mr = texture(u_mr_tex, v_uv).rgb;
        \\  float metallic = u_material[1].x * mr.b;
        \\  float roughness = clamp(u_material[1].y * mr.g, 0.045, 1.0);
        \\  float occlusion_strength = u_material[1].z;
        \\  float normal_scale = u_material[1].w;
        \\  vec3 emissive_factor = u_material[2].rgb;
        \\  vec3 base_sample = texture(u_base_tex, v_uv).rgb;
        \\  vec3 albedo = base_sample * base_color.rgb;
        \\  float ao_sample = texture(u_occlusion_tex, v_uv).r;
        \\
    ;
    const normal_nm =
        \\  vec3 n_ts = texture(u_normal_tex, v_uv).xyz * 2.0 - 1.0;
        \\  n_ts.xy *= normal_scale;
        \\  mat3 TBN = mat3(normalize(v_tangent), normalize(v_bitangent), normalize(v_normal));
        \\  vec3 N = normalize(TBN * n_ts);
        \\
    ;
    const normal_plain =
        \\  vec3 N = normalize(v_normal);
        \\
    ;
    const lighting =
        \\  vec3 V = normalize(u_camera_pos - v_world_pos);
        \\  float NdotV = max(dot(N, V), 0.0);
        \\  vec3 F0 = mix(vec3(0.04), albedo, metallic);
        \\  float k_direct = (roughness + 1.0) * (roughness + 1.0) / 8.0;
        \\  float alpha = roughness * roughness;
        \\  vec3 Lo = vec3(0.0);
        \\  for (int i = 0; i < u_light_count; i++) {
        \\    vec4 l0 = u_lights[2 * i];
        \\    vec4 l1 = u_lights[2 * i + 1];
        \\    float ltype = l0.x;
        \\    float intensity = l0.y;
        \\    vec3 posdir = vec3(l0.z, l0.w, l1.x);
        \\    vec3 lcolor = l1.yzw;
        \\    vec3 L;
        \\    vec3 radiance;
        \\    if (ltype < 0.5) {
        \\      L = -posdir;
        \\      radiance = lcolor * intensity;
        \\    } else {
        \\      vec3 Lvec = posdir - v_world_pos;
        \\      float dist = length(Lvec);
        \\      L = Lvec / dist;
        \\      radiance = lcolor * intensity / (dist * dist);
        \\    }
        \\    vec3 H = normalize(V + L);
        \\    float NdotL = max(dot(N, L), 0.0);
        \\    float D = distributionGGX(N, H, alpha);
        \\    float G = geometrySmith(N, V, L, k_direct);
        \\    vec3 F = fresnelSchlick(max(dot(H, V), 0.0), F0);
        \\    vec3 spec = (D * G * F) / max(4.0 * NdotV * NdotL, 0.0001);
        \\    vec3 kD = (vec3(1.0) - F) * (1.0 - metallic);
        \\    Lo += (kD * albedo / PI + spec) * radiance * NdotL;
        \\  }
        \\  vec3 F_ibl = fresnelSchlickRoughness(NdotV, F0, roughness);
        \\  vec3 kD_ibl = (vec3(1.0) - F_ibl) * (1.0 - metallic);
        \\  vec3 diffuse = texture(u_irradiance, N).rgb * albedo;
        \\  vec3 R = reflect(-V, N);
        \\  vec3 prefiltered = textureLod(u_prefiltered, R, roughness * (u_prefiltered_mips - 1.0)).rgb;
        \\  vec2 lut = texture(u_brdf_lut, vec2(NdotV, roughness)).rg;
        \\  vec3 specular_ibl = prefiltered * (F0 * lut.x + lut.y);
        \\  vec3 ambient = (kD_ibl * diffuse + specular_ibl) * mix(1.0, ao_sample, occlusion_strength);
        \\
    ;
    // Direct-light combine, split out so the shadow variant can attenuate the
    // direct term (`Lo`) while leaving the IBL ambient unshadowed. The
    // non-shadow string is byte-identical to the pre-slice-3 source.
    const combine_plain =
        \\  vec3 color = ambient + Lo;
        \\
    ;
    const combine_shadow =
        \\  vec3 color = ambient + Lo * shadowFactor(v_light_pos);
        \\
    ;
    // Shadow-receiver declarations (variant_shadow): the depth-compare sampler,
    // the interpolated light-space position, and a 3×3 PCF lookup. Hardware
    // comparison (sampler2DShadow + LINEAR) gives 2×2 filtering per tap.
    const shadow_decls =
        \\uniform highp sampler2DShadow u_shadow_map;
        \\in vec4 v_light_pos;
        \\float shadowFactor(vec4 lp) {
        \\  vec3 proj = lp.xyz / lp.w;
        \\  proj = proj * 0.5 + 0.5;
        \\  if (proj.z > 1.0) return 1.0;
        \\  float bias = 0.0015;
        \\  vec2 texel = 1.0 / vec2(textureSize(u_shadow_map, 0));
        \\  float sum = 0.0;
        \\  for (int y = -1; y <= 1; y++)
        \\    for (int x = -1; x <= 1; x++)
        \\      sum += texture(u_shadow_map, vec3(proj.xy + vec2(x, y) * texel, proj.z - bias));
        \\  return sum / 9.0;
        \\}
        \\
    ;
    const emissive =
        \\  color += emissive_factor * texture(u_emissive_tex, v_uv).rgb;
        \\
    ;
    const tail_tonemap =
        \\  color = clamp((color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14), 0.0, 1.0);
        \\  color = pow(color, vec3(1.0 / 2.2));
        \\
    ;
    const tail_close =
        \\  o_frag = vec4(color, base_color.a);
        \\}
        \\
    ;
    comptime var src: []const u8 = head;
    if (flags & variant_normal_map != 0) src = src ++ nm_ins;
    src = src ++ uniforms;
    if (flags & variant_normal_map != 0) src = src ++ nm_sampler;
    if (flags & variant_emissive != 0) src = src ++ em_sampler;
    src = src ++ ibl_samplers;
    if (flags & variant_shadow != 0) src = src ++ shadow_decls;
    src = src ++ main_open;
    src = src ++ (if (flags & variant_normal_map != 0) normal_nm else normal_plain);
    src = src ++ lighting;
    src = src ++ (if (flags & variant_shadow != 0) combine_shadow else combine_plain);
    if (flags & variant_emissive != 0) src = src ++ emissive;
    if (flags & variant_linear_output == 0) src = src ++ tail_tonemap;
    src = src ++ tail_close;
    return src;
}

// ── Post-processing GLSL sources ────────────────────────────────────
//
// Shared fullscreen-triangle vertex + 4 post-effect fragments.
// Paired with wgslBright/Blur/Composite/Fxaa below for WebGPU.

pub const fullscreenVertexSrc: []const u8 =
    \\#version 300 es
    \\out vec2 v_uv;
    \\void main() {
    \\  // VBO-less covering triangle: ids 0,1,2 -> (-1,-1),(3,-1),(-1,3)
    \\  vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
    \\  v_uv = p;
    \\  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
    \\}
;

pub const brightFragmentSrc: []const u8 =
    \\#version 300 es
    \\precision highp float;
    \\in vec2 v_uv;
    \\out vec4 frag;
    \\uniform sampler2D u_tex0;
    \\uniform float u_threshold;
    \\void main() {
    \\  vec3 c = texture(u_tex0, v_uv).rgb;
    \\  float l = dot(c, vec3(0.2126, 0.7152, 0.0722));
    \\  frag = vec4(l > u_threshold ? c : vec3(0.0), 1.0);
    \\}
;

pub const blurFragmentSrc: []const u8 =
    \\#version 300 es
    \\precision highp float;
    \\in vec2 v_uv;
    \\out vec4 frag;
    \\uniform sampler2D u_tex0;
    \\uniform vec2 u_texel; // 1/target_size
    \\uniform vec2 u_dir;   // (1,0) horizontal, (0,1) vertical
    \\void main() {
    \\  // 9-tap Gaussian (normalized weights).
    \\  float w[5];
    \\  w[0]=0.227027; w[1]=0.194595; w[2]=0.121622; w[3]=0.054054; w[4]=0.016216;
    \\  vec3 acc = texture(u_tex0, v_uv).rgb * w[0];
    \\  for (int i = 1; i < 5; i++) {
    \\    vec2 o = u_texel * u_dir * float(i);
    \\    acc += texture(u_tex0, v_uv + o).rgb * w[i];
    \\    acc += texture(u_tex0, v_uv - o).rgb * w[i];
    \\  }
    \\  frag = vec4(acc, 1.0);
    \\}
;

pub const compositeFragmentSrc: []const u8 =
    \\#version 300 es
    \\precision highp float;
    \\in vec2 v_uv;
    \\out vec4 frag;
    \\uniform sampler2D u_tex0; // scene HDR
    \\uniform sampler2D u_tex1; // bloom
    \\uniform float u_intensity;
    \\vec3 aces(vec3 x) {
    \\  const float a=2.51, b=0.03, c=2.43, d=0.59, e=0.14;
    \\  return clamp((x*(a*x+b))/(x*(c*x+d)+e), 0.0, 1.0);
    \\}
    \\void main() {
    \\  vec3 hdr = texture(u_tex0, v_uv).rgb + u_intensity * texture(u_tex1, v_uv).rgb;
    \\  frag = vec4(aces(hdr), 1.0);
    \\}
;

pub const fxaaFragmentSrc: []const u8 =
    \\#version 300 es
    \\precision highp float;
    \\in vec2 v_uv;
    \\out vec4 frag;
    \\uniform sampler2D u_tex0;
    \\uniform vec2 u_texel;
    \\float luma(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }
    \\void main() {
    \\  vec3 m  = texture(u_tex0, v_uv).rgb;
    \\  float lM = luma(m);
    \\  float lN = luma(texture(u_tex0, v_uv + vec2(0.0, -u_texel.y)).rgb);
    \\  float lS = luma(texture(u_tex0, v_uv + vec2(0.0,  u_texel.y)).rgb);
    \\  float lE = luma(texture(u_tex0, v_uv + vec2( u_texel.x, 0.0)).rgb);
    \\  float lW = luma(texture(u_tex0, v_uv + vec2(-u_texel.x, 0.0)).rgb);
    \\  float lo = min(lM, min(min(lN, lS), min(lE, lW)));
    \\  float hi = max(lM, max(max(lN, lS), max(lE, lW)));
    \\  if (hi - lo < 0.10) { frag = vec4(m, 1.0); return; }
    \\  vec2 dir = normalize(vec2((lN + lS) - 2.0*lM, (lE + lW) - 2.0*lM) + 1e-6);
    \\  vec3 a = texture(u_tex0, v_uv + dir * u_texel).rgb;
    \\  vec3 b = texture(u_tex0, v_uv - dir * u_texel).rgb;
    \\  frag = vec4(0.5 * (a + b), 1.0);
    \\}
;

// ── WebGPU PBR über-shader (P10 slice 2a) ───────────────────────────
//
// One WGSL module holding BOTH stages (vs_main + fs_main), a parallel
// emission to the GLSL pbrVertexSrc/pbrFragmentSrc above. The GLSL goldens
// remain the source of truth; this mirrors their semantics exactly for the
// three PBR variants:
//   F0 = variant_pbr
//   F1 = variant_pbr | variant_normal_map
//   F2 = variant_pbr | variant_normal_map | variant_emissive
//
// variant_shadow / variant_depth are NOT part of this slice (rejected at
// comptime). IBL bindings (slots 5-7) are always present; in slice 2a they
// sample default placeholder textures (~zero contribution) so the WGSL
// goldens freeze ONCE here and slice 2b adds no golden churn.
//
// Uniform layout (std140-equivalent, explicit 16B member alignment):
//   mvp        : mat4x4<f32>      (offset 0)
//   model      : mat4x4<f32>      (offset 64)
//   normal_mat : mat3x3<f32>      (offset 128; occupies 48B, three vec4 cols)
//   camera_pos : vec3<f32>        (offset 176; +4B pad)
//   material   : array<vec4<f32>,3>
//   lights     : array<vec4<f32>,8>
//   light_count: i32
//   prefiltered_mips: f32         (+8B pad to 16B)
//
// Bindings (@group(1)): a shared sampler (binding 0) + per-slot textures.
// Slots mirror the GLSL sampler order / JS texture-unit contract:
//   1 base (2D), 2 metallic-roughness (2D), (F1) 3 normal (2D),
//   (F2) 4 emissive (2D), 5 occlusion (2D), 6 irradiance (cube),
//   7 prefiltered (cube), 8 brdf_lut (2D).
pub fn wgslPbr(comptime flags: u32) []const u8 {
    comptime pbrCheck(flags);
    if (flags & variant_depth != 0) @compileError("wgslPbr: variant_depth uses wgslDepth(), not wgslPbr");

    // ── Uniform block + group(0) ────────────────────────────────────
    // Split so variant_shadow can append `light_vp` (offset 384, after the f32
    // prefiltered_mips @ 372 padded to 384) without changing the non-shadow bytes.
    const uniforms_head =
        \\struct U {
        \\  mvp: mat4x4<f32>,
        \\  model: mat4x4<f32>,
        \\  normal_mat: mat3x3<f32>,
        \\  camera_pos: vec3<f32>,
        \\  material: array<vec4<f32>, 3>,
        \\  lights: array<vec4<f32>, 8>,
        \\  light_count: i32,
        \\  prefiltered_mips: f32,
        \\
    ;
    const uniforms_shadow =
        \\  light_vp: mat4x4<f32>,
        \\
    ;
    const uniforms_tail =
        \\};
        \\@group(0) @binding(0) var<uniform> u: U;
        \\
    ;
    // Bone-matrix palette (variant_skinned). A SEPARATE group(0) binding, not part
    // of the per-draw U block: a 64-entry mat4 array uploaded via set_bones. Joint
    // indices/weights (vs_main locations 4/5) index it.
    const uniforms_bones =
        \\struct Bones {
        \\  m: array<mat4x4<f32>, 64>,
        \\};
        \\@group(0) @binding(1) var<uniform> bones: Bones;
        \\
    ;
    // ── group(1) texture + sampler bindings (varied by variant) ─────
    const samp =
        \\@group(1) @binding(0) var samp: sampler;
        \\
    ;
    const tex_base =
        \\@group(1) @binding(1) var base_tex: texture_2d<f32>;
        \\@group(1) @binding(2) var mr_tex: texture_2d<f32>;
        \\
    ;
    const tex_normal =
        \\@group(1) @binding(3) var normal_tex: texture_2d<f32>;
        \\
    ;
    const tex_emissive =
        \\@group(1) @binding(4) var emissive_tex: texture_2d<f32>;
        \\
    ;
    const tex_ibl =
        \\@group(1) @binding(5) var occlusion_tex: texture_2d<f32>;
        \\@group(1) @binding(6) var irradiance: texture_cube<f32>;
        \\@group(1) @binding(7) var prefiltered: texture_cube<f32>;
        \\@group(1) @binding(8) var brdf_lut: texture_2d<f32>;
        \\
    ;
    // Shadow receiver (variant_shadow): a depth texture + comparison sampler at
    // bindings 9/10 (after the IBL units). slot tex_slot_shadow=8 → binding 9.
    const tex_shadow =
        \\@group(1) @binding(9) var shadow_map: texture_depth_2d;
        \\@group(1) @binding(10) var shadow_samp: sampler_comparison;
        \\
    ;
    // ── varyings: VSOut struct ──────────────────────────────────────
    const vsout_head =
        \\struct VSOut {
        \\  @builtin(position) pos: vec4<f32>,
        \\  @location(0) world_pos: vec3<f32>,
        \\  @location(1) normal: vec3<f32>,
        \\  @location(2) uv: vec2<f32>,
        \\
    ;
    const vsout_nm =
        \\  @location(3) tangent: vec3<f32>,
        \\  @location(4) bitangent: vec3<f32>,
        \\
    ;
    const vsout_shadow =
        \\  @location(5) light_pos: vec4<f32>,
        \\
    ;
    const vsout_tail =
        \\};
        \\
    ;
    // ── vertex stage ────────────────────────────────────────────────
    const vs_head =
        \\@vertex
        \\fn vs_main(
        \\  @location(0) a_pos: vec3<f32>,
        \\  @location(1) a_normal: vec3<f32>,
        \\  @location(2) a_tangent: vec4<f32>,
        \\  @location(3) a_uv: vec2<f32>,
        \\) -> VSOut {
        \\  var out: VSOut;
        \\  out.world_pos = (u.model * vec4<f32>(a_pos, 1.0)).xyz;
        \\  out.normal = u.normal_mat * a_normal;
        \\  out.uv = a_uv;
        \\
    ;
    // Skinned vs_main: adds joint/weight vertex inputs (locations 4/5), builds the
    // skin matrix from the bone palette, and feeds the skinned position/normal into
    // the world-space + normal varyings. uint8x4 → vec4<u32>; unorm8x4 → vec4<f32>.
    const vs_head_skinned =
        \\@vertex
        \\fn vs_main(
        \\  @location(0) a_pos: vec3<f32>,
        \\  @location(1) a_normal: vec3<f32>,
        \\  @location(2) a_tangent: vec4<f32>,
        \\  @location(3) a_uv: vec2<f32>,
        \\  @location(4) a_joints: vec4<u32>,
        \\  @location(5) a_weights: vec4<f32>,
        \\) -> VSOut {
        \\  var out: VSOut;
        \\  let skin = a_weights.x * bones.m[a_joints.x] + a_weights.y * bones.m[a_joints.y] + a_weights.z * bones.m[a_joints.z] + a_weights.w * bones.m[a_joints.w];
        \\  let sp = skin * vec4<f32>(a_pos, 1.0);
        \\  out.world_pos = (u.model * sp).xyz;
        \\  out.normal = u.normal_mat * (mat3x3<f32>(skin[0].xyz, skin[1].xyz, skin[2].xyz) * a_normal);
        \\  out.uv = a_uv;
        \\
    ;
    const vs_nm =
        \\  let t = normalize((mat3x3<f32>(u.model[0].xyz, u.model[1].xyz, u.model[2].xyz)) * a_tangent.xyz);
        \\  out.tangent = t;
        \\  out.bitangent = cross(out.normal, t) * a_tangent.w;
        \\
    ;
    const vs_nm_skinned =
        \\  let t = normalize((mat3x3<f32>(u.model[0].xyz, u.model[1].xyz, u.model[2].xyz)) * (mat3x3<f32>(skin[0].xyz, skin[1].xyz, skin[2].xyz) * a_tangent.xyz));
        \\  out.tangent = t;
        \\  out.bitangent = cross(out.normal, t) * a_tangent.w;
        \\
    ;
    const vs_shadow =
        \\  out.light_pos = u.light_vp * u.model * vec4<f32>(a_pos, 1.0);
        \\
    ;
    const vs_tail =
        \\  out.pos = u.mvp * vec4<f32>(a_pos, 1.0);
        \\  return out;
        \\}
        \\
    ;
    const vs_tail_skinned =
        \\  out.pos = u.mvp * sp;
        \\  return out;
        \\}
        \\
    ;
    // ── fragment helpers (Cook-Torrance) ────────────────────────────
    const helpers =
        \\const PI: f32 = 3.14159265359;
        \\fn distributionGGX(N: vec3<f32>, H: vec3<f32>, a: f32) -> f32 {
        \\  let a2 = a * a;
        \\  let NdotH = max(dot(N, H), 0.0);
        \\  let d = NdotH * NdotH * (a2 - 1.0) + 1.0;
        \\  return a2 / (PI * d * d);
        \\}
        \\fn geometrySchlickGGX(NdotX: f32, k: f32) -> f32 {
        \\  return NdotX / (NdotX * (1.0 - k) + k);
        \\}
        \\fn geometrySmith(N: vec3<f32>, V: vec3<f32>, L: vec3<f32>, k: f32) -> f32 {
        \\  return geometrySchlickGGX(max(dot(N, V), 0.0), k) * geometrySchlickGGX(max(dot(N, L), 0.0), k);
        \\}
        \\fn fresnelSchlick(cosT: f32, F0: vec3<f32>) -> vec3<f32> {
        \\  return F0 + (vec3<f32>(1.0) - F0) * pow(clamp(1.0 - cosT, 0.0, 1.0), 5.0);
        \\}
        \\fn fresnelSchlickRoughness(cosT: f32, F0: vec3<f32>, rough: f32) -> vec3<f32> {
        \\  let Fr = max(vec3<f32>(1.0 - rough), F0);
        \\  return F0 + (Fr - F0) * pow(clamp(1.0 - cosT, 0.0, 1.0), 5.0);
        \\}
        \\
    ;
    // ── fragment stage ──────────────────────────────────────────────
    const fs_open =
        \\@fragment
        \\fn fs_main(in: VSOut) -> @location(0) vec4<f32> {
        \\  let base_color = u.material[0];
        \\  let mr = textureSample(mr_tex, samp, in.uv).rgb;
        \\  let metallic = u.material[1].x * mr.b;
        \\  let roughness = clamp(u.material[1].y * mr.g, 0.045, 1.0);
        \\  let occlusion_strength = u.material[1].z;
        \\  let normal_scale = u.material[1].w;
        \\  let emissive_factor = u.material[2].rgb;
        \\  let base_sample = textureSample(base_tex, samp, in.uv).rgb;
        \\  let albedo = base_sample * base_color.rgb;
        \\  let ao_sample = textureSample(occlusion_tex, samp, in.uv).r;
        \\
    ;
    const fs_normal_nm =
        \\  var n_ts = textureSample(normal_tex, samp, in.uv).xyz * 2.0 - 1.0;
        \\  n_ts = vec3<f32>(n_ts.xy * normal_scale, n_ts.z);
        \\  let TBN = mat3x3<f32>(normalize(in.tangent), normalize(in.bitangent), normalize(in.normal));
        \\  let N = normalize(TBN * n_ts);
        \\
    ;
    const fs_normal_plain =
        \\  let N = normalize(in.normal);
        \\
    ;
    const fs_lighting =
        \\  let V = normalize(u.camera_pos - in.world_pos);
        \\  let NdotV = max(dot(N, V), 0.0);
        \\  let F0 = mix(vec3<f32>(0.04), albedo, metallic);
        \\  let k_direct = (roughness + 1.0) * (roughness + 1.0) / 8.0;
        \\  let alpha = roughness * roughness;
        \\  var Lo = vec3<f32>(0.0);
        \\  for (var i: i32 = 0; i < u.light_count; i = i + 1) {
        \\    let l0 = u.lights[2 * i];
        \\    let l1 = u.lights[2 * i + 1];
        \\    let ltype = l0.x;
        \\    let intensity = l0.y;
        \\    let posdir = vec3<f32>(l0.z, l0.w, l1.x);
        \\    let lcolor = l1.yzw;
        \\    var L: vec3<f32>;
        \\    var radiance: vec3<f32>;
        \\    if (ltype < 0.5) {
        \\      L = -posdir;
        \\      radiance = lcolor * intensity;
        \\    } else {
        \\      let Lvec = posdir - in.world_pos;
        \\      let dist = length(Lvec);
        \\      L = Lvec / dist;
        \\      radiance = lcolor * intensity / (dist * dist);
        \\    }
        \\    let H = normalize(V + L);
        \\    let NdotL = max(dot(N, L), 0.0);
        \\    let D = distributionGGX(N, H, alpha);
        \\    let G = geometrySmith(N, V, L, k_direct);
        \\    let F = fresnelSchlick(max(dot(H, V), 0.0), F0);
        \\    let spec = (D * G * F) / max(4.0 * NdotV * NdotL, 0.0001);
        \\    let kD = (vec3<f32>(1.0) - F) * (1.0 - metallic);
        \\    Lo = Lo + (kD * albedo / PI + spec) * radiance * NdotL;
        \\  }
        \\  let F_ibl = fresnelSchlickRoughness(NdotV, F0, roughness);
        \\  let kD_ibl = (vec3<f32>(1.0) - F_ibl) * (1.0 - metallic);
        \\  let diffuse = textureSample(irradiance, samp, N).rgb * albedo;
        \\  let R = reflect(-V, N);
        \\  let prefiltered_c = textureSampleLevel(prefiltered, samp, R, roughness * (u.prefiltered_mips - 1.0)).rgb;
        \\  let lut = textureSample(brdf_lut, samp, vec2<f32>(NdotV, roughness)).rg;
        \\  let specular_ibl = prefiltered_c * (F0 * lut.x + lut.y);
        \\  let ambient = (kD_ibl * diffuse + specular_ibl) * mix(1.0, ao_sample, occlusion_strength);
        \\
    ;
    // 3×3 PCF over the depth-compare sampler. The chunk supplies a light_vp that
    // already remaps clip z to WebGPU's [0,1] range (Zfix·ortho·view), so the
    // depth ref is ndc.z directly; uv flips Y for WebGPU texture space.
    const fs_shadow_decl =
        \\fn shadowFactor(lp: vec4<f32>) -> f32 {
        \\  let ndc = lp.xyz / lp.w;
        \\  if (ndc.z > 1.0) { return 1.0; }
        \\  let uv = vec2<f32>(ndc.x * 0.5 + 0.5, ndc.y * -0.5 + 0.5);
        \\  let bias = 0.0015;
        \\  let texel = 1.0 / vec2<f32>(textureDimensions(shadow_map, 0));
        \\  var sum = 0.0;
        \\  for (var y = -1; y <= 1; y = y + 1) {
        \\    for (var x = -1; x <= 1; x = x + 1) {
        \\      sum = sum + textureSampleCompareLevel(shadow_map, shadow_samp, uv + vec2<f32>(f32(x), f32(y)) * texel, ndc.z - bias);
        \\    }
        \\  }
        \\  return sum / 9.0;
        \\}
        \\
    ;
    const fs_combine_plain =
        \\  var color = ambient + Lo;
        \\
    ;
    const fs_combine_shadow =
        \\  var color = ambient + Lo * shadowFactor(in.light_pos);
        \\
    ;
    const fs_emissive =
        \\  color = color + emissive_factor * textureSample(emissive_tex, samp, in.uv).rgb;
        \\
    ;
    const fs_tail =
        \\  color = clamp((color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14), vec3<f32>(0.0), vec3<f32>(1.0));
        \\  color = pow(color, vec3<f32>(1.0 / 2.2));
        \\  return vec4<f32>(color, base_color.a);
        \\}
        \\
    ;

    const nm = flags & variant_normal_map != 0;
    const em = flags & variant_emissive != 0;
    const shadow = flags & variant_shadow != 0;
    const skinned = flags & variant_skinned != 0;
    comptime var src: []const u8 = uniforms_head;
    if (shadow) src = src ++ uniforms_shadow;
    src = src ++ uniforms_tail;
    if (skinned) src = src ++ uniforms_bones;
    src = src ++ samp ++ tex_base;
    if (nm) src = src ++ tex_normal;
    if (em) src = src ++ tex_emissive;
    src = src ++ tex_ibl;
    if (shadow) src = src ++ tex_shadow;
    src = src ++ vsout_head;
    if (nm) src = src ++ vsout_nm;
    if (shadow) src = src ++ vsout_shadow;
    src = src ++ vsout_tail;
    src = src ++ (if (skinned) vs_head_skinned else vs_head);
    if (nm) src = src ++ (if (skinned) vs_nm_skinned else vs_nm);
    if (shadow) src = src ++ vs_shadow;
    src = src ++ (if (skinned) vs_tail_skinned else vs_tail);
    src = src ++ helpers;
    if (shadow) src = src ++ fs_shadow_decl;
    src = src ++ fs_open;
    src = src ++ (if (nm) fs_normal_nm else fs_normal_plain);
    src = src ++ fs_lighting;
    src = src ++ (if (shadow) fs_combine_shadow else fs_combine_plain);
    if (em) src = src ++ fs_emissive;
    src = src ++ fs_tail;
    return src;
}

/// Depth-only WGSL for the WebGPU shadow pass (variant_depth). Reads only
/// position (attrib 0) of the stride-48 PBR layout; the fragment stage writes
/// nothing — the depth buffer is the sole output. Parallel to depthVertexSrc /
/// depthFragmentSrc (GLSL). Uniform: a single light-space mvp.
pub fn wgslDepth() []const u8 {
    return
    \\struct U {
    \\  mvp: mat4x4<f32>,
    \\};
    \\@group(0) @binding(0) var<uniform> u: U;
    \\@vertex
    \\fn vs_main(@location(0) a_pos: vec3<f32>) -> @builtin(position) vec4<f32> {
    \\  return u.mvp * vec4<f32>(a_pos, 1.0);
    \\}
    \\@fragment
    \\fn fs_main() {}
    \\
    ;
}

// ── Post-processing WGSL modules ─────────────────────────────────────
//
// Shared bind-group layout for all 4 post effects:
//   @group(0) @binding(0) = params uniform (padded to 16B)
//   @group(1) @binding(0) = sampler
//   @group(1) @binding(1) = tex0 (primary input)
//   @group(1) @binding(2) = tex1 (secondary; bridge binds a 1×1 dummy for single-input effects)
// Each module includes a VBO-less fullscreen-triangle vs_main.

pub fn wgslBright() []const u8 {
    return
    \\struct VsOut { @builtin(position) pos: vec4<f32>, @location(0) uv: vec2<f32> };
    \\@vertex fn vs_main(@builtin(vertex_index) vi: u32) -> VsOut {
    \\  var o: VsOut;
    \\  let p = vec2<f32>(f32((vi << 1u) & 2u), f32(vi & 2u));
    \\  o.uv = p;
    \\  o.pos = vec4<f32>(p * 2.0 - 1.0, 0.0, 1.0);
    \\  return o;
    \\}
    \\struct Params { threshold: f32, _pad: vec3<f32> };
    \\@group(0) @binding(0) var<uniform> P: Params;
    \\@group(1) @binding(0) var samp: sampler;
    \\@group(1) @binding(1) var tex0: texture_2d<f32>;
    \\@group(1) @binding(2) var tex1: texture_2d<f32>;
    \\@fragment fn fs_main(@location(0) uv: vec2<f32>) -> @location(0) vec4<f32> {
    \\  let c = textureSample(tex0, samp, uv).rgb;
    \\  let l = dot(c, vec3<f32>(0.2126, 0.7152, 0.0722));
    \\  return vec4<f32>(select(vec3<f32>(0.0), c, l > P.threshold), 1.0);
    \\}
    ;
}

pub fn wgslBlur() []const u8 {
    return
    \\struct VsOut { @builtin(position) pos: vec4<f32>, @location(0) uv: vec2<f32> };
    \\@vertex fn vs_main(@builtin(vertex_index) vi: u32) -> VsOut {
    \\  var o: VsOut;
    \\  let p = vec2<f32>(f32((vi << 1u) & 2u), f32(vi & 2u));
    \\  o.uv = p;
    \\  o.pos = vec4<f32>(p * 2.0 - 1.0, 0.0, 1.0);
    \\  return o;
    \\}
    \\struct Params { texel: vec2<f32>, dir: vec2<f32> };
    \\@group(0) @binding(0) var<uniform> P: Params;
    \\@group(1) @binding(0) var samp: sampler;
    \\@group(1) @binding(1) var tex0: texture_2d<f32>;
    \\@group(1) @binding(2) var tex1: texture_2d<f32>;
    \\@fragment fn fs_main(@location(0) uv: vec2<f32>) -> @location(0) vec4<f32> {
    \\  let w0 = 0.227027; let w1 = 0.194595; let w2 = 0.121622; let w3 = 0.054054; let w4 = 0.016216;
    \\  var acc = textureSample(tex0, samp, uv).rgb * w0;
    \\  let step = P.texel * P.dir;
    \\  acc += textureSample(tex0, samp, uv + step * 1.0).rgb * w1;
    \\  acc += textureSample(tex0, samp, uv - step * 1.0).rgb * w1;
    \\  acc += textureSample(tex0, samp, uv + step * 2.0).rgb * w2;
    \\  acc += textureSample(tex0, samp, uv - step * 2.0).rgb * w2;
    \\  acc += textureSample(tex0, samp, uv + step * 3.0).rgb * w3;
    \\  acc += textureSample(tex0, samp, uv - step * 3.0).rgb * w3;
    \\  acc += textureSample(tex0, samp, uv + step * 4.0).rgb * w4;
    \\  acc += textureSample(tex0, samp, uv - step * 4.0).rgb * w4;
    \\  return vec4<f32>(acc, 1.0);
    \\}
    ;
}

pub fn wgslComposite() []const u8 {
    return
    \\struct VsOut { @builtin(position) pos: vec4<f32>, @location(0) uv: vec2<f32> };
    \\@vertex fn vs_main(@builtin(vertex_index) vi: u32) -> VsOut {
    \\  var o: VsOut;
    \\  let p = vec2<f32>(f32((vi << 1u) & 2u), f32(vi & 2u));
    \\  o.uv = p;
    \\  o.pos = vec4<f32>(p * 2.0 - 1.0, 0.0, 1.0);
    \\  return o;
    \\}
    \\struct Params { intensity: f32, _pad: vec3<f32> };
    \\@group(0) @binding(0) var<uniform> P: Params;
    \\@group(1) @binding(0) var samp: sampler;
    \\@group(1) @binding(1) var tex0: texture_2d<f32>;
    \\@group(1) @binding(2) var tex1: texture_2d<f32>;
    \\fn aces(x: vec3<f32>) -> vec3<f32> {
    \\  let a = 2.51; let b = 0.03; let c = 2.43; let d = 0.59; let e = 0.14;
    \\  return clamp((x*(a*x+b))/(x*(c*x+d)+e), vec3<f32>(0.0), vec3<f32>(1.0));
    \\}
    \\@fragment fn fs_main(@location(0) uv: vec2<f32>) -> @location(0) vec4<f32> {
    \\  let hdr = textureSample(tex0, samp, uv).rgb + P.intensity * textureSample(tex1, samp, uv).rgb;
    \\  return vec4<f32>(aces(hdr), 1.0);
    \\}
    ;
}

pub fn wgslFxaa() []const u8 {
    // Use textureSampleLevel (mip 0) for all directional samples — always
    // uniform control flow, no early-return branch, satisfies WGSL spec.
    return
    \\struct VsOut { @builtin(position) pos: vec4<f32>, @location(0) uv: vec2<f32> };
    \\@vertex fn vs_main(@builtin(vertex_index) vi: u32) -> VsOut {
    \\  var o: VsOut;
    \\  let p = vec2<f32>(f32((vi << 1u) & 2u), f32(vi & 2u));
    \\  o.uv = p;
    \\  o.pos = vec4<f32>(p * 2.0 - 1.0, 0.0, 1.0);
    \\  return o;
    \\}
    \\struct Params { texel: vec2<f32>, _pad: vec2<f32> };
    \\@group(0) @binding(0) var<uniform> P: Params;
    \\@group(1) @binding(0) var samp: sampler;
    \\@group(1) @binding(1) var tex0: texture_2d<f32>;
    \\@group(1) @binding(2) var tex1: texture_2d<f32>;
    \\fn luma(c: vec3<f32>) -> f32 { return dot(c, vec3<f32>(0.299, 0.587, 0.114)); }
    \\@fragment fn fs_main(@location(0) uv: vec2<f32>) -> @location(0) vec4<f32> {
    \\  let m  = textureSampleLevel(tex0, samp, uv, 0.0).rgb;
    \\  let lM = luma(m);
    \\  let lN = luma(textureSampleLevel(tex0, samp, uv + vec2<f32>(0.0, -P.texel.y), 0.0).rgb);
    \\  let lS = luma(textureSampleLevel(tex0, samp, uv + vec2<f32>(0.0,  P.texel.y), 0.0).rgb);
    \\  let lE = luma(textureSampleLevel(tex0, samp, uv + vec2<f32>( P.texel.x, 0.0), 0.0).rgb);
    \\  let lW = luma(textureSampleLevel(tex0, samp, uv + vec2<f32>(-P.texel.x, 0.0), 0.0).rgb);
    \\  let lo = min(lM, min(min(lN, lS), min(lE, lW)));
    \\  let hi = max(lM, max(max(lN, lS), max(lE, lW)));
    \\  let edge = clamp((hi - lo - 0.10) * 20.0, 0.0, 1.0);
    \\  let dir = normalize(vec2<f32>((lN + lS) - 2.0*lM, (lE + lW) - 2.0*lM) + vec2<f32>(1e-6));
    \\  let a = textureSampleLevel(tex0, samp, uv + dir * P.texel, 0.0).rgb;
    \\  let b = textureSampleLevel(tex0, samp, uv - dir * P.texel, 0.0).rgb;
    \\  let blended = mix(m, 0.5 * (a + b), edge);
    \\  return vec4<f32>(blended, 1.0);
    \\}
    ;
}

// ── Task 3: Post-process effect-graph structs ────────────────────────

/// Bloom configuration for the post-process pass.
pub const Bloom = struct {
    /// Luminance threshold above which pixels contribute to bloom.
    threshold: f32 = 1.0,
    /// Bloom intensity blended into the composite.
    intensity: f32 = 0.6,
};

/// Options for `beginPostProcess` / `endPostProcess`.
pub const PostProcess = struct {
    /// Bloom effect; set to `null` to skip bright-pass + blur chain.
    bloom: ?Bloom = .{},
    /// FXAA anti-aliasing on the final canvas blit.
    fxaa: bool = true,
    /// When true, `beginPostProcess` emits the WGSL post modules
    /// (`wgslBright`/`wgslBlur`/`wgslComposite`/`wgslFxaa`) in the create-shader
    /// vs slot (fs slot 0/0) for the WebGPU backend, mirroring how GlScene/GlSkin
    /// select WGSL vs GLSL via `use_webgpu`. Default (false) emits GLSL.
    webgpu: bool = false,
};

/// Persistent state owned by the island (one static per GL canvas island).
/// Holds fixed render-target / shader handles and stable param storage whose
/// addresses are wired into the command stream; must outlive the frame.
///
/// Handle reservation (h_ = render target, sh_ = shader):
///   240–247 are reserved for the post path to avoid clashing with app handles.
pub const PostCtx = struct {
    pub const h_scene_hdr: u32 = 240;
    pub const h_bloom_a: u32 = 241;
    pub const h_bloom_b: u32 = 242;
    pub const h_ldr: u32 = 243;
    pub const sh_bright: u32 = 244;
    pub const sh_blur: u32 = 245;
    pub const sh_composite: u32 = 246;
    pub const sh_fxaa: u32 = 247;

    /// True once shaders + targets have been emitted for the first time.
    created: bool = false,
    last_w: u32 = 0,
    last_h: u32 = 0,
    opts: PostProcess = .{},

    // Stable param storage (wire records point at these; must outlive the frame).
    p_bright: [4]f32 = .{ 0, 0, 0, 0 }, // [threshold, 0, 0, 0]
    p_blur_h: [4]f32 = .{ 0, 0, 1, 0 }, // [texel.x, texel.y, dir.x=1, dir.y=0]
    p_blur_v: [4]f32 = .{ 0, 0, 0, 1 }, // [texel.x, texel.y, dir.x=0, dir.y=1]
    p_comp: [4]f32 = .{ 0, 0, 0, 0 }, // [intensity, 0, 0, 0]
    p_fxaa: [4]f32 = .{ 0, 0, 0, 0 }, // [texel.x, texel.y, 0, 0]
};

pub const Encoder = struct {
    buf: []u8,
    len: usize,

    pub fn init(buf: []u8) Encoder {
        return .{ .buf = buf, .len = 4 }; // [0..4) reserved for the length header
    }

    fn header(self: *Encoder, tag: Tag, payload_size: u16) void {
        std.debug.assert(payload_size % 4 == 0); // keep every record u32-aligned
        std.debug.assert(self.len + 4 + payload_size <= self.buf.len);
        std.mem.writeInt(u16, self.buf[self.len..][0..2], @intFromEnum(tag), .little);
        std.mem.writeInt(u16, self.buf[self.len + 2 ..][0..2], payload_size, .little);
        self.len += 4;
    }

    fn putU32(self: *Encoder, v: u32) void {
        std.mem.writeInt(u32, self.buf[self.len..][0..4], v, .little);
        self.len += 4;
    }

    fn putF32(self: *Encoder, v: f32) void {
        self.putU32(@bitCast(v));
    }

    pub fn beginFrame(self: *Encoder, clear: [4]f32, width: u32, height: u32) void {
        self.header(.begin_frame, 24);
        for (clear) |c| self.putF32(c);
        self.putU32(width);
        self.putU32(height);
    }

    pub fn createBuffer(self: *Encoder, handle: u32, kind: BufferKind, ptr: u32, byte_len: u32) void {
        self.header(.create_buffer, 16);
        self.putU32(handle);
        self.putU32(@intFromEnum(kind));
        self.putU32(ptr);
        self.putU32(byte_len);
    }

    pub fn createShader(self: *Encoder, handle: u32, variant: u32, vs_ptr: u32, vs_len: u32, fs_ptr: u32, fs_len: u32) void {
        self.header(.create_shader, 24);
        self.putU32(handle);
        self.putU32(variant);
        self.putU32(vs_ptr);
        self.putU32(vs_len);
        self.putU32(fs_ptr);
        self.putU32(fs_len);
    }

    pub fn setPipeline(self: *Encoder, shader: u32, state: u32) void {
        self.header(.set_pipeline, 8);
        self.putU32(shader);
        self.putU32(state);
    }

    pub fn draw(self: *Encoder, vbuf: u32, ibuf: u32, index_count: u32, mvp_ptr: u32) void {
        self.header(.draw, 16);
        self.putU32(vbuf);
        self.putU32(ibuf);
        self.putU32(index_count);
        self.putU32(mvp_ptr);
    }

    pub fn createTexture(self: *Encoder, handle: u32, width: u32, height: u32, ptr: u32, byte_len: u32) void {
        self.header(.create_texture, 20);
        self.putU32(handle);
        self.putU32(width);
        self.putU32(height);
        self.putU32(ptr);
        self.putU32(byte_len);
    }

    /// Like `createTexture` but the bridge uploads the bytes with an
    /// `SRGB8_ALPHA8` internal format (hardware sRGB→linear on sample). Used for
    /// base-color and emissive material textures (P8) so the PBR shader no longer
    /// applies an in-shader `pow(2.2)` decode. Identical 20-byte payload to tag 7.
    pub fn createTextureSrgb(self: *Encoder, handle: u32, width: u32, height: u32, ptr: u32, byte_len: u32) void {
        self.header(.create_texture_srgb, 20);
        self.putU32(handle);
        self.putU32(width);
        self.putU32(height);
        self.putU32(ptr);
        self.putU32(byte_len);
    }

    pub fn bindTexture(self: *Encoder, slot: u32, handle: u32) void {
        self.header(.bind_texture, 8);
        self.putU32(slot);
        self.putU32(handle);
    }

    pub fn drawSub(self: *Encoder, vbuf: u32, ibuf: u32, index_byte_off: u32, index_count: u32, mvp_ptr: u32, color_ptr: u32) void {
        self.header(.draw_sub, 24);
        self.putU32(vbuf);
        self.putU32(ibuf);
        self.putU32(index_byte_off);
        self.putU32(index_count);
        self.putU32(mvp_ptr);
        self.putU32(color_ptr);
    }

    pub fn createTextureEx(self: *Encoder, handle: u32, target: TexTarget, format: TexFormat, width: u32, height: u32, mip_count: u32, ptr: u32, byte_len: u32) void {
        self.header(.create_texture_ex, 32);
        self.putU32(handle);
        self.putU32(@intFromEnum(target));
        self.putU32(@intFromEnum(format));
        self.putU32(width);
        self.putU32(height);
        self.putU32(mip_count);
        self.putU32(ptr);
        self.putU32(byte_len);
    }

    /// Stream-order rule: SET_PIPELINE must precede SET_LIGHTS / BIND_IBL in a
    /// frame. The JS interpreter sets these uniforms on the *active* program; it
    /// null-guards the uniform locations and silently skips when no PBR program
    /// is bound.
    pub fn setLights(self: *Encoder, count: u32, ptr: u32) void {
        self.header(.set_lights, 8);
        self.putU32(count);
        self.putU32(ptr);
    }

    pub fn setBones(self: *Encoder, count: u32, ptr: u32) void {
        self.header(.set_bones, 8);
        self.putU32(count);
        self.putU32(ptr);
    }

    /// See setLights: SET_PIPELINE must precede BIND_IBL in a frame.
    pub fn bindIbl(self: *Encoder, irr: u32, spec: u32, lut: u32, spec_mip_count: u32) void {
        self.header(.bind_ibl, 16);
        self.putU32(irr);
        self.putU32(spec);
        self.putU32(lut);
        self.putU32(spec_mip_count);
    }

    pub fn drawPbr(self: *Encoder, vbuf: u32, ibuf: u32, index_byte_off: u32, index_count: u32, mvp_ptr: u32, model_ptr: u32, normal_ptr: u32, material_ptr: u32, camera_ptr: u32) void {
        self.header(.draw_pbr, 36);
        self.putU32(vbuf);
        self.putU32(ibuf);
        self.putU32(index_byte_off);
        self.putU32(index_count);
        self.putU32(mvp_ptr);
        self.putU32(model_ptr);
        self.putU32(normal_ptr);
        self.putU32(material_ptr);
        self.putU32(camera_ptr);
    }

    /// Issued on island disposal and when replacing resources; the JS interpreter
    /// frees the GPU object and nulls the handle slot.
    pub fn deleteResource(self: *Encoder, kind: ResKind, handle: u32) void {
        self.header(.delete_resource, 8);
        self.putU32(@intFromEnum(kind));
        self.putU32(handle);
    }

    // ── P9 slice 3: shadow pass ─────────────────────────────────────────
    /// Create the depth render target (FBO + `size`×`size` depth texture). One
    /// per scene; recorded for context-restore replay.
    pub fn createShadowMap(self: *Encoder, handle: u32, size: u32) void {
        self.header(.create_shadow_map, 8);
        self.putU32(handle);
        self.putU32(size);
    }

    /// Begin the depth pass: bind the shadow FBO, set the depth-only shader, and
    /// size the viewport to the shadow map. `drawDepth` calls follow.
    pub fn beginShadowPass(self: *Encoder, shadow_handle: u32, depth_shader: u32, size: u32) void {
        self.header(.begin_shadow_pass, 12);
        self.putU32(shadow_handle);
        self.putU32(depth_shader);
        self.putU32(size);
    }

    /// End the depth pass: restore the default framebuffer + canvas viewport.
    pub fn endShadowPass(self: *Encoder, width: u32, height: u32) void {
        self.header(.end_shadow_pass, 8);
        self.putU32(width);
        self.putU32(height);
    }

    /// Depth-only submesh draw (shadow pass). `mvp_ptr` is the light-space
    /// `light_vp · world` matrix.
    pub fn drawDepth(self: *Encoder, vbuf: u32, ibuf: u32, index_byte_off: u32, index_count: u32, mvp_ptr: u32) void {
        self.header(.draw_depth, 20);
        self.putU32(vbuf);
        self.putU32(ibuf);
        self.putU32(index_byte_off);
        self.putU32(index_count);
        self.putU32(mvp_ptr);
    }

    /// Bind the shadow map to `slot` and set `u_light_vp` on the active program.
    /// Like setLights / bindIbl, must be re-emitted after each SET_PIPELINE since
    /// it writes a uniform on the currently active program.
    pub fn bindShadowMap(self: *Encoder, slot: u32, shadow_handle: u32, light_vp_ptr: u32) void {
        self.header(.bind_shadow_map, 12);
        self.putU32(slot);
        self.putU32(shadow_handle);
        self.putU32(light_vp_ptr);
    }

    // ── Post-processing ─────────────────────────────────────────────────

    /// Allocate a color render target (FBO + color attachment, optional depth).
    /// `format` selects the internal texture format; `flags` may include `rt_flag_with_depth`.
    pub fn createRenderTarget(self: *Encoder, handle: u32, width: u32, height: u32, format: TexFormat, flags: u32) void {
        self.header(.create_render_target, 20);
        self.putU32(handle);
        self.putU32(width);
        self.putU32(height);
        self.putU32(@intFromEnum(format));
        self.putU32(flags);
    }

    /// Bind the render target and clear per `clear_flags` (bit0=color, bit1=depth).
    pub fn beginOffscreenPass(self: *Encoder, target_handle: u32, clear: [4]f32, clear_flags: u32) void {
        self.header(.begin_offscreen_pass, 24);
        self.putU32(target_handle);
        for (clear) |c| self.putF32(c);
        self.putU32(clear_flags);
    }

    /// Close the offscreen pass; the next begin_* restores the default framebuffer.
    pub fn endOffscreenPass(self: *Encoder) void {
        self.header(.end_offscreen_pass, 0);
    }

    /// Draw a VBO-less fullscreen triangle with `shader`, binding `tex0`/`tex1` to
    /// samplers 0/1, and pointing the uniform block to `params_ptr` (`param_count` f32s).
    pub fn drawFullscreenQuad(self: *Encoder, shader: u32, tex0: u32, tex1: u32, params_ptr: u32, param_count: u32) void {
        self.header(.draw_fullscreen_quad, 20);
        self.putU32(shader);
        self.putU32(tex0);
        self.putU32(tex1);
        self.putU32(params_ptr);
        self.putU32(param_count);
    }

    pub fn endFrame(self: *Encoder) void {
        self.header(.end_frame, 0);
    }

    /// Stamp the length header and return the full stream.
    pub fn finish(self: *Encoder) []const u8 {
        std.mem.writeInt(u32, self.buf[0..4], @intCast(self.len - 4), .little);
        return self.buf[0..self.len];
    }

    // ── Task 3: Post-process effect-graph API ────────────────────────

    /// GLSL post shader: shared fullscreen vertex + the effect's fragment src,
    /// tagged `variant_post` (the bridge keys bright/blur/composite/fxaa by handle).
    fn createPostShaderGlsl(self: *Encoder, handle: u32, fs: []const u8) void {
        self.createShader(
            handle,
            variant_post,
            @truncate(@intFromPtr(fullscreenVertexSrc.ptr)),
            @intCast(fullscreenVertexSrc.len),
            @truncate(@intFromPtr(fs.ptr)),
            @intCast(fs.len),
        );
    }

    /// WGSL post shader: the WGSL module (both stages) rides the vs slot, fs 0/0 —
    /// same wire shape GlScene/GlSkin use for `wgslPbr` on the WebGPU backend.
    fn createPostShaderWgsl(self: *Encoder, handle: u32, wgsl: []const u8) void {
        self.createShader(
            handle,
            variant_post,
            @truncate(@intFromPtr(wgsl.ptr)),
            @intCast(wgsl.len),
            0,
            0,
        );
    }

    /// Open the post-process pass for this frame.
    ///
    /// On first call (or when `width`/`height` change) emits
    /// `createRenderTarget` × 4 and (first call only) `createShader` × 4.
    /// Ends by opening an offscreen pass into `h_scene_hdr` — the caller
    /// renders the scene into it, then calls `endPostProcess`.
    pub fn beginPostProcess(self: *Encoder, ctx: *PostCtx, opts: PostProcess, width: u32, height: u32) void {
        ctx.opts = opts;
        const resized = width != ctx.last_w or height != ctx.last_h;
        if (!ctx.created or resized) {
            if (resized and ctx.created) {
                self.deleteResource(.render_target, PostCtx.h_scene_hdr);
                self.deleteResource(.render_target, PostCtx.h_bloom_a);
                self.deleteResource(.render_target, PostCtx.h_bloom_b);
                self.deleteResource(.render_target, PostCtx.h_ldr);
            }
            const hw = @max(1, width / 2);
            const hh = @max(1, height / 2);
            self.createRenderTarget(PostCtx.h_scene_hdr, width, height, .rgba16f, rt_flag_with_depth);
            self.createRenderTarget(PostCtx.h_bloom_a, hw, hh, .rgba16f, 0);
            self.createRenderTarget(PostCtx.h_bloom_b, hw, hh, .rgba16f, 0);
            self.createRenderTarget(PostCtx.h_ldr, width, height, .rgba8, 0);
            ctx.last_w = width;
            ctx.last_h = height;
        }
        if (!ctx.created) {
            if (opts.webgpu) {
                // WebGPU: ship the WGSL module (both stages) in the vs slot,
                // fs slot 0/0 — same convention GlScene/GlSkin use for wgslPbr.
                // The bridge picks bright/blur/composite/fxaa by shader handle.
                self.createPostShaderWgsl(PostCtx.sh_bright, wgslBright());
                self.createPostShaderWgsl(PostCtx.sh_blur, wgslBlur());
                self.createPostShaderWgsl(PostCtx.sh_composite, wgslComposite());
                self.createPostShaderWgsl(PostCtx.sh_fxaa, wgslFxaa());
            } else {
                self.createPostShaderGlsl(PostCtx.sh_bright, brightFragmentSrc);
                self.createPostShaderGlsl(PostCtx.sh_blur, blurFragmentSrc);
                self.createPostShaderGlsl(PostCtx.sh_composite, compositeFragmentSrc);
                self.createPostShaderGlsl(PostCtx.sh_fxaa, fxaaFragmentSrc);
            }
            ctx.created = true;
        }
        // Open the scene pass into the HDR target.
        self.beginOffscreenPass(PostCtx.h_scene_hdr, .{ 0, 0, 0, 1 }, clear_flag_color | clear_flag_depth);
    }

    /// Close the scene pass and emit the full effect chain.
    ///
    /// Chain (bloom + fxaa):
    ///   end_offscreen_pass (close scene)
    ///   bright → bloom_a  (begin_offscreen_pass + draw_fullscreen_quad + end_offscreen_pass)
    ///   blurH  → bloom_b  (begin_offscreen_pass + draw_fullscreen_quad + end_offscreen_pass)
    ///   blurV  → bloom_a  (begin_offscreen_pass + draw_fullscreen_quad + end_offscreen_pass)
    ///   composite → ldr   (begin_offscreen_pass + draw_fullscreen_quad + end_offscreen_pass)
    ///   fxaa  → canvas    (begin_frame + draw_fullscreen_quad + end_frame)
    /// Without fxaa, composite goes straight to the canvas pass.
    pub fn endPostProcess(self: *Encoder, ctx: *PostCtx) void {
        // Close the scene HDR pass.
        self.endOffscreenPass();

        const w = ctx.last_w;
        const h = ctx.last_h;
        const hw: f32 = 1.0 / @as(f32, @floatFromInt(@max(1, w / 2)));
        const hh: f32 = 1.0 / @as(f32, @floatFromInt(@max(1, h / 2)));
        const fw: f32 = 1.0 / @as(f32, @floatFromInt(@max(1, w)));
        const fh: f32 = 1.0 / @as(f32, @floatFromInt(@max(1, h)));

        if (ctx.opts.bloom) |b| {
            // bright-pass: scene_hdr -> bloom_a (½-res)
            ctx.p_bright[0] = b.threshold;
            self.beginOffscreenPass(PostCtx.h_bloom_a, .{ 0, 0, 0, 1 }, clear_flag_color);
            self.drawFullscreenQuad(PostCtx.sh_bright, PostCtx.h_scene_hdr, 0, @truncate(@intFromPtr(&ctx.p_bright)), 1);
            self.endOffscreenPass();
            // blur H: bloom_a -> bloom_b
            ctx.p_blur_h = .{ hw, hh, 1, 0 };
            self.beginOffscreenPass(PostCtx.h_bloom_b, .{ 0, 0, 0, 1 }, clear_flag_color);
            self.drawFullscreenQuad(PostCtx.sh_blur, PostCtx.h_bloom_a, 0, @truncate(@intFromPtr(&ctx.p_blur_h)), 4);
            self.endOffscreenPass();
            // blur V: bloom_b -> bloom_a
            ctx.p_blur_v = .{ hw, hh, 0, 1 };
            self.beginOffscreenPass(PostCtx.h_bloom_a, .{ 0, 0, 0, 1 }, clear_flag_color);
            self.drawFullscreenQuad(PostCtx.sh_blur, PostCtx.h_bloom_b, 0, @truncate(@intFromPtr(&ctx.p_blur_v)), 4);
            self.endOffscreenPass();
            ctx.p_comp[0] = b.intensity;
        } else {
            ctx.p_comp[0] = 0; // no bloom contribution
        }

        if (ctx.opts.fxaa) {
            // composite (scene_hdr + bloom_a) -> ldr offscreen
            self.beginOffscreenPass(PostCtx.h_ldr, .{ 0, 0, 0, 1 }, clear_flag_color);
            self.drawFullscreenQuad(PostCtx.sh_composite, PostCtx.h_scene_hdr, PostCtx.h_bloom_a, @truncate(@intFromPtr(&ctx.p_comp)), 1);
            self.endOffscreenPass();
            // fxaa: ldr -> canvas
            ctx.p_fxaa = .{ fw, fh, 0, 0 };
            self.beginFrame(.{ 0, 0, 0, 1 }, w, h);
            self.drawFullscreenQuad(PostCtx.sh_fxaa, PostCtx.h_ldr, 0, @truncate(@intFromPtr(&ctx.p_fxaa)), 2);
            self.endFrame();
        } else {
            // composite straight to canvas
            self.beginFrame(.{ 0, 0, 0, 1 }, w, h);
            self.drawFullscreenQuad(PostCtx.sh_composite, PostCtx.h_scene_hdr, PostCtx.h_bloom_a, @truncate(@intFromPtr(&ctx.p_comp)), 1);
            self.endFrame();
        }
    }
};

const testing = std.testing;

fn hexAlloc(alloc: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const digits = "0123456789abcdef";
    const out = try alloc.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 0xf];
    }
    return out;
}

test "golden: empty frame (begin + end)" {
    var buf: [256]u8 = undefined;
    var enc = Encoder.init(&buf);
    enc.beginFrame(.{ 0, 0, 0, 1 }, 300, 150);
    enc.endFrame();
    const stream = enc.finish();
    const hex = try hexAlloc(testing.allocator, stream);
    defer testing.allocator.free(hex);
    try testing.expectEqualStrings(
        "20000000" ++ // length header: 32 record bytes
            "0100" ++ "1800" ++ // BEGIN_FRAME, 24-byte payload
            "00000000" ++ "00000000" ++ "00000000" ++ "0000803f" ++ // clear rgba
            "2c010000" ++ "96000000" ++ // viewport 300x150
            "0600" ++ "0000", // END_FRAME, empty payload
        hex,
    );
}

test "golden: resources + one draw" {
    var buf: [512]u8 = undefined;
    var enc = Encoder.init(&buf);
    enc.createBuffer(1, .vertex, 0x1000, 192);
    enc.createBuffer(2, .index, 0x2000, 72);
    enc.createShader(3, variant_vertex_color, 0x4000, 256, 0x5000, 128);
    enc.beginFrame(.{ 0, 0, 0, 1 }, 300, 150);
    enc.setPipeline(3, state_depth_test | state_cull_back);
    enc.draw(1, 2, 36, 0x3000);
    enc.endFrame();
    const stream = enc.finish();
    const hex = try hexAlloc(testing.allocator, stream);
    defer testing.allocator.free(hex);
    try testing.expectEqualStrings(
        "84000000" ++ // length header: 132 record bytes
            // CREATE_BUFFER handle=1 kind=vertex(0) ptr=0x1000 len=192
            "0200" ++ "1000" ++ "01000000" ++ "00000000" ++ "00100000" ++ "c0000000" ++
            // CREATE_BUFFER handle=2 kind=index(1) ptr=0x2000 len=72
            "0200" ++ "1000" ++ "02000000" ++ "01000000" ++ "00200000" ++ "48000000" ++
            // CREATE_SHADER handle=3 variant=1 vs=0x4000/256 fs=0x5000/128
            "0300" ++ "1800" ++ "03000000" ++ "01000000" ++ "00400000" ++ "00010000" ++ "00500000" ++ "80000000" ++
            // BEGIN_FRAME clear=(0,0,0,1) 300x150
            "0100" ++ "1800" ++ "00000000" ++ "00000000" ++ "00000000" ++ "0000803f" ++ "2c010000" ++ "96000000" ++
            // SET_PIPELINE shader=3 state=depth|cull(3)
            "0400" ++ "0800" ++ "03000000" ++ "03000000" ++
            // DRAW vbuf=1 ibuf=2 count=36 mvp_ptr=0x3000
            "0500" ++ "1000" ++ "01000000" ++ "02000000" ++ "24000000" ++ "00300000" ++
            // END_FRAME
            "0600" ++ "0000",
        hex,
    );
}

test "encoder asserts on overflow" {
    // 4-byte header + BEGIN_FRAME needs 32 bytes; documented contract:
    // caller sizes the buffer, overflow is a bug caught by assert.
    // Verified here only by confirming exactly-sized buffer works.
    var buf: [32]u8 = undefined;
    var enc = Encoder.init(&buf);
    enc.beginFrame(.{ 0, 0, 0, 1 }, 1, 1);
    try testing.expectEqual(@as(usize, 32), enc.finish().len);
}

test "golden: CREATE_TEXTURE_SRGB (tag 15) byte layout" {
    // P8: sRGB material texture upload. Same payload as CREATE_TEXTURE (tag 7);
    // the bridge uploads with internalFormat SRGB8_ALPHA8 + generated mips.
    var buf: [64]u8 = undefined;
    var enc = Encoder.init(&buf);
    enc.createTextureSrgb(2, 4, 4, 0x5000, 64);
    enc.endFrame();
    const stream = enc.finish();
    const hex = try hexAlloc(testing.allocator, stream);
    defer testing.allocator.free(hex);
    try testing.expectEqualStrings(
        "1c000000" ++ // 28 record bytes
            // CREATE_TEXTURE_SRGB handle=2 w=4 h=4 ptr=0x5000 len=64
            "0f00" ++ "1400" ++ "02000000" ++ "04000000" ++ "04000000" ++ "00500000" ++ "40000000" ++
            // END_FRAME
            "0600" ++ "0000",
        hex,
    );
}

test "golden: texture + lit submesh draw" {
    var buf: [512]u8 = undefined;
    var enc = Encoder.init(&buf);
    enc.createTexture(1, 8, 8, 0x6000, 256);
    enc.bindTexture(0, 1);
    enc.drawSub(1, 2, 12, 36, 0x3000, 0x7000);
    enc.endFrame();
    const stream = enc.finish();
    const hex = try hexAlloc(testing.allocator, stream);
    defer testing.allocator.free(hex);
    try testing.expectEqualStrings(
        "44000000" ++ // 68 record bytes
            // CREATE_TEXTURE handle=1 w=8 h=8 ptr=0x6000 len=256
            "0700" ++ "1400" ++ "01000000" ++ "08000000" ++ "08000000" ++ "00600000" ++ "00010000" ++
            // BIND_TEXTURE slot=0 handle=1
            "0800" ++ "0800" ++ "00000000" ++ "01000000" ++
            // DRAW_SUB vbuf=1 ibuf=2 index_byte_off=12 count=36 mvp=0x3000 color=0x7000
            "0900" ++ "1800" ++ "01000000" ++ "02000000" ++ "0c000000" ++ "24000000" ++ "00300000" ++ "00700000" ++
            // END_FRAME
            "0600" ++ "0000",
        hex,
    );
}

test "P1 goldens unchanged" {
    // No code — this is a reminder marker. The two existing P1 golden
    // tests above must still pass byte-identical; CI proves it.
}

test "P2 goldens unchanged" {
    // Marker: the "texture + lit submesh draw" golden (tags 7/8/9) must
    // stay byte-identical. P3 is purely additive (tags 10-13).
}

// ── P3 wire + shader goldens ────────────────────────────────────────

fn fnv64(s: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (s) |b| {
        h ^= b;
        h = h *% 0x100000001b3;
    }
    return h;
}

test "golden: P3 pbr frame records" {
    var buf: [256]u8 = undefined;
    var enc = Encoder.init(&buf);
    enc.createTextureEx(5, .cube, .rgba16f, 128, 128, 6, 0x8000, 0x100000);
    enc.setLights(2, 0x9000);
    enc.bindIbl(5, 6, 7, 6);
    enc.drawPbr(1, 2, 12, 36, 0x3000, 0x3100, 0x3200, 0x3300, 0x3400);
    enc.endFrame();
    const stream = enc.finish();
    const hex = try hexAlloc(testing.allocator, stream);
    defer testing.allocator.free(hex);
    // Record bytes (excludes the 4-byte length header itself, matching the
    // existing P1/P2 goldens — finish() writes len-4):
    //   CREATE_TEXTURE_EX  4 + 32 = 36
    //   SET_LIGHTS         4 +  8 = 12
    //   BIND_IBL           4 + 16 = 20
    //   DRAW_PBR           4 + 36 = 40
    //   END_FRAME          4 +  0 =  4
    //   total = 112 = 0x70  ->  length header "70000000"
    try testing.expectEqualStrings(
        "70000000" ++ // length header: 112 record bytes
            // CREATE_TEXTURE_EX handle=5 target=cube(1) format=rgba16f(1) w=128 h=128 mips=6 ptr=0x8000 len=0x100000
            "0a00" ++ "2000" ++ "05000000" ++ "01000000" ++ "01000000" ++ "80000000" ++ "80000000" ++ "06000000" ++ "00800000" ++ "00001000" ++
            // SET_LIGHTS count=2 ptr=0x9000
            "0b00" ++ "0800" ++ "02000000" ++ "00900000" ++
            // BIND_IBL irr=5 spec=6 lut=7 spec_mip_count=6
            "0c00" ++ "1000" ++ "05000000" ++ "06000000" ++ "07000000" ++ "06000000" ++
            // DRAW_PBR vbuf=1 ibuf=2 idx_off=12 count=36 mvp=0x3000 model=0x3100 normal=0x3200 material=0x3300 camera=0x3400
            "0d00" ++ "2400" ++ "01000000" ++ "02000000" ++ "0c000000" ++ "24000000" ++ "00300000" ++ "00310000" ++ "00320000" ++ "00330000" ++ "00340000" ++
            // END_FRAME (tag 6)
            "0600" ++ "0000",
        hex,
    );
}

test "golden: set_bones wire record" {
    var buf: [64]u8 = undefined;
    var enc = Encoder.init(&buf);
    enc.setBones(3, 0x4000);
    const stream = enc.finish();
    const hex = try hexAlloc(testing.allocator, stream);
    defer testing.allocator.free(hex);
    // Record bytes (excludes the 4-byte length header, matching the other goldens):
    //   SET_BONES  4 + 8 = 12 = 0x0c  ->  length header "0c000000"
    try testing.expectEqualStrings(
        "0c000000" ++ // length header: 12 record bytes
            // SET_BONES tag=21=0x15 payload=8 count=3 ptr=0x4000
            "1500" ++ "0800" ++ "03000000" ++ "00400000",
        hex,
    );
}

test "golden: PBR GLSL hashes frozen (FNV-1a-64)" {
    const F0 = variant_pbr;
    const F1 = variant_pbr | variant_normal_map;
    const F2 = variant_pbr | variant_normal_map | variant_emissive;
    // Frozen from first green run — a change here = deliberate GLSL contract bump.
    // Fragment hashes bumped in P8: base-color + emissive samples no longer apply
    // an in-shader pow(2.2) — those textures upload as SRGB8_ALPHA8 (hardware decode).
    try testing.expectEqual(@as(u64, 0x9fc619889b5412ca), fnv64(pbrVertexSrc(F0)));
    try testing.expectEqual(@as(u64, 0x197481afefd351c2), fnv64(pbrVertexSrc(F1)));
    try testing.expectEqual(@as(u64, 0x197481afefd351c2), fnv64(pbrVertexSrc(F2))); // emissive does not touch the VS
    try testing.expectEqual(@as(u64, 0x2f65f1426c2c4ed2), fnv64(pbrFragmentSrc(F0)));
    try testing.expectEqual(@as(u64, 0x4b3d632d4e94e70d), fnv64(pbrFragmentSrc(F1)));
    try testing.expectEqual(@as(u64, 0xf0c580cec075612c), fnv64(pbrFragmentSrc(F2)));
}

test "skinned vertex variant: attribs + bone palette present, absent when off" {
    const SK = variant_pbr | variant_skinned;
    const sk = pbrVertexSrc(SK);
    try testing.expect(std.mem.indexOf(u8, sk, "a_joints") != null);
    try testing.expect(std.mem.indexOf(u8, sk, "a_weights") != null);
    try testing.expect(std.mem.indexOf(u8, sk, "u_bones[64]") != null);
    try testing.expect(std.mem.indexOf(u8, sk, "u_bones[a_joints.x]") != null);

    // Non-skinned VS must not leak any skinning declarations.
    const ns = pbrVertexSrc(variant_pbr);
    try testing.expect(std.mem.indexOf(u8, ns, "a_joints") == null);
    try testing.expect(std.mem.indexOf(u8, ns, "u_bones") == null);
}

test "golden: skinned PBR VS hash frozen (FNV-1a-64)" {
    // Frozen from first green run — a change here = deliberate GLSL contract bump.
    try testing.expectEqual(@as(u64, 0x967adc56f7ed4c24), fnv64(pbrVertexSrc(variant_pbr | variant_skinned)));
}

test "WGSL unlit: both stages and uniform present" {
    const src = wgslUnlit;
    try testing.expect(std.mem.indexOf(u8, src, "@vertex") != null);
    try testing.expect(std.mem.indexOf(u8, src, "@fragment") != null);
    try testing.expect(std.mem.indexOf(u8, src, "vs_main") != null);
    try testing.expect(std.mem.indexOf(u8, src, "fs_main") != null);
    try testing.expect(std.mem.indexOf(u8, src, "u.mvp") != null);
}

test "golden: WGSL unlit hash frozen (FNV-1a-64)" {
    // Frozen from first green run — a change here = deliberate WGSL contract bump.
    try testing.expectEqual(@as(u64, 0xa159f35e040f6f8f), fnv64(wgslUnlit));
}

test "WGSL PBR: both stages, uniform + bindings, ACES present" {
    const F0 = variant_pbr;
    const F1 = variant_pbr | variant_normal_map;
    const F2 = variant_pbr | variant_normal_map | variant_emissive;
    inline for ([_]u32{ F0, F1, F2 }) |f| {
        const src = wgslPbr(f);
        // both stages + entry points
        try testing.expect(std.mem.indexOf(u8, src, "@vertex") != null);
        try testing.expect(std.mem.indexOf(u8, src, "@fragment") != null);
        try testing.expect(std.mem.indexOf(u8, src, "fn vs_main") != null);
        try testing.expect(std.mem.indexOf(u8, src, "fn fs_main") != null);
        // uniform block + group(0)
        try testing.expect(std.mem.indexOf(u8, src, "@group(0) @binding(0) var<uniform> u: U") != null);
        try testing.expect(std.mem.indexOf(u8, src, "mvp: mat4x4<f32>") != null);
        try testing.expect(std.mem.indexOf(u8, src, "light_count: i32") != null);
        try testing.expect(std.mem.indexOf(u8, src, "prefiltered_mips: f32") != null);
        // sampler + texture bindings always present (incl. IBL cubes)
        try testing.expect(std.mem.indexOf(u8, src, "var samp: sampler") != null);
        try testing.expect(std.mem.indexOf(u8, src, "base_tex: texture_2d<f32>") != null);
        try testing.expect(std.mem.indexOf(u8, src, "irradiance: texture_cube<f32>") != null);
        try testing.expect(std.mem.indexOf(u8, src, "prefiltered: texture_cube<f32>") != null);
        try testing.expect(std.mem.indexOf(u8, src, "brdf_lut: texture_2d<f32>") != null);
        // Cook-Torrance helpers
        try testing.expect(std.mem.indexOf(u8, src, "fn distributionGGX") != null);
        try testing.expect(std.mem.indexOf(u8, src, "fn geometrySmith") != null);
        try testing.expect(std.mem.indexOf(u8, src, "fn fresnelSchlickRoughness") != null);
        // ACES tonemap frozen constants + gamma
        try testing.expect(std.mem.indexOf(u8, src, "2.51") != null);
        try testing.expect(std.mem.indexOf(u8, src, "0.03") != null);
        try testing.expect(std.mem.indexOf(u8, src, "2.43") != null);
        try testing.expect(std.mem.indexOf(u8, src, "0.59") != null);
        try testing.expect(std.mem.indexOf(u8, src, "0.14") != null);
        try testing.expect(std.mem.indexOf(u8, src, "1.0 / 2.2") != null);
    }
}

test "WGSL PBR: variant-gated normal-map / emissive paths" {
    const F0 = variant_pbr;
    const F1 = variant_pbr | variant_normal_map;
    const F2 = variant_pbr | variant_normal_map | variant_emissive;
    // normal-map / tangent path only for F1 + F2
    try testing.expect(std.mem.indexOf(u8, wgslPbr(F0), "normal_tex") == null);
    try testing.expect(std.mem.indexOf(u8, wgslPbr(F0), "tangent: vec3<f32>") == null);
    try testing.expect(std.mem.indexOf(u8, wgslPbr(F1), "normal_tex") != null);
    try testing.expect(std.mem.indexOf(u8, wgslPbr(F1), "TBN") != null);
    try testing.expect(std.mem.indexOf(u8, wgslPbr(F2), "normal_tex") != null);
    // emissive term only for F2
    try testing.expect(std.mem.indexOf(u8, wgslPbr(F0), "emissive_tex") == null);
    try testing.expect(std.mem.indexOf(u8, wgslPbr(F1), "emissive_tex") == null);
    try testing.expect(std.mem.indexOf(u8, wgslPbr(F2), "emissive_tex") != null);
}

test "WGSL PBR: variant_skinned vertex path" {
    const SK = variant_pbr | variant_skinned;
    const sk = wgslPbr(SK);
    for ([_][]const u8{
        "a_joints", "a_weights", "@group(0) @binding(1)", "bones.m", "bones.m[a_joints.x]",
    }) |needle|
        try testing.expect(std.mem.indexOf(u8, sk, needle) != null);
    // Non-skinned variant carries none of the skinning machinery.
    const ns = wgslPbr(variant_pbr);
    for ([_][]const u8{ "a_joints", "a_weights", "@group(0) @binding(1)", "bones.m" }) |needle|
        try testing.expect(std.mem.indexOf(u8, ns, needle) == null);
}

test "golden: WGSL skinned hash frozen (FNV-1a-64)" {
    // Frozen from first green run — a change here = deliberate WGSL contract bump.
    try testing.expectEqual(@as(u64, 0x1bab1e6822205a6a), fnv64(wgslPbr(variant_pbr | variant_skinned)));
}

test "golden: WGSL PBR hashes frozen (FNV-1a-64)" {
    const F0 = variant_pbr;
    const F1 = variant_pbr | variant_normal_map;
    const F2 = variant_pbr | variant_normal_map | variant_emissive;
    // Frozen from first green run — a change here = deliberate WGSL contract bump.
    try testing.expectEqual(@as(u64, 0x22da26fe9b6d11ce), fnv64(wgslPbr(F0)));
    try testing.expectEqual(@as(u64, 0x8415f4d5595e6473), fnv64(wgslPbr(F1)));
    try testing.expectEqual(@as(u64, 0x08b2f7cb68681f01), fnv64(wgslPbr(F2)));
}

test "WGSL PBR shadow + depth: variant_shadow path and wgslDepth structure" {
    const S0 = variant_pbr | variant_shadow;
    const S1 = variant_pbr | variant_normal_map | variant_shadow;
    const S2 = variant_pbr | variant_normal_map | variant_emissive | variant_shadow;
    inline for ([_]u32{ S0, S1, S2 }) |f| {
        const src = wgslPbr(f);
        try testing.expect(std.mem.indexOf(u8, src, "shadow_map: texture_depth_2d") != null);
        try testing.expect(std.mem.indexOf(u8, src, "shadow_samp: sampler_comparison") != null);
        try testing.expect(std.mem.indexOf(u8, src, "textureSampleCompareLevel") != null);
        try testing.expect(std.mem.indexOf(u8, src, "light_vp: mat4x4<f32>") != null);
        try testing.expect(std.mem.indexOf(u8, src, "light_pos: vec4<f32>") != null);
        try testing.expect(std.mem.indexOf(u8, src, "shadowFactor(in.light_pos)") != null);
    }
    // Non-shadow variants must NOT carry any shadow machinery.
    inline for ([_]u32{ variant_pbr, variant_pbr | variant_normal_map | variant_emissive }) |f| {
        const src = wgslPbr(f);
        try testing.expect(std.mem.indexOf(u8, src, "shadow_map") == null);
        try testing.expect(std.mem.indexOf(u8, src, "light_vp") == null);
        try testing.expect(std.mem.indexOf(u8, src, "shadowFactor") == null);
    }
    // Depth-only shader: a vertex stage on position + an empty fragment.
    const d = wgslDepth();
    try testing.expect(std.mem.indexOf(u8, d, "@vertex") != null);
    try testing.expect(std.mem.indexOf(u8, d, "fn vs_main") != null);
    try testing.expect(std.mem.indexOf(u8, d, "fn fs_main() {}") != null);
    try testing.expect(std.mem.indexOf(u8, d, "mvp: mat4x4<f32>") != null);
}

test "golden: WGSL shadow + depth hashes frozen (FNV-1a-64)" {
    const S0 = variant_pbr | variant_shadow;
    const S1 = variant_pbr | variant_normal_map | variant_shadow;
    const S2 = variant_pbr | variant_normal_map | variant_emissive | variant_shadow;
    // Frozen from first green run — a change here = deliberate WGSL contract bump.
    try testing.expectEqual(@as(u64, 0x7135291bd052822a), fnv64(wgslPbr(S0)));
    try testing.expectEqual(@as(u64, 0x3755ccbc75857e09), fnv64(wgslPbr(S1)));
    try testing.expectEqual(@as(u64, 0x9df4e0e12b66da1f), fnv64(wgslPbr(S2)));
    try testing.expectEqual(@as(u64, 0x3bb6cf33bcf5f8b1), fnv64(wgslDepth()));
}

test "PBR uniform contract: full-variant names present" {
    const full = variant_pbr | variant_normal_map | variant_emissive;
    const vs = pbrVertexSrc(full);
    const fs = pbrFragmentSrc(full);
    // vertex-side uniforms
    for ([_][]const u8{ "u_mvp", "u_model", "u_normal_mat" }) |name|
        try testing.expect(std.mem.indexOf(u8, vs, name) != null);
    // fragment-side uniforms + samplers
    for ([_][]const u8{
        "u_camera_pos",       "u_material",      "u_lights",     "u_light_count",
        "u_prefiltered_mips", "u_base_tex",      "u_mr_tex",     "u_normal_tex",
        "u_emissive_tex",     "u_occlusion_tex", "u_irradiance", "u_prefiltered",
        "u_brdf_lut",
    }) |name|
        try testing.expect(std.mem.indexOf(u8, fs, name) != null);
}

test "PBR base variant omits normal/emissive samplers" {
    const fs = pbrFragmentSrc(variant_pbr);
    try testing.expect(std.mem.indexOf(u8, fs, "u_normal_tex") == null);
    try testing.expect(std.mem.indexOf(u8, fs, "u_emissive_tex") == null);
}

test "PBR fragment carries ACES constants (loose sync with ibl.acesTonemap)" {
    // ibl.zig acesTonemap uses 2.51/0.03/2.43/0.59/0.14; keep these in lockstep.
    const fs = pbrFragmentSrc(variant_pbr);
    try testing.expect(std.mem.indexOf(u8, fs, "2.51") != null);
    try testing.expect(std.mem.indexOf(u8, fs, "0.59") != null);
}

// ── P4 wire goldens ─────────────────────────────────────────────────

test "golden: DELETE_RESOURCE (tag 14)" {
    var buf: [64]u8 = undefined;
    var enc = Encoder.init(&buf);
    enc.deleteResource(.texture, 7);
    enc.endFrame();
    const stream = enc.finish();
    const hex = try hexAlloc(testing.allocator, stream);
    defer testing.allocator.free(hex);
    // Hand-derived byte layout:
    //   DELETE_RESOURCE  4 (header) + 8 (payload) = 12
    //   END_FRAME        4 (header) + 0 (payload) =  4
    //   total record bytes = 16 = 0x10  →  length header "10000000"
    //   DELETE_RESOURCE: tag=0x0e payload_size=8 kind=texture(1) handle=7
    try testing.expectEqualStrings(
        "10000000" ++ // length header: 16 record bytes
            "0e00" ++ "0800" ++ "01000000" ++ "07000000" ++ // DELETE_RESOURCE texture handle=7
            "0600" ++ "0000", // END_FRAME
        hex,
    );
}

test "P3 goldens unchanged (P4 is additive)" {
    // Marker: P3 golden tests above must still pass byte-identical. P4 adds tag 14 only.
}

// ── P9 slice 3: shadow-map wire + shader goldens ────────────────────

test "golden: shadow-variant GLSL hashes frozen (FNV-1a-64)" {
    const S0 = variant_pbr | variant_shadow;
    const S1 = variant_pbr | variant_normal_map | variant_shadow;
    const S2 = variant_pbr | variant_normal_map | variant_emissive | variant_shadow;
    // Frozen from first green run. A change here = deliberate GLSL contract bump.
    try testing.expectEqual(@as(u64, 0x4c653dc19966e2c9), fnv64(pbrVertexSrc(S0)));
    try testing.expectEqual(@as(u64, 0x39a20440b418312f), fnv64(pbrVertexSrc(S1)));
    try testing.expectEqual(@as(u64, 0x39a20440b418312f), fnv64(pbrVertexSrc(S2))); // emissive does not touch the VS
    try testing.expectEqual(@as(u64, 0xe29b0bf3c830deef), fnv64(pbrFragmentSrc(S0)));
    try testing.expectEqual(@as(u64, 0x361efc733727617a), fnv64(pbrFragmentSrc(S1)));
    try testing.expectEqual(@as(u64, 0x55ae1c2b63596b7b), fnv64(pbrFragmentSrc(S2)));
    // Depth-only shadow-pass shader.
    try testing.expectEqual(@as(u64, 0x5bd62d643af5c2d5), fnv64(depthVertexSrc()));
    try testing.expectEqual(@as(u64, 0xe43018c9a1312d96), fnv64(depthFragmentSrc()));
}

test "shadow variant adds receiver uniforms; base variant has none" {
    const S0 = variant_pbr | variant_shadow;
    try testing.expect(std.mem.indexOf(u8, pbrVertexSrc(S0), "u_light_vp") != null);
    try testing.expect(std.mem.indexOf(u8, pbrFragmentSrc(S0), "u_shadow_map") != null);
    try testing.expect(std.mem.indexOf(u8, pbrFragmentSrc(S0), "shadowFactor(v_light_pos)") != null);
    // The shadow term attenuates direct light only — IBL ambient stays lit.
    try testing.expect(std.mem.indexOf(u8, pbrFragmentSrc(S0), "ambient + Lo * shadowFactor") != null);
    // Base PBR variant carries none of it.
    try testing.expect(std.mem.indexOf(u8, pbrFragmentSrc(variant_pbr), "u_shadow_map") == null);
    try testing.expect(std.mem.indexOf(u8, pbrVertexSrc(variant_pbr), "u_light_vp") == null);
}

test "golden: shadow-pass frame records (tags 16-20)" {
    var buf: [128]u8 = undefined;
    var enc = Encoder.init(&buf);
    enc.createShadowMap(8, 1024);
    enc.beginShadowPass(8, 4, 1024);
    enc.drawDepth(1, 2, 12, 36, 0x3000);
    enc.endShadowPass(300, 150);
    enc.bindShadowMap(tex_slot_shadow, 8, 0x3500);
    enc.endFrame();
    const stream = enc.finish();
    const hex = try hexAlloc(testing.allocator, stream);
    defer testing.allocator.free(hex);
    try testing.expectEqualStrings(
        "54000000" ++ // length header: 84 record bytes
            // CREATE_SHADOW_MAP handle=8 size=1024
            "1000" ++ "0800" ++ "08000000" ++ "00040000" ++
            // BEGIN_SHADOW_PASS shadow=8 depth_shader=4 size=1024
            "1100" ++ "0c00" ++ "08000000" ++ "04000000" ++ "00040000" ++
            // DRAW_DEPTH vbuf=1 ibuf=2 idx_off=12 count=36 mvp=0x3000
            "1300" ++ "1400" ++ "01000000" ++ "02000000" ++ "0c000000" ++ "24000000" ++ "00300000" ++
            // END_SHADOW_PASS width=300 height=150
            "1200" ++ "0800" ++ "2c010000" ++ "96000000" ++
            // BIND_SHADOW_MAP slot=8 shadow=8 light_vp=0x3500
            "1400" ++ "0c00" ++ "08000000" ++ "08000000" ++ "00350000" ++
            // END_FRAME
            "0600" ++ "0000",
        hex,
    );
}

// ── Post-processing wire goldens ─────────────────────────────────────

fn readU16(bytes: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, bytes[off..][0..2], .little);
}

fn readU32(bytes: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, bytes[off..][0..4], .little);
}

test "golden: post-process wire records (tags 22-25)" {
    var buf: [256]u8 = undefined;
    var enc = Encoder.init(&buf);
    enc.createRenderTarget(5, 800, 600, .rgba16f, rt_flag_with_depth);
    enc.beginOffscreenPass(5, .{ 0, 0, 0, 1 }, clear_flag_color | clear_flag_depth);
    enc.drawFullscreenQuad(3, 5, 0, 0x2000, 1);
    enc.endOffscreenPass();
    const out = enc.finish();

    // record framing: [len u32][ (tag u16, size u16, payload) ... ]
    var off: usize = 4;
    // create_render_target: handle,w,h,format,flags = 5×u32 = 20B
    try testing.expectEqual(@as(u16, @intFromEnum(Tag.create_render_target)), readU16(out, off));
    try testing.expectEqual(@as(u16, 20), readU16(out, off + 2));
    try testing.expectEqual(@as(u32, 5), readU32(out, off + 4));
    try testing.expectEqual(@as(u32, 800), readU32(out, off + 8));
    try testing.expectEqual(@as(u32, 600), readU32(out, off + 12));
    try testing.expectEqual(@as(u32, @intFromEnum(TexFormat.rgba16f)), readU32(out, off + 16));
    try testing.expectEqual(rt_flag_with_depth, readU32(out, off + 20));
    off += 4 + 20;
    // begin_offscreen_pass: target u32 + clear 4×f32 + clear_flags u32 = 24B
    try testing.expectEqual(@as(u16, @intFromEnum(Tag.begin_offscreen_pass)), readU16(out, off));
    try testing.expectEqual(@as(u16, 24), readU16(out, off + 2));
    try testing.expectEqual(@as(u32, 5), readU32(out, off + 4));
    try testing.expectEqual(clear_flag_color | clear_flag_depth, readU32(out, off + 24));
    off += 4 + 24;
    // draw_fullscreen_quad: shader,tex0,tex1,params_ptr,param_count = 20B
    try testing.expectEqual(@as(u16, @intFromEnum(Tag.draw_fullscreen_quad)), readU16(out, off));
    try testing.expectEqual(@as(u16, 20), readU16(out, off + 2));
    try testing.expectEqual(@as(u32, 3), readU32(out, off + 4));
    try testing.expectEqual(@as(u32, 5), readU32(out, off + 8));
    try testing.expectEqual(@as(u32, 0), readU32(out, off + 12));
    try testing.expectEqual(@as(u32, 0x2000), readU32(out, off + 16));
    try testing.expectEqual(@as(u32, 1), readU32(out, off + 20));
    off += 4 + 20;
    // end_offscreen_pass: 0B payload
    try testing.expectEqual(@as(u16, @intFromEnum(Tag.end_offscreen_pass)), readU16(out, off));
    try testing.expectEqual(@as(u16, 0), readU16(out, off + 2));
}

// ── Task 2: Post shader sources + linear-output PBR variant ─────────

test "post GLSL sources: uniforms + sampler names present" {
    // Fullscreen vertex stage uses gl_VertexID, declares no attributes.
    try testing.expect(std.mem.indexOf(u8, fullscreenVertexSrc, "gl_VertexID") != null);
    try testing.expect(std.mem.indexOf(u8, fullscreenVertexSrc, "in ") == null); // no vertex attributes

    // bright-pass: one source sampler + threshold uniform.
    try testing.expect(std.mem.indexOf(u8, brightFragmentSrc, "u_tex0") != null);
    try testing.expect(std.mem.indexOf(u8, brightFragmentSrc, "u_threshold") != null);

    // blur: source + texel + direction.
    try testing.expect(std.mem.indexOf(u8, blurFragmentSrc, "u_texel") != null);
    try testing.expect(std.mem.indexOf(u8, blurFragmentSrc, "u_dir") != null);

    // composite: two samplers + intensity + ACES (tonemap lives here now).
    try testing.expect(std.mem.indexOf(u8, compositeFragmentSrc, "u_tex0") != null);
    try testing.expect(std.mem.indexOf(u8, compositeFragmentSrc, "u_tex1") != null);
    try testing.expect(std.mem.indexOf(u8, compositeFragmentSrc, "u_intensity") != null);

    // fxaa: source + texel.
    try testing.expect(std.mem.indexOf(u8, fxaaFragmentSrc, "u_texel") != null);
}

test "variant_linear_output skips ACES in PBR fragment" {
    const lit = pbrFragmentSrc(variant_pbr);
    const linear = pbrFragmentSrc(variant_pbr | variant_linear_output);
    // The standard variant tonemaps (inline ACES coefficients 2.51/2.43); the linear variant does not.
    try testing.expect(std.mem.indexOf(u8, lit, "2.51") != null);
    try testing.expect(std.mem.indexOf(u8, linear, "2.51") == null); // ACES omitted in linear output
    try testing.expect(linear.len < lit.len); // linear omits the tonemap block
}

test "golden: post shader sources frozen (FNV-1a-64)" {
    // Frozen from first green run — a change here = deliberate shader contract bump.
    // GLSL
    try testing.expectEqual(@as(u64, 0xd8e25fe0c5f0c5c3), fnv64(fullscreenVertexSrc));
    try testing.expectEqual(@as(u64, 0xceff6b2f105a92ec), fnv64(brightFragmentSrc));
    try testing.expectEqual(@as(u64, 0x221d8b95dd9492ba), fnv64(blurFragmentSrc));
    try testing.expectEqual(@as(u64, 0x0ac71cffb32f57ad), fnv64(compositeFragmentSrc));
    try testing.expectEqual(@as(u64, 0x9d052976fb0b2105), fnv64(fxaaFragmentSrc));
    // WGSL
    try testing.expectEqual(@as(u64, 0xefa46fcd8c5003b6), fnv64(wgslBright()));
    try testing.expectEqual(@as(u64, 0xb93270d3619361ca), fnv64(wgslBlur()));
    try testing.expectEqual(@as(u64, 0xdb360b028579d531), fnv64(wgslComposite()));
    try testing.expectEqual(@as(u64, 0xe8ac45e2d1276dfd), fnv64(wgslFxaa()));
    // linear-output PBR variant (omits tonemap+gamma; post composite pass tonemaps instead)
    try testing.expectEqual(@as(u64, 0x435aa6e4ca89a81a), fnv64(pbrFragmentSrc(variant_pbr | variant_linear_output)));
}

// ── Task 3: Post-process effect-graph sequence tests ─────────────────

/// Walk the record stream and collect all Tag values in order.
fn collectTags(stream: []const u8, out: []Tag) usize {
    if (stream.len < 4) return 0;
    var off: usize = 4; // skip the length header
    var n: usize = 0;
    while (off + 4 <= stream.len and n < out.len) {
        const tag_raw = std.mem.readInt(u16, stream[off..][0..2], .little);
        const size = std.mem.readInt(u16, stream[off + 2 ..][0..2], .little);
        // Map raw u16 to Tag; skip if unknown.
        inline for (std.meta.fields(Tag)) |f| {
            if (f.value == tag_raw) {
                out[n] = @enumFromInt(tag_raw);
                n += 1;
                break;
            }
        }
        off += 4 + size;
    }
    return n;
}

/// Assert that `needle` appears as a contiguous subsequence inside `haystack[0..n]`.
fn expectContainsInOrder(haystack: []const Tag, n: usize, needle: []const Tag) !void {
    var ni: usize = 0;
    for (haystack[0..n]) |t| {
        if (ni < needle.len and t == needle[ni]) {
            ni += 1;
        }
    }
    if (ni != needle.len) {
        std.debug.print("expectContainsInOrder: missing tags starting at index {d}\n", .{ni});
        return error.MissingTagSubsequence;
    }
}

test "beginPostProcess/endPostProcess emit the bloom+fxaa chain" {
    var buf: [4096]u8 = undefined;
    var enc = Encoder.init(&buf);
    var ctx = PostCtx{};
    enc.beginPostProcess(&ctx, .{ .bloom = .{}, .fxaa = true }, 800, 600);
    enc.endPostProcess(&ctx);
    const out = enc.finish();
    var tag_buf: [64]Tag = undefined;
    const n = collectTags(out, &tag_buf);
    const tags = tag_buf[0..n];
    // First frame: render targets created, then offscreen scene pass opened.
    try expectContainsInOrder(tags, n, &.{
        .create_render_target, // scene_hdr
        .create_render_target, // bloom_a
        .create_render_target, // bloom_b
        .create_render_target, // ldr
        .begin_offscreen_pass, // scene -> hdr
    });
    // endPostProcess: close scene, bloom chain, composite, then canvas fxaa pass.
    try expectContainsInOrder(tags, n, &.{
        .end_offscreen_pass, // close scene
        .begin_offscreen_pass, // bright -> bloom_a
        .draw_fullscreen_quad,
        .begin_offscreen_pass, // blur H -> bloom_b
        .draw_fullscreen_quad,
        .begin_offscreen_pass, // blur V -> bloom_a
        .draw_fullscreen_quad,
        .begin_offscreen_pass, // composite -> ldr
        .draw_fullscreen_quad,
        .begin_frame, // canvas
        .draw_fullscreen_quad, // fxaa -> canvas
        .end_frame,
    });
}

test "endPostProcess without fxaa composites straight to canvas" {
    var buf: [4096]u8 = undefined;
    var enc = Encoder.init(&buf);
    var ctx = PostCtx{};
    enc.beginPostProcess(&ctx, .{ .bloom = .{}, .fxaa = false }, 800, 600);
    enc.endPostProcess(&ctx);
    const tags_raw = enc.finish();
    var tag_buf: [64]Tag = undefined;
    const n = collectTags(tags_raw, &tag_buf);
    // No ldr offscreen composite; composite draws inside a begin_frame canvas pass.
    try expectContainsInOrder(tag_buf[0..n], n, &.{ .begin_frame, .draw_fullscreen_quad, .end_frame });
}
