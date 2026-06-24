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
    set_lights = 11, // {count, ptr -> count*16 f32 (4 vec4/light: v0=type/intensity/pos.xy, v1=pos.z/dir.xyz, v2=color.rgb/range, v3=cosIn/cosOut/__/__}
    bind_ibl = 12, // {irr, spec, lut, spec_mip_count}
    draw_pbr = 13, // {vbuf, ibuf, index_byte_off, index_count, mvp_ptr, model_ptr, normal_ptr, material_ptr, camera_ptr}
    delete_resource = 14, // {kind, handle} — frees one GPU object; slot may be reused after
    create_texture_srgb = 15, // {handle, width, height, ptr, len} raw RGBA8 → SRGB8_ALPHA8 internal (P8); same layout as tag 7
    // ── P9 slice 3: single directional shadow map ──────────────────────
    create_shadow_map = 16, // {handle, size} — FBO + DEPTH_COMPONENT24 depth tex (size²), compare mode for sampler2DShadow
    begin_shadow_pass = 17, // {atlas_handle, depth_shader_handle, col, row, tile} — bind atlas FBO, set viewport+scissor to (col*tile,row*tile,tile,tile), scissor-clear that tile's depth, bind depth shader
    end_shadow_pass = 18, // {width, height} — unbind FBO back to canvas, restore viewport
    draw_depth = 19, // {vbuf, ibuf, index_byte_off, index_count, mvp_ptr} — depth-only draw (mvp = light_vp·world)
    bind_shadow_map = 20, // {slot, atlas_handle, vp_ptr, count} — bind 2D shadow atlas to slot + upload `count` mat4 → u_shadow_vp[0..count] (shadow_vp[0..count] WGSL)
    set_bones = 21, // {count, ptr} — count×mat4 bone palette → u_bones[] on the active program
    // ── Post-processing ─────────────────────────────────────────────────
    create_render_target = 22, // {handle, width, height, format, flags(bit0=with_depth)} — color RT (+optional depth)
    begin_offscreen_pass = 23, // {target_handle, clear_rgba(4 f32), clear_flags(bit0=color,bit1=depth)} — bind RT
    end_offscreen_pass = 24, // {} — close the offscreen pass; next begin_* rebinds
    draw_fullscreen_quad = 25, // {shader, tex0, tex1, params_ptr, param_count} — VBO-less 3-vert triangle
    draw_depth_at = 26, // {shader, vbuf, ibuf, index_byte_off, index_count, mvp_ptr, material_ptr} — alpha-tested depth draw (MASK shadows)
    draw_pbr_instanced = 27, // {vbuf, ibuf, off, count, instance_ptr, instance_count, vp_ptr, material_ptr, camera_ptr}
    set_fog = 28, // {ptr -> 8 f32 FogParams}
    set_morph_weights = 29, // {count, idx_ptr -> count u32, wt_ptr -> count f32}
    create_morph_tex = 30, // {handle, width, height, ptr -> f16 deltas, byte_len}
    // ── Point-light (omnidirectional) shadow atlas ──────────────────────
    create_point_shadow = 31, // {handle, w, h} — RGBA8 atlas + depth scratch
    begin_point_shadow_face = 32, // {handle, col, row, tile, face_vp_ptr, light_pos_ptr, far_bits}
    draw_point_depth = 33, // {vbuf, ibuf, index_byte_off, index_count, model_ptr}
    end_point_shadow = 34, // {width, height}
    bind_point_shadow = 35, // {slot, handle} — binds the point atlas texture to `slot`; caster pos/far come from the lights array (lpos=v0.zw/v1.x, far=v2.w=lrange)
    // ── Cascaded shadow maps (CSM directional) ──────────────────────────
    set_csm = 36, // {cascade_count, splits_ptr, view_forward_ptr} — frame-global CSM params for the directional caster.
    //   Cache cascade_count, the 4 f32 at splits_ptr (cascade_splits — view-space FAR distance per cascade),
    //   and the 3 f32 at view_forward_ptr (normalized camera look dir). The bridge (S2T2) writes them into each
    //   shadowed draw's U at cascade_count@1024 / cascade_splits@1040 / view_forward@1056. Per-frame transient
    //   (re-emitted each frame, NOT recorded into the registry) — mirrors set_lights.
    // ── Slice 3: rect area lights (LTC) ─────────────────────────────────
    set_area_lights = 37, // {count, ptr -> count*16 f32 (4 vec4/area light)} — mirrors set_lights (tag 11). Per-frame transient.
    //   Cache count + the count*16 f32 at ptr; the bridge writes them into each PBR draw's U at
    //   area_count@504 / area_lights@512 (always present, before the shadow block). See max_area_lights packing.
    bind_ltc_lut = 38, // {ltc_mat_handle, ltc_mag_handle} — bind the two LTC LUT textures to tex_slot_ltc_mat(10)/tex_slot_ltc_mag(11).
    //   Mirrors bind_ibl (tag 12). The bridge binds dummy 1×1 LUTs when no area light (like the IBL fallback) so the
    //   LTC samplers are always valid. Must follow SET_PIPELINE (writes uniforms/binds on the active program).
    // ── Image-quality slice 1: depth + view-space normal prepass ────────
    draw_prepass = 39, // {vbuf, ibuf, index_byte_off, index_count, mvp_ptr, mv_ptr} — geometry draw into the G-buffer.
    //   Mirrors draw_depth (tag 19) + a second mat4 pointer. The prepass program (variant_prepass) reads pos+normal of
    //   the stride-48 PBR layout and writes rgb=viewNormal*0.5+0.5, a=-viewPos.z into the rgba16f G-buffer (h_gbuffer).
    //   mvp = proj·view·model (clip pos); mv = view·model (no projection; transforms normals + gives viewPos).
};

pub const ResKind = enum(u32) { buffer = 0, texture = 1, shader = 2, shadow_map = 3, render_target = 4 };

pub const BufferKind = enum(u32) { vertex = 0, index = 1 };

/// SET_PIPELINE state bits.
pub const state_depth_test: u32 = 1 << 0;
pub const state_cull_back: u32 = 1 << 1;
pub const state_blend: u32 = 1 << 2; // src-alpha over; depth-write off (transparency)
pub const state_cull_front: u32 = 1 << 3; // enable CULL_FACE + cullFace(FRONT) — renders back faces (double-sided BLEND back pass)

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
pub const variant_alpha_test: u32 = 1 << 10; // requires variant_pbr; MASK cutout (discard below alphaCutoff)
pub const variant_double_sided: u32 = 1 << 11; // requires variant_pbr; render both faces, flip back-face normal
pub const variant_instanced: u32 = 1 << 12; // requires variant_pbr; per-instance model (attr 4-7) + color (attr 8); non-skinned
pub const variant_fog: u32 = 1 << 13; // requires variant_pbr; distance fog mix before tonemap
pub const variant_morph: u32 = 1 << 14; // requires variant_pbr; texture-blended POSITION+NORMAL morph deltas
pub const variant_shadow_point: u32 = 1 << 15; // requires variant_pbr; omnidirectional point-light shadow receiver (RGBA8 atlas)
pub const variant_prepass: u32 = 1 << 16; // depth + view-space normal prepass; rgba16f G-buffer (rgb=n*0.5+0.5, a=-viewPos.z). Standalone shader pair (mvp+mv UBO), not a PBR add-on.

/// Render-target creation flags.
pub const rt_flag_with_depth: u32 = 1 << 0;
/// Offscreen-pass clear flags.
pub const clear_flag_color: u32 = 1 << 0;
pub const clear_flag_depth: u32 = 1 << 1;

pub const max_lights: u32 = 4;
// ── Slice 3: rect area lights (LTC) ─────────────────────────────────
// Up to `max_area_lights` RectAreaLights, evaluated per PBR draw via LTC.
// area_lights is in the BASE U (always present); area_count=0 → loop is a no-op.
// Packing (each area light = 4 vec4, into area_lights[4*i .. 4*i+3]):
//   a0 = [pos.x, pos.y, pos.z, intensity]
//   a1 = [ex.x, ex.y, ex.z, two_sided]     (ex = half-width edge vector)
//   a2 = [ey.x, ey.y, ey.z, shadow_slot]   (ey = half-height edge vector; shadow_slot = 2D-atlas slot or -1)
//   a3 = [color.r, color.g, color.b, shadow_kind]  (0 none / 1 = 2D shadow)
// Rect corners (CCW, light shines in local -ey×ex normal dir, matching three.js):
//   c0 = pos + ex - ey   c1 = pos - ex - ey   c2 = pos - ex + ey   c3 = pos + ex + ey
pub const max_area_lights: u32 = 4;
pub const area_light_stride_f32: u32 = 16; // 4 vec4 per area light
pub const light_stride_f32: u32 = 16; // v0:[type,intensity,pos.x,pos.y]  v1:[pos.z,dir.x,dir.y,dir.z]  v2:[color.r,color.g,color.b,range]  v3:[cos_inner,cos_outer,shadow_index,shadow_kind]
// v3.z = shadow_index: for a 2D caster → index in shadow_vp[] AND its tile in the 2D atlas (0..3);
//        for a point caster → its point-caster index (0..3). -1.0 = this light casts no shadow.
// v3.w = shadow_kind: 0 = none, 1 = 2D (directional/spot), 2 = point, 3 = CSM directional (cascade-select).
// For shadow_kind 3 (CSM), v3.z is the BASE shadow_vp[] index of cascade 0; the receiver
// selects cascade ci by view-space depth and samples shadow_vp[base + ci] (each cascade
// is its own ortho VP in its own 2D-atlas tile). cascade_count / cascade_splits come from U.

// ── Simultaneous multi-caster shadow contract (Slice 1 + Slice 2 CSM) ─────────────
// Up to `max_lights` lights may cast at once, in any mix of 2D / point.
// shadow_vp[] holds (up to max_csm_cascades) CSM cascades + single 2D casters; 8 covers
// 4 cascades + 4 spots. The 16-tile atlas (4×4) supports all 8 in rows 0..1.
pub const max_2d_casters: u32 = 8; // CSM cascades + directional/spot casters share the 2D atlas; index 0..7
pub const max_csm_cascades: u32 = 4; // a CSM directional light splits into up to this many cascades
pub const max_point_casters: u32 = 4; // point casters share the cube atlas; index 0..3
// CONTRACT (T3 MUST honor): a point caster's range (light v2.w = lrange) MUST equal the
// far plane used in its depth pass (begin_point_shadow_face far_bits). The receiver normalises
// distance by range (`length(v) / far`), so range=0 or "unlimited" is ILLEGAL for a shadow
// caster — the scene must clamp the light's range to the actual depth-pass far.
// 2D shadow atlas geometry. CHANGING THESE REQUIRES the verve.js atlas-create AND
// the in-shader shadowFactor2D constants to move in lockstep.
pub const shadow_atlas_dim: u32 = 4096; // full atlas is shadow_atlas_dim²
pub const shadow_tile_dim: u32 = 1024; // → 4 tiles per row, 16 tiles total; up to 8 used in rows 0..1
pub const shadow_tiles_per_row: u32 = 4;
// Point shadow atlas geometry. 3 cols × 8 rows of 512² tiles = 6 faces × 4 casters.
// Caster `c` occupies rows [c*2, c*2+1]; face `f` → col = f%3, row = c*2 + f/3.
// CHANGING THESE REQUIRES the verve.js point-atlas-create AND the in-shader
// pointShadowFactor constants to move in lockstep.
pub const point_atlas_w: u32 = 1536; // 3 × 512
pub const point_atlas_h: u32 = 4096; // 8 × 512 (was effectively 1024 for one caster)
pub const fog_params_f32: u32 = 8; // [mode, r,g,b, near, far, density, _pad]
pub const morph_max_active: u32 = 8; // K: max simultaneously-active morph influences
pub const material_len_f32: u32 = 12; // base_color rgba | metallic, roughness, occlusion_strength, normal_scale | emissive rgb, 0

pub const tex_slot_base: u32 = 0;
pub const tex_slot_mr: u32 = 1;
pub const tex_slot_normal: u32 = 2;
pub const tex_slot_emissive: u32 = 3;
pub const tex_slot_occlusion: u32 = 4;
// IBL units (JS contract): irradiance=5 (cube), prefiltered=6 (cube), brdf_lut=7 (2D)
pub const tex_slot_shadow: u32 = 8; // directional shadow map (sampler2DShadow), after the IBL units
pub const tex_slot_point_shadow: u32 = 9; // point-light RGBA8 shadow atlas (sampler2D), slot after directional
// ── Slice 3: rect area lights (LTC) ─────────────────────────────────
pub const tex_slot_ltc_mat: u32 = 10; // LTC_1 LUT (Minv reconstruction), 64×64 RGBA float; ALWAYS bound (dummy when no area light)
pub const tex_slot_ltc_mag: u32 = 11; // LTC_2 LUT (magnitude + fresnel), 64×64 RGBA float; ALWAYS bound

/// GLSL float-to-RGBA8 packing helpers shared between the point-depth and receiver shaders.
pub const rgba8_pack_glsl: []const u8 = "vec4 packDist(float v){ vec4 e=fract(v*vec4(1.0,255.0,65025.0,16581375.0)); e-=e.yzww*vec4(1.0/255.0,1.0/255.0,1.0/255.0,0.0); return e; }";
pub const rgba8_unpack_glsl: []const u8 = "float unpackDist(vec4 c){ return dot(c, vec4(1.0,1.0/255.0,1.0/65025.0,1.0/16581375.0)); }";

/// WGSL float-to-RGBA8 packing helpers (same constants, vec4f).
pub const rgba8_pack_wgsl: []const u8 = "fn packDist(v: f32) -> vec4f { var e = fract(v*vec4f(1.0,255.0,65025.0,16581375.0)); e -= e.yzww*vec4f(1.0/255.0,1.0/255.0,1.0/255.0,0.0); return e; }";
pub const rgba8_unpack_wgsl: []const u8 = "fn unpackDist(c: vec4f) -> f32 { return dot(c, vec4f(1.0,1.0/255.0,1.0/65025.0,1.0/16581375.0)); }";

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
    // Morph-target uniforms (variant_morph): sampler2D texture (RGBA16F,
    // width=vertex_count, height=target_count*2), per-active-target indices +
    // weights, and the count of active targets (≤ morph_max_active = 8).
    const morph_uniforms =
        \\uniform highp sampler2D u_morph_tex;
        \\uniform int u_morph_idx[8];
        \\uniform float u_morph_wt[8];
        \\uniform int u_morph_count;
        \\
    ;
    // Morph body_open: opens void main(), accumulates morph deltas into m_pos/
    // m_nrm (frozen texel convention: row 2*t=POS, 2*t+1=NORM, x=gl_VertexID),
    // then transforms the morphed locals.  Replaces body_open on the morph path.
    const body_open_morph =
        \\void main() {
        \\  vec3 m_pos = a_pos;
        \\  vec3 m_nrm = a_normal;
        \\  for (int i = 0; i < u_morph_count; i++) {
        \\    int t = u_morph_idx[i];
        \\    float w = u_morph_wt[i];
        \\    m_pos += w * texelFetch(u_morph_tex, ivec2(gl_VertexID, 2 * t), 0).xyz;
        \\    m_nrm += w * texelFetch(u_morph_tex, ivec2(gl_VertexID, 2 * t + 1), 0).xyz;
        \\  }
        \\  v_world_pos = (u_model * vec4(m_pos, 1.0)).xyz;
        \\  v_normal = u_normal_mat * m_nrm;
        \\  v_uv = a_uv;
        \\
    ;
    // Morph body_close: feeds m_pos into gl_Position (non-skinned).
    const body_close_morph =
        \\  gl_Position = u_mvp * vec4(m_pos, 1.0);
        \\}
        \\
    ;
    // Shadow receiver (variant_shadow): light-space positions are computed per
    // caster IN THE FRAGMENT shader from v_world_pos and u_shadow_vp[slot], so the
    // vertex stage carries NO shadow uniform or varying anymore.
    // Instanced (variant_instanced): per-instance mat4 model columns as vertex
    // attributes (loc 4-7) + per-instance color (loc 8); u_vp replaces u_mvp/u_model.
    // All non-instanced bytes stay byte-identical; this block is appended ONLY under the gate.
    const inst_decl =
        \\uniform mat4 u_vp;
        \\layout(location = 4) in vec4 a_inst_model0;
        \\layout(location = 5) in vec4 a_inst_model1;
        \\layout(location = 6) in vec4 a_inst_model2;
        \\layout(location = 7) in vec4 a_inst_model3;
        \\layout(location = 8) in vec4 a_inst_color;
        \\out vec4 v_inst_color;
        \\
    ;
    const inst_body =
        \\void main() {
        \\  mat4 model = mat4(a_inst_model0, a_inst_model1, a_inst_model2, a_inst_model3);
        \\  vec4 world_pos4 = model * vec4(a_pos, 1.0);
        \\  v_world_pos = world_pos4.xyz;
        \\  v_normal = normalize(mat3(model) * a_normal);
        \\  v_uv = a_uv;
        \\  v_inst_color = a_inst_color;
        \\  gl_Position = u_vp * world_pos4;
        \\}
        \\
    ;
    const skinned = flags & variant_skinned != 0;
    const morphed = flags & variant_morph != 0;
    comptime var src: []const u8 = head;
    if (flags & variant_instanced != 0) {
        src = src ++ inst_decl;
        src = src ++ inst_body;
        return src;
    }
    if (morphed and skinned) @compileError("variant_morph + variant_skinned not supported this slice");
    if (flags & variant_normal_map != 0) src = src ++ nm_outs;
    if (skinned) src = src ++ skin_decl;
    if (morphed) src = src ++ morph_uniforms;
    if (morphed) {
        src = src ++ body_open_morph;
    } else if (skinned) {
        src = src ++ body_open_skinned;
    } else {
        src = src ++ body_open;
    }
    if (flags & variant_normal_map != 0) src = src ++ (if (skinned) nm_body_skinned else nm_body);
    if (morphed) {
        src = src ++ body_close_morph;
    } else if (skinned) {
        src = src ++ body_close_skinned;
    } else {
        src = src ++ body_close;
    }
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

/// Depth-alpha-test vertex shader for the shadow pass. Like depthVertexSrc but
/// also passes UV to the fragment stage so the fragment can sample the base
/// texture and discard transparent pixels. Vertex layout: pos at location 0
/// (offset 0), UV at location 1 (offset 40) — matching the PBR stride-48 VBO.
pub fn depthAtVertexSrc() []const u8 {
    return
    \\#version 300 es
    \\layout(location = 0) in vec3 a_pos;
    \\layout(location = 1) in vec2 a_uv;
    \\uniform mat4 u_mvp;
    \\out vec2 v_uv;
    \\void main() {
    \\  v_uv = a_uv;
    \\  gl_Position = u_mvp * vec4(a_pos, 1.0);
    \\}
    \\
    ;
}

/// Depth-alpha-test fragment shader. Discards pixels where
/// baseTexAlpha × base_color.a < alphaTestCutoff so the shadow map records
/// holes in cutout (MASK) geometry. u_material[0].w = base_color.a (dissolve),
/// u_material[2].w = alpha cutoff.
pub fn depthAtFragmentSrc() []const u8 {
    return
    \\#version 300 es
    \\precision highp float;
    \\in vec2 v_uv;
    \\uniform sampler2D u_base_tex;
    \\uniform vec4 u_material[3];
    \\void main() {
    \\  if (texture(u_base_tex, v_uv).a * u_material[0].w < u_material[2].w) discard;
    \\}
    \\
    ;
}

// ── Image-quality slice 1: depth + view-space normal prepass (GLSL) ──────
//
// A standalone shader pair (NOT a PBR add-on) rendered once before the main
// PBR pass into the rgba16f G-buffer. Reads pos (attrib 0) + normal (attrib 1)
// of the stride-48 PBR layout. Outputs: rgb = viewNormal*0.5+0.5, a = -viewPos.z
// (linear view-space depth, positive in front of the camera). Uniforms:
// u_mvp = proj·view·model (clip position); u_mv = view·model (view-space pos +
// normal transform; mv's upper-3×3 is used directly — exact for rigid /
// uniform-scale transforms, adequate for the debug G-buffer).

pub fn prepassVertexSrc() []const u8 {
    return
    \\#version 300 es
    \\layout(location = 0) in vec3 a_pos;
    \\layout(location = 1) in vec3 a_normal;
    \\uniform mat4 u_mvp;
    \\uniform mat4 u_mv;
    \\out vec3 v_view_normal;
    \\out vec3 v_view_pos;
    \\void main() {
    \\  v_view_normal = mat3(u_mv) * a_normal;
    \\  v_view_pos = (u_mv * vec4(a_pos, 1.0)).xyz;
    \\  gl_Position = u_mvp * vec4(a_pos, 1.0);
    \\}
    \\
    ;
}

pub fn prepassFragmentSrc() []const u8 {
    return
    \\#version 300 es
    \\precision highp float;
    \\in vec3 v_view_normal;
    \\in vec3 v_view_pos;
    \\out vec4 o_gbuffer;
    \\void main() {
    \\  vec3 n = normalize(v_view_normal);
    \\  o_gbuffer = vec4(n * 0.5 + 0.5, -v_view_pos.z);
    \\}
    \\
    ;
}

/// G-buffer debug fullscreen fragment (GLSL, variant_post). Samples the prepass
/// G-buffer bound at tex0. u_threshold (params.x) selects the mode: 0 = view
/// normals (the rgb channel passed through), 1 = linearized depth grayscale
/// (the alpha channel, divided by a fixed range so the near cube reads darker
/// than the far background). Reuses the shared fullscreen vertex + post params.
pub fn gbufferDebugFragmentSrc() []const u8 {
    return
    \\#version 300 es
    \\precision highp float;
    \\in vec2 v_uv;
    \\uniform sampler2D u_tex0;
    \\uniform float u_threshold;
    \\out vec4 o_color;
    \\void main() {
    \\  vec4 g = texture(u_tex0, v_uv);
    \\  if (u_threshold > 0.5) {
    \\    float d = clamp(g.a / 10.0, 0.0, 1.0);
    \\    o_color = vec4(vec3(d), 1.0);
    \\  } else {
    \\    o_color = vec4(g.rgb, 1.0);
    \\  }
    \\}
    \\
    ;
}

/// Point-light distance depth vertex shader.  Writes world-space position to
/// `v_world` so the fragment can compute linear distance from the light.
/// Uniforms: `u_face_vp` (mat4, cube-face view-projection), `u_model` (mat4).
/// Vertex layout: position at attrib 0 (matching PBR stride-48 VBO).
pub fn pointDepthVertexSrc() []const u8 {
    return
    \\#version 300 es
    \\layout(location = 0) in vec3 a_pos;
    \\uniform mat4 u_face_vp;
    \\uniform mat4 u_model;
    \\out vec3 v_world;
    \\void main() {
    \\  vec4 world = u_model * vec4(a_pos, 1.0);
    \\  v_world = world.xyz;
    \\  gl_Position = u_face_vp * world;
    \\}
    \\
    ;
}

/// Point-light distance depth fragment shader.  Packs the normalised linear
/// distance from the light into RGBA8 colour using the P1 `packDist` helper.
/// Uniforms: `u_light_pos` (vec3 world-space), `u_far` (float, far-plane dist).
pub fn pointDepthFragmentSrc() []const u8 {
    // Inline pack const rather than runtime-concatenate so the return type is
    // a comptime-known string literal (required for Zig ++ on []const u8).
    return
    \\#version 300 es
    \\precision highp float;
    \\in vec3 v_world;
    \\uniform vec3 u_light_pos;
    \\uniform float u_far;
    \\out vec4 frag_color;
    \\vec4 packDist(float v){ vec4 e=fract(v*vec4(1.0,255.0,65025.0,16581375.0)); e-=e.yzww*vec4(1.0/255.0,1.0/255.0,1.0/255.0,0.0); return e; }
    \\void main() {
    \\  frag_color = packDist(clamp(length(v_world - u_light_pos) / u_far, 0.0, 1.0));
    \\}
    \\
    ;
}

/// Combined WGSL module for the point-depth pass (vertex + fragment).
/// Uniform struct U: face_vp mat4x4, model mat4x4, light_pos vec3, far f32.
/// Renders to an rgba8unorm colour attachment; depth scratch is side-effect.
pub fn pointDepthWgslSrc() []const u8 {
    return
    \\struct U { face_vp: mat4x4<f32>, model: mat4x4<f32>, light_pos: vec3<f32>, far: f32 }
    \\@group(0) @binding(0) var<uniform> u: U;
    \\struct VOut { @builtin(position) pos: vec4f, @location(0) world: vec3f }
    \\fn packDist(v: f32) -> vec4f { var e = fract(v*vec4f(1.0,255.0,65025.0,16581375.0)); e -= e.yzww*vec4f(1.0/255.0,1.0/255.0,1.0/255.0,0.0); return e; }
    \\@vertex fn vs_main(@location(0) a_pos: vec3f) -> VOut {
    \\  var o: VOut;
    \\  let world = u.model * vec4f(a_pos, 1.0);
    \\  o.world = world.xyz;
    \\  o.pos = u.face_vp * world;
    \\  return o;
    \\}
    \\@fragment fn fs_main(@location(0) world: vec3f) -> @location(0) vec4f {
    \\  return packDist(clamp(length(world - u.light_pos) / u.far, 0.0, 1.0));
    \\}
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
    const inst_in =
        \\in vec4 v_inst_color;
        \\
    ;
    // Per-instance tint. `main_open` already derived `albedo = base_sample *
    // base_color` from the UNtinted base_color, so albedo (the term lighting
    // actually consumes) must be re-tinted here too — tinting base_color alone
    // would only affect its alpha. Matches the WGSL path, which folds inst_color
    // into base_color BEFORE computing albedo.
    const inst_tint =
        \\  base_color *= v_inst_color;
        \\  albedo *= v_inst_color.rgb;
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
        \\uniform vec4 u_lights[16];
        \\uniform int u_light_count;
        \\uniform float u_prefiltered_mips;
        \\uniform int u_area_count;
        \\uniform vec4 u_area_lights[16];
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
        \\// ── LTC (Linearly Transformed Cosines) rect area lights ──
        \\// Transcribed from three.js r160 (selfshadow ltc_code). LUT data convention
        \\// matches ltc_data.zig: ltc_mat=LTC_1 (Minv), ltc_mag=LTC_2 (mag/fresnel).
        \\uniform sampler2D u_ltc_mat;
        \\uniform sampler2D u_ltc_mag;
        \\vec3 ltcEdgeVectorFormFactor(vec3 v1, vec3 v2) {
        \\  float x = dot(v1, v2);
        \\  float y = abs(x);
        \\  float a = 0.8543985 + (0.4965155 + 0.0145206 * y) * y;
        \\  float b = 3.4175940 + (4.1616724 + y) * y;
        \\  float v = a / b;
        \\  float theta_sintheta = (x > 0.0) ? v : 0.5 * inversesqrt(max(1.0 - x * x, 1e-7)) - v;
        \\  return cross(v1, v2) * theta_sintheta;
        \\}
        \\float ltcClippedSphereFormFactor(vec3 f) {
        \\  float l = length(f);
        \\  return max((l * l + f.z) / (l + 1.0), 0.0);
        \\}
        \\// Evaluate the LTC form factor for a quad (corners CCW) at shading point P.
        \\// mInv = identity for diffuse, the LUT-reconstructed Minv for specular.
        \\vec3 ltcEvaluate(vec3 N, vec3 V, vec3 P, mat3 mInv, vec3 c0, vec3 c1, vec3 c2, vec3 c3) {
        \\  vec3 v1 = c1 - c0;
        \\  vec3 v2 = c3 - c0;
        \\  vec3 lightNormal = cross(v1, v2);
        \\  if (dot(lightNormal, P - c0) < 0.0) return vec3(0.0);
        \\  vec3 T1 = normalize(V - N * dot(V, N));
        \\  vec3 T2 = -cross(N, T1);
        \\  mat3 basis = mat3(T1, T2, N);
        \\  mat3 m = mInv * transpose(basis);
        \\  vec3 p0 = normalize(m * (c0 - P));
        \\  vec3 p1 = normalize(m * (c1 - P));
        \\  vec3 p2 = normalize(m * (c2 - P));
        \\  vec3 p3 = normalize(m * (c3 - P));
        \\  vec3 ff = vec3(0.0);
        \\  ff += ltcEdgeVectorFormFactor(p0, p1);
        \\  ff += ltcEdgeVectorFormFactor(p1, p2);
        \\  ff += ltcEdgeVectorFormFactor(p2, p3);
        \\  ff += ltcEdgeVectorFormFactor(p3, p0);
        \\  return vec3(ltcClippedSphereFormFactor(ff));
        \\}
        \\
    ;
    const fog_uniforms =
        \\uniform vec4 u_fog0; // [mode, color.r, color.g, color.b]
        \\uniform vec4 u_fog1; // [near, far, density, _pad]
        \\
    ;
    const fog_mix =
        \\  float fog_dist = length(u_camera_pos - v_world_pos);
        \\  float fog_factor = 1.0;
        \\  if (u_fog0.x > 0.5) {
        \\    if (u_fog0.x < 1.5) {
        \\      fog_factor = (u_fog1.y - fog_dist) / max(u_fog1.y - u_fog1.x, 1e-4);
        \\    } else if (u_fog0.x < 2.5) {
        \\      fog_factor = exp(-u_fog1.z * fog_dist);
        \\    } else {
        \\      float fd = u_fog1.z * fog_dist;
        \\      fog_factor = exp(-fd * fd);
        \\    }
        \\    color = mix(u_fog0.yzw, color, clamp(fog_factor, 0.0, 1.0));
        \\  }
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
    const alpha_test =
        \\  if (texture(u_base_tex, v_uv).a * base_color.a < u_material[2].w) discard;
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
    const ds_flip =
        \\  N = gl_FrontFacing ? N : -N;
        \\
    ;
    // Light loop, split so the shadow variants can inject a per-light shadow
    // attenuation of `radiance` BEFORE the BRDF accumulation. For non-shadow
    // variants, lighting_head ++ lighting_tail is byte-identical to the original
    // single `lighting` string (no extra bytes leak into the non-shadow path).
    const lighting_head =
        \\  vec3 V = normalize(u_camera_pos - v_world_pos);
        \\  float NdotV = max(dot(N, V), 0.0);
        \\  vec3 F0 = mix(vec3(0.04), albedo, metallic);
        \\  float k_direct = (roughness + 1.0) * (roughness + 1.0) / 8.0;
        \\  float alpha = roughness * roughness;
        \\  vec3 Lo = vec3(0.0);
        \\  for (int i = 0; i < u_light_count; i++) {
        \\    vec4 v0 = u_lights[4 * i];
        \\    vec4 v1 = u_lights[4 * i + 1];
        \\    vec4 v2 = u_lights[4 * i + 2];
        \\    vec4 v3 = u_lights[4 * i + 3];
        \\    float ltype = v0.x;
        \\    float intensity = v0.y;
        \\    vec3 lpos = vec3(v0.z, v0.w, v1.x);
        \\    vec3 ldir = normalize(vec3(v1.y, v1.z, v1.w));
        \\    vec3 lcolor = v2.xyz;
        \\    float lrange = v2.w;
        \\    float cosIn = v3.x;
        \\    float cosOut = v3.y;
        \\    vec3 L;
        \\    vec3 radiance;
        \\    if (ltype < 0.5) {
        \\      L = -ldir;
        \\      radiance = lcolor * intensity;
        \\    } else {
        \\      vec3 Lvec = lpos - v_world_pos;
        \\      float dist = length(Lvec);
        \\      L = Lvec / max(dist, 1e-4);
        \\      float atten = 1.0 / max(dist * dist, 1e-4);
        \\      if (lrange > 0.0 && dist > lrange) atten = 0.0;
        \\      radiance = lcolor * intensity * atten;
        \\      if (ltype > 1.5) {
        \\        float cosA = dot(-L, ldir);
        \\        radiance *= smoothstep(cosOut, cosIn, cosA);
        \\      }
        \\    }
        \\
    ;
    // Per-light shadow attenuation, injected into the loop body after `radiance`
    // is computed and before the BRDF accumulation. Emitted only under a shadow
    // variant; the helper bodies (shadowFactor2D / pointShadowFactor) are emitted
    // only under their respective variants, but a light may pick either at runtime
    // via v3.w (shadow_kind) so we guard each branch on its variant too. Each
    // snippet keeps the loop-body indentation and a trailing newline so it slots
    // in between lighting_head and lighting_tail without disturbing the layout.
    // Guards are reordered/range-bounded so they stay mutually exclusive regardless
    // of emission order: sk>2.5 → CSM (kind 3), sk>1.5 → point (kind 2),
    // sk>0.5 → single 2D (kind 1). CSM is emitted under variant_shadow (csmFactor
    // lives in shadow_decls).
    const lighting_shadow_csm =
        \\    if (v3.w > 2.5) radiance *= csmFactor(int(v3.z + 0.5));
        \\
    ;
    const lighting_shadow_2d =
        \\    if (v3.w > 0.5 && v3.w < 1.5) radiance *= shadowFactor2D(int(v3.z + 0.5));
        \\
    ;
    const lighting_shadow_point =
        \\    if (v3.w > 1.5 && v3.w < 2.5) radiance *= pointShadowFactor(lpos, lrange, int(v3.z + 0.5));
        \\
    ;
    const lighting_tail =
        \\    vec3 H = normalize(V + L);
        \\    float NdotL = max(dot(N, L), 0.0);
        \\    float D = distributionGGX(N, H, alpha);
        \\    float G = geometrySmith(N, V, L, k_direct);
        \\    vec3 F = fresnelSchlick(max(dot(H, V), 0.0), F0);
        \\    vec3 spec = (D * G * F) / max(4.0 * NdotV * NdotL, 0.0001);
        \\    vec3 kD = (vec3(1.0) - F) * (1.0 - metallic);
        \\    Lo += (kD * albedo / PI + spec) * radiance * NdotL;
        \\  }
        \\
    ;
    // ── Rect area lights (LTC), evaluated after the punctual loop. ──
    // ALWAYS emitted (area_count=0 → no-op). Mirrors three.js RE_Direct_RectArea_Physical:
    //   diffuse  = albedo  * ltcEvaluate(N,V,P, mat3(1.0), corners)
    //   specular = fresnel * ltcEvaluate(N,V,P, Minv,      corners)
    // The form factor is already normalized (theta/sin/2pi in the edge term) — NO extra /PI.
    // Shadow multiply (a_kind > 0.5) is emitted ONLY under variant_shadow (shadowFactor2D lives there).
    const area_lighting_head =
        \\  for (int ai = 0; ai < u_area_count; ai++) {
        \\    vec4 a0 = u_area_lights[4 * ai];
        \\    vec4 a1 = u_area_lights[4 * ai + 1];
        \\    vec4 a2 = u_area_lights[4 * ai + 2];
        \\    vec4 a3 = u_area_lights[4 * ai + 3];
        \\    vec3 a_pos = a0.xyz;
        \\    float a_intensity = a0.w;
        \\    vec3 ex = a1.xyz;
        \\    vec3 ey = a2.xyz;
        \\    vec3 a_color = a3.xyz;
        \\    vec3 c0 = a_pos + ex - ey;
        \\    vec3 c1 = a_pos - ex - ey;
        \\    vec3 c2 = a_pos - ex + ey;
        \\    vec3 c3 = a_pos + ex + ey;
        \\    vec2 ltc_uv = vec2(roughness, sqrt(1.0 - NdotV)) * (63.0 / 64.0) + 0.5 / 64.0;
        \\    vec4 t1 = textureLod(u_ltc_mat, ltc_uv, 0.0);
        \\    vec4 t2 = textureLod(u_ltc_mag, ltc_uv, 0.0);
        \\    mat3 Minv = mat3(vec3(t1.x, 0.0, t1.y), vec3(0.0, 1.0, 0.0), vec3(t1.z, 0.0, t1.w));
        \\    vec3 a_fresnel = F0 * t2.x + (vec3(1.0) - F0) * t2.y;
        \\    vec3 a_diffuse = ltcEvaluate(N, V, v_world_pos, mat3(1.0), c0, c1, c2, c3);
        \\    vec3 a_spec = a_fresnel * ltcEvaluate(N, V, v_world_pos, Minv, c0, c1, c2, c3);
        \\    vec3 area_radiance = a_color * a_intensity;
        \\    vec3 area_contrib = area_radiance * (albedo * a_diffuse + a_spec);
        \\
    ;
    // 2D-shadow attenuation for an area caster — only emitted under variant_shadow.
    const area_lighting_shadow_2d =
        \\    if (a3.w > 0.5) area_contrib *= shadowFactor2D(int(a2.w + 0.5));
        \\
    ;
    const area_lighting_tail =
        \\    Lo += area_contrib;
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
    // Direct-light combine. The shadow is now folded into each light's `radiance`
    // inside the loop, so ALL variants use the plain combine; IBL ambient stays
    // unshadowed. Byte-identical to the pre-slice-3 source.
    const combine_plain =
        \\  vec3 color = ambient + Lo;
        \\
    ;
    // Shadow-receiver declarations (variant_shadow): a depth-compare sampler over
    // the 4096² 2D atlas + per-caster shadowFactor2D(slot). The light-space clip
    // position is recomputed per caster from u_shadow_vp[slot]·v_world_pos; PCF
    // samples are confined to the caster's 1024² tile (row 0, col = slot) so
    // neighbouring tiles never bleed. Hardware compare (sampler2DShadow + LINEAR)
    // gives 2×2 filtering per tap. shadow_atlas_dim/shadow_tile_dim/shadow_tiles_per_row
    // are the Zig constants of the same name — keep them in lockstep with verve.js.
    const shadow_decls =
        \\uniform highp sampler2DShadow u_shadow_map;
        \\uniform mat4 u_shadow_vp[8];
        \\uniform int u_cascade_count;
        \\uniform vec4 u_cascade_splits;
        \\uniform vec3 u_view_forward;
        \\float shadowFactor2D(int slot) {
        \\  vec4 lp = u_shadow_vp[slot] * vec4(v_world_pos, 1.0);
        \\  vec3 proj = lp.xyz / lp.w;
        \\  proj = proj * 0.5 + 0.5;
        \\  if (proj.z > 1.0) return 1.0;
        \\  float bias = 0.0015;
        \\  float tileScale = 1024.0 / 4096.0;
        \\  vec2 tile = vec2(float(slot - (slot / 4) * 4), float(slot / 4));
        \\  float texel = 1.0 / 4096.0;
        \\  vec2 pclamp = clamp(proj.xy, vec2(0.0), vec2(1.0));
        \\  float sum = 0.0;
        \\  for (int y = -1; y <= 1; y++)
        \\    for (int x = -1; x <= 1; x++) {
        \\      vec2 t = clamp(pclamp + vec2(x, y) * texel, vec2(0.0), vec2(1.0));
        \\      vec2 atlasUv = (tile + t) * tileScale;
        \\      sum += texture(u_shadow_map, vec3(atlasUv, proj.z - bias));
        \\    }
        \\  return sum / 9.0;
        \\}
        \\// CSM: select a cascade by view-space depth (viewZ = dot(world-camera, fwd)),
        \\// sample shadow_vp[base+ci], blend into the next cascade near the boundary.
        \\float csmFactor(int base) {
        \\  float viewZ = dot(v_world_pos - u_camera_pos, u_view_forward);
        \\  int ci = u_cascade_count - 1;
        \\  for (int i = 0; i < 4; i++) {
        \\    if (i >= u_cascade_count) break;
        \\    if (viewZ <= u_cascade_splits[i]) { ci = i; break; }
        \\  }
        \\  float f = shadowFactor2D(base + ci);
        \\  if (ci < u_cascade_count - 1) {
        \\    float prev = (ci == 0) ? 0.0 : u_cascade_splits[ci - 1];
        \\    float far = u_cascade_splits[ci];
        \\    float band = 0.1 * (far - prev);
        \\    if (band > 0.0001 && viewZ > far - band) {
        \\      float t = clamp((viewZ - (far - band)) / band, 0.0, 1.0);
        \\      f = mix(f, shadowFactor2D(base + ci + 1), t);
        \\    }
        \\  }
        \\  return f;
        \\}
        \\
    ;
    // Point-shadow receiver (variant_shadow_point): RGBA8 atlas sampler +
    // per-caster pointShadowFactor(lpos, far, pidx). Light pos & far come from the
    // per-light loop vars (no dedicated uniform). The atlas is now 1536×4096
    // (3 cols × 8 rows of 512² tiles); caster `pidx` occupies rows [pidx*2,
    // pidx*2+1], face f → col = f%3, row = pidx*2 + f/3.
    // Face order: 0=+X, 1=−X, 2=+Y, 3=−Y, 4=+Z, 5=−Z (matches cubeFaceVp).
    // uvc signs per face (WGSL twin must mirror EXACTLY — wire-frozen):
    //   face 0 (+X): uvc = vec2(-v.z, -v.y)
    //   face 1 (-X): uvc = vec2( v.z, -v.y)
    //   face 2 (+Y): uvc = vec2( v.x,  v.z)
    //   face 3 (-Y): uvc = vec2( v.x, -v.z)
    //   face 4 (+Z): uvc = vec2( v.x, -v.y)
    //   face 5 (-Z): uvc = vec2(-v.x, -v.y)
    // Bias: 0.01 (normalised distance). In-tile clamp [0.0008,0.9992] stays
    // tile-local (applied before adding the tile offset).
    const point_shadow_decls =
        \\uniform sampler2D u_point_atlas;
        \\float unpackDist(vec4 c){ return dot(c, vec4(1.0,1.0/255.0,1.0/65025.0,1.0/16581375.0)); }
        \\float pointShadowFactor(vec3 lpos, float far, int pidx) {
        \\  vec3 v = v_world_pos - lpos;
        \\  float cur = length(v) / far;
        \\  vec3 a = abs(v);
        \\  float ma; int face; vec2 uvc;
        \\  if (a.x >= a.y && a.x >= a.z) {
        \\    ma = a.x;
        \\    if (v.x > 0.0) { face = 0; uvc = vec2(-v.z, -v.y); }
        \\    else           { face = 1; uvc = vec2( v.z, -v.y); }
        \\  } else if (a.y >= a.z) {
        \\    ma = a.y;
        \\    if (v.y > 0.0) { face = 2; uvc = vec2( v.x,  v.z); }
        \\    else           { face = 3; uvc = vec2( v.x, -v.z); }
        \\  } else {
        \\    ma = a.z;
        \\    if (v.z > 0.0) { face = 4; uvc = vec2( v.x, -v.y); }
        \\    else           { face = 5; uvc = vec2(-v.x, -v.y); }
        \\  }
        \\  vec2 uv = 0.5 * (uvc / ma + 1.0);
        \\  vec2 tile = vec2(float(face - (face / 3) * 3), float(pidx * 2 + face / 3));
        \\  float bias = 0.01;
        \\  vec2 texel = 1.0 / vec2(1536.0, 4096.0);
        \\  float lit = 0.0;
        \\  for (int dy = -1; dy <= 1; dy++) {
        \\    for (int dx = -1; dx <= 1; dx++) {
        \\      vec2 fuv = clamp(uv + vec2(float(dx), float(dy)) / 512.0,
        \\                       vec2(0.0008), vec2(0.9992));
        \\      vec2 atlasUv = (tile + fuv) * vec2(1.0 / 3.0, 1.0 / 8.0);
        \\      float stored = unpackDist(texture(u_point_atlas, atlasUv));
        \\      lit += (cur <= stored + bias) ? 1.0 : 0.0;
        \\    }
        \\  }
        \\  return lit / 9.0;
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
    if (flags & variant_instanced != 0) src = src ++ inst_in;
    if (flags & variant_normal_map != 0) src = src ++ nm_ins;
    src = src ++ uniforms;
    if (flags & variant_normal_map != 0) src = src ++ nm_sampler;
    if (flags & variant_emissive != 0) src = src ++ em_sampler;
    src = src ++ ibl_samplers;
    if (flags & variant_fog != 0) src = src ++ fog_uniforms;
    if (flags & variant_shadow != 0) src = src ++ shadow_decls;
    if (flags & variant_shadow_point != 0) src = src ++ point_shadow_decls;
    src = src ++ main_open;
    if (flags & variant_instanced != 0) src = src ++ inst_tint;
    if (flags & variant_alpha_test != 0) src = src ++ alpha_test;
    src = src ++ (if (flags & variant_normal_map != 0) normal_nm else normal_plain);
    if (flags & variant_double_sided != 0) src = src ++ ds_flip;
    src = src ++ lighting_head;
    if (flags & variant_shadow != 0) src = src ++ lighting_shadow_csm;
    if (flags & variant_shadow_point != 0) src = src ++ lighting_shadow_point;
    if (flags & variant_shadow != 0) src = src ++ lighting_shadow_2d;
    src = src ++ lighting_tail;
    src = src ++ area_lighting_head;
    if (flags & variant_shadow != 0) src = src ++ area_lighting_shadow_2d;
    src = src ++ area_lighting_tail;
    src = src ++ combine_plain;
    if (flags & variant_emissive != 0) src = src ++ emissive;
    if (flags & variant_fog != 0) src = src ++ fog_mix;
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
    \\uniform sampler2D u_tex0;      // scene HDR
    \\uniform sampler2D u_tex1;      // bloom
    \\uniform float u_intensity;     // bloom intensity   (p_comp[0])
    \\uniform float u_tonemap;       // operator index    (p_comp[1])
    \\uniform float u_vig_intensity; // vignette strength (p_comp[2])
    \\uniform float u_vig_radius;    // vignette radius   (p_comp[3])
    \\vec3 aces(vec3 x) {
    \\  const float a=2.51, b=0.03, c=2.43, d=0.59, e=0.14;
    \\  return clamp((x*(a*x+b))/(x*(c*x+d)+e), 0.0, 1.0);
    \\}
    \\// Minimal AgX tone-mapper (Troy Sobotka / Filament).  This is the same
    \\// approximation that underlies three.js AgXToneMapping (r160+).
    \\// Steps: (1) linear sRGB → AgX log via input matrix; (2) log2-encode and
    \\// normalise over [-12.47393, 4.026069]; (3) 7th-order per-channel contrast
    \\// polynomial; (4) AgX output (inverse) matrix; (5) EOTF pow(·,2.2).
    \\// GLSL and WGSL twins share byte-identical matrices and coefficients.
    \\vec3 agxDefaultContrastApprox(vec3 x) {
    \\  vec3 x2 = x * x; vec3 x4 = x2 * x2;
    \\  return -0.00232 + x * (0.1191 + x * (0.4298 + x * (-6.868 +
    \\    x * (31.96 + x * (-40.14 + x * 15.5)))));
    \\}
    \\vec3 agx(vec3 v) {
    \\  // (1) input matrix: linear sRGB -> AgX log space
    \\  mat3 agxMat = mat3(
    \\    0.842479062253094, 0.0423282422610123, 0.0423756549057051,
    \\    0.0784335999999992, 0.878468636469772, 0.0784336,
    \\    0.0792237451477643, 0.0791661274605434, 0.879142973793104);
    \\  vec3 LOG2_MIN = vec3(-12.47393); vec3 LOG2_MAX = vec3(4.026069);
    \\  v = agxMat * v;
    \\  // (2) log2-encode + normalise to [0,1]
    \\  v = clamp(log2(max(v, vec3(1e-10))), LOG2_MIN, LOG2_MAX);
    \\  v = (v - LOG2_MIN) / (LOG2_MAX - LOG2_MIN);
    \\  // (3) per-channel contrast polynomial
    \\  v = agxDefaultContrastApprox(clamp(v, 0.0, 1.0));
    \\  // (4) output matrix: AgX log space -> linear sRGB
    \\  mat3 agxMatInv = mat3(
    \\    1.19687900512017, -0.0528968517574562, -0.0529716355144438,
    \\    -0.0980208811401368, 1.15190312990417, -0.0980434501171241,
    \\    -0.0990297440797205, -0.099043597298276, 1.15107367264116);
    \\  v = agxMatInv * v;
    \\  // (5) EOTF: AgX output gamma
    \\  return pow(clamp(v, vec3(0.0), vec3(1.0)), vec3(2.2));
    \\}
    \\vec3 hable(vec3 x) {
    \\  const float A=0.15, B=0.50, C=0.10, D=0.20, E=0.02, F=0.30;
    \\  return ((x*(A*x+C*B)+D*E)/(x*(A*x+B)+D*F))-E/F;
    \\}
    \\void main() {
    \\  vec3 hdr = texture(u_tex0, v_uv).rgb + u_intensity * texture(u_tex1, v_uv).rgb;
    \\  int op = int(u_tonemap + 0.5);
    \\  vec3 rgb;
    \\  if (op == 0) {
    \\    rgb = pow(clamp(hdr, 0.0, 1.0), vec3(1.0/2.2));
    \\  } else if (op == 1) {
    \\    vec3 x = hdr / (1.0 + hdr);
    \\    rgb = pow(x, vec3(1.0/2.2));
    \\  } else if (op == 2) {
    \\    const float W = 4.0;
    \\    vec3 x = hdr * (1.0 + hdr/(W*W)) / (1.0 + hdr);
    \\    rgb = pow(x, vec3(1.0/2.2));
    \\  } else if (op == 3) {
    \\    rgb = aces(hdr);
    \\  } else if (op == 4) {
    \\    rgb = agx(hdr);
    \\  } else {
    \\    const float W = 11.2;
    \\    vec3 x = hable(hdr * 2.0) / hable(vec3(W));
    \\    rgb = pow(x, vec3(1.0/2.2));
    \\  }
    \\  float d = length(v_uv - vec2(0.5));
    \\  float v = smoothstep(u_vig_radius, u_vig_radius - 0.45, d);
    \\  rgb *= mix(1.0, v, u_vig_intensity);
    \\  frag = vec4(rgb, 1.0);
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
//   material   : array<vec4<f32>,3> (offset 192)
//   lights     : array<vec4<f32>,16> (offset 240; 256B — 4 vec4/light × 4 lights)
//   light_count: i32              (offset 496)
//   prefiltered_mips: f32         (offset 500)
//   area_count : i32              (offset 504; 504..508)             [S3 — ALWAYS present]
//   area_lights: array<vec4<f32>,16> (offset 512; 256B → 512..768)  [S3 — 4 area lights × 4 vec4]
//   (variant_shadow) shadow_vp: array<mat4x4<f32>,8> (offset 768; 512B → 768..1280)
//   (variant_shadow) cascade_count:  i32        (offset 1280; 1280..1284)
//   (variant_shadow) cascade_splits: vec4<f32>  (offset 1296; 16-aligned, 1296..1312)
//   (variant_shadow) view_forward:   vec3<f32>  (offset 1312; 1312..1324, +4B pad → 1328)
//
// BASE (non-shadow) BYTE MAP (S3 — for T3 bridge / T4 scene):
//   ... lights@240, light_count@496, prefiltered_mips@500,
//   area_count@504 (i32), area_lights@512 (16 vec4 = 256B → 512..768)
//   struct size = 768  (was 512)
//
// SHADOW-VARIANT BYTE MAP (S3 — area block shifts the shadow block by 256):
//   area_count@504, area_lights@512..768,
//   shadow_vp@768 (8×mat4 = 512B → 768..1280)
//   cascade_count@1280   (i32,  1280..1284)
//   cascade_splits@1296  (vec4, 1296..1312 — view-space FAR distance per cascade)
//   view_forward@1312    (vec3, 1312..1324 — normalized camera look dir, +pad → 1328)
//   struct size = 1328  (was 1072)
//   PBR_STRIDE = align(1328, 256) = 1536  (was 1280)
//   PBR_U.size = 1328
// cascade_count / cascade_splits / view_forward live ONLY in the shadow variant.
// area_count / area_lights are in the BASE U (every PBR variant), offset 504/512.
//
// INSTANCED VARIANT (S3 — vp offset MOVED 512→768):
//   The instanced `vp: mat4x4` now sits AFTER area_lights, at offset 768 (where
//   shadow_vp would be). Instanced draws are non-shadow + non-area (area_count=0).
//   struct size = 768 + 64 = 832 (was 576). FLAG for T3: bridge instanced vp offset 512→768.
//
// Bindings (@group(1)): a shared sampler (binding 0) + per-slot textures.
// Slots mirror the GLSL sampler order / JS texture-unit contract:
//   1 base (2D), 2 metallic-roughness (2D), (F1) 3 normal (2D),
//   (F2) 4 emissive (2D), 5 occlusion (2D), 6 irradiance (cube),
//   7 prefiltered (cube), 8 brdf_lut (2D).
pub fn wgslPbr(comptime flags: u32) []const u8 {
    comptime pbrCheck(flags);
    if (flags & variant_depth != 0) @compileError("wgslPbr: variant_depth uses wgslDepth(), not wgslPbr");
    // variant_instanced appends `vp: mat4x4<f32>` at byte offset 768 (after the S3
    // area_lights block) — the same slot variant_shadow uses for `shadow_vp`. The two
    // are mutually exclusive in v1 (instanced draws are non-shadow receivers). Enforce
    // it here so a future caller cannot silently produce a broken WGSL U struct.
    if (flags & variant_instanced != 0 and flags & variant_shadow != 0)
        @compileError("wgslPbr: variant_instanced + variant_shadow unsupported in v1 (vp/shadow_vp slot collision at offset 768)");
    if (flags & variant_instanced != 0 and flags & variant_shadow_point != 0)
        @compileError("wgslPbr: variant_instanced + variant_shadow_point unsupported in v1 (point-shadow bind-group not wired for instanced draw path)");

    // ── Uniform block + group(0) ────────────────────────────────────
    // BASE U always carries area_count@504 (i32) + area_lights@512 (16 vec4 → 512..768).
    // variant_shadow then appends `shadow_vp: array<mat4x4,8>` (offset 768; 512B → 768..1280)
    // plus the CSM fields (cascade_count@1280, cascade_splits@1296, view_forward@1312)
    // without changing the base bytes. shadow struct size 1328, PBR_STRIDE = align(1328,256) = 1536.
    const uniforms_head =
        \\struct U {
        \\  mvp: mat4x4<f32>,
        \\  model: mat4x4<f32>,
        \\  normal_mat: mat3x3<f32>,
        \\  camera_pos: vec3<f32>,
        \\  material: array<vec4<f32>, 3>,
        \\  lights: array<vec4<f32>, 16>,
        \\  light_count: i32,
        \\  prefiltered_mips: f32,
        \\  area_count: i32,
        \\  area_lights: array<vec4<f32>, 16>,
        \\
    ;
    const uniforms_shadow =
        \\  shadow_vp: array<mat4x4<f32>, 8>,
        \\  cascade_count: i32,
        \\  cascade_splits: vec4<f32>,
        \\  view_forward: vec3<f32>,
        \\
    ;
    // Instanced (variant_instanced): view-projection only (model comes from
    // per-instance vertex attributes loc 4-7).
    const uniforms_vp =
        \\  vp: mat4x4<f32>,
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
    // Fog parameters (variant_fog). A SEPARATE group(0) binding at @binding(2).
    const uniforms_fog =
        \\struct Fog {
        \\  a: vec4<f32>, // [mode, color.r, color.g, color.b]
        \\  b: vec4<f32>, // [near, far, density, _pad]
        \\};
        \\@group(0) @binding(2) var<uniform> fog: Fog;
        \\
    ;
    // Morph-target parameters (variant_morph). SEPARATE group(0) bindings at
    // @binding(3) (UBO) and @binding(4) (texture), both VERTEX-visible.
    // UBO layout (std140-compatible, 80 bytes):
    //   offset   0: idx: array<vec4<i32>, 2>  → 2×16 bytes = 32 bytes (8 i32 slots)
    //   offset  32: wt:  array<vec4<f32>, 2>  → 2×16 bytes = 32 bytes (8 f32 slots)
    //   offset  64: count: i32                → 4 bytes (followed by 12 bytes implicit pad)
    // Access: morph.idx[i / 4][i % 4]  morph.wt[i / 4][i % 4]  morph.count
    // M6 writes the UBO matching this exact layout.
    const uniforms_morph =
        \\struct Morph { idx: array<vec4<i32>, 2>, wt: array<vec4<f32>, 2>, count: i32 };
        \\@group(0) @binding(3) var<uniform> morph: Morph;
        \\@group(0) @binding(4) var u_morph_tex: texture_2d<f32>;
        \\
    ;
    // (variant_shadow_point no longer needs a dedicated PointShadow uniform: each
    // caster's light pos & far come from the per-light loop vars lpos/lrange, and
    // pointShadowFactor takes them as args — mirrors the GLSL receiver exactly.)
    // Morph vertex function: adds @builtin(vertex_index) input, accumulates
    // POSITION + NORMAL deltas, then transforms the morphed locals.
    // vtx_index drives textureLoad (x-coord = vertex index, y-coord = 2*t or 2*t+1).
    const vs_head_morph =
        \\@vertex
        \\fn vs_main(
        \\  @location(0) a_pos: vec3<f32>,
        \\  @location(1) a_normal: vec3<f32>,
        \\  @location(2) a_tangent: vec4<f32>,
        \\  @location(3) a_uv: vec2<f32>,
        \\  @builtin(vertex_index) vtx_index: u32,
        \\) -> VSOut {
        \\  var out: VSOut;
        \\  var m_pos = a_pos;
        \\  var m_nrm = a_normal;
        \\  for (var i = 0; i < morph.count; i = i + 1) {
        \\    let t = morph.idx[i / 4][i % 4];
        \\    let w = morph.wt[i / 4][i % 4];
        \\    m_pos = m_pos + w * textureLoad(u_morph_tex, vec2<i32>(i32(vtx_index), 2 * t), 0).xyz;
        \\    m_nrm = m_nrm + w * textureLoad(u_morph_tex, vec2<i32>(i32(vtx_index), 2 * t + 1), 0).xyz;
        \\  }
        \\  out.world_pos = (u.model * vec4<f32>(m_pos, 1.0)).xyz;
        \\  out.normal = u.normal_mat * m_nrm;
        \\  out.uv = a_uv;
        \\
    ;
    const vs_tail_morph =
        \\  out.pos = u.mvp * vec4<f32>(m_pos, 1.0);
        \\  return out;
        \\}
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
    // Point-shadow receiver (variant_shadow_point): RGBA8 atlas sampler at
    // binding 11 (after the 2D shadow pair). Sampled with the group(1) filtering
    // sampler at binding 0 (textureSampleLevel, same samp as PBR textures).
    const tex_point_shadow =
        \\@group(1) @binding(11) var point_atlas: texture_2d<f32>;
        \\
    ;
    // LTC LUTs (rect area lights) at bindings 12/13. ALWAYS declared (the bridge
    // binds dummy 1×1 LUTs when no area light, like the IBL fallback) so the
    // group(1) bind-group layout stays valid across variants. Sampled with the
    // shared `samp` at binding 0 (textureSampleLevel, mip 0). tex_slot_ltc_mat=10
    // / tex_slot_ltc_mag=11 are the JS texture-unit slots; WGSL bindings are 12/13.
    const tex_ltc =
        \\@group(1) @binding(12) var ltc_mat: texture_2d<f32>;
        \\@group(1) @binding(13) var ltc_mag: texture_2d<f32>;
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
    // (variant_shadow no longer needs a light-space varying: the fragment
    // recomputes light-space position per caster from u.shadow_vp[slot] · world_pos.)
    // Instanced: per-instance color varying (next free location after shadow's 5).
    const vsout_inst_color =
        \\  @location(6) inst_color: vec4<f32>,
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
    // Instanced vs_main: reads per-instance mat4 model (col-major rows at loc 4-7)
    // + per-instance color (loc 8); reconstructs model, transforms position/normal,
    // writes inst_color varying. u.vp (view-proj) replaces u.mvp + u.model.
    const vs_head_instanced =
        \\@vertex
        \\fn vs_main(
        \\  @location(0) a_pos: vec3<f32>,
        \\  @location(1) a_normal: vec3<f32>,
        \\  @location(2) a_tangent: vec4<f32>,
        \\  @location(3) a_uv: vec2<f32>,
        \\  @location(4) inst_m0: vec4<f32>,
        \\  @location(5) inst_m1: vec4<f32>,
        \\  @location(6) inst_m2: vec4<f32>,
        \\  @location(7) inst_m3: vec4<f32>,
        \\  @location(8) inst_color: vec4<f32>,
        \\) -> VSOut {
        \\  var out: VSOut;
        \\  let model = mat4x4<f32>(inst_m0, inst_m1, inst_m2, inst_m3);
        \\  let world_pos4 = model * vec4<f32>(a_pos, 1.0);
        \\  out.world_pos = world_pos4.xyz;
        \\  out.normal = normalize(mat3x3<f32>(model[0].xyz, model[1].xyz, model[2].xyz) * a_normal);
        \\  out.uv = a_uv;
        \\  out.inst_color = inst_color;
        \\  out.pos = u.vp * world_pos4;
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
        \\// ── LTC (Linearly Transformed Cosines) rect area lights ──
        \\// WGSL twin of the GLSL ltcEvaluate. Free fns: N/V/P are PARAMS (no in.* refs).
        \\// Transcribed from three.js r160; normalization is the form factor itself (no extra /PI).
        \\fn ltcEdgeVectorFormFactor(v1: vec3<f32>, v2: vec3<f32>) -> vec3<f32> {
        \\  let x = dot(v1, v2);
        \\  let y = abs(x);
        \\  let a = 0.8543985 + (0.4965155 + 0.0145206 * y) * y;
        \\  let b = 3.4175940 + (4.1616724 + y) * y;
        \\  let v = a / b;
        \\  var theta_sintheta: f32;
        \\  if (x > 0.0) { theta_sintheta = v; } else { theta_sintheta = 0.5 * inverseSqrt(max(1.0 - x * x, 1e-7)) - v; }
        \\  return cross(v1, v2) * theta_sintheta;
        \\}
        \\fn ltcClippedSphereFormFactor(f: vec3<f32>) -> f32 {
        \\  let l = length(f);
        \\  return max((l * l + f.z) / (l + 1.0), 0.0);
        \\}
        \\fn ltcEvaluate(N: vec3<f32>, V: vec3<f32>, P: vec3<f32>, mInv: mat3x3<f32>, c0: vec3<f32>, c1: vec3<f32>, c2: vec3<f32>, c3: vec3<f32>) -> vec3<f32> {
        \\  let v1 = c1 - c0;
        \\  let v2 = c3 - c0;
        \\  let lightNormal = cross(v1, v2);
        \\  if (dot(lightNormal, P - c0) < 0.0) { return vec3<f32>(0.0); }
        \\  let T1 = normalize(V - N * dot(V, N));
        \\  let T2 = -cross(N, T1);
        \\  let basis = mat3x3<f32>(T1, T2, N);
        \\  let m = mInv * transpose(basis);
        \\  let p0 = normalize(m * (c0 - P));
        \\  let p1 = normalize(m * (c1 - P));
        \\  let p2 = normalize(m * (c2 - P));
        \\  let p3 = normalize(m * (c3 - P));
        \\  var ff = vec3<f32>(0.0);
        \\  ff += ltcEdgeVectorFormFactor(p0, p1);
        \\  ff += ltcEdgeVectorFormFactor(p1, p2);
        \\  ff += ltcEdgeVectorFormFactor(p2, p3);
        \\  ff += ltcEdgeVectorFormFactor(p3, p0);
        \\  return vec3<f32>(ltcClippedSphereFormFactor(ff));
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
    const fs_open_ds =
        \\@fragment
        \\fn fs_main(in: VSOut, @builtin(front_facing) front_facing: bool) -> @location(0) vec4<f32> {
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
    const fs_alpha_test =
        \\  if (textureSample(base_tex, samp, in.uv).a * base_color.a < u.material[2].w) { discard; }
        \\
    ;
    // Instanced fs_open: base_color is tinted by the per-instance color varying.
    const fs_open_instanced =
        \\@fragment
        \\fn fs_main(in: VSOut) -> @location(0) vec4<f32> {
        \\  let base_color = u.material[0] * in.inst_color;
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
    const fs_normal_nm_ds =
        \\  var n_ts = textureSample(normal_tex, samp, in.uv).xyz * 2.0 - 1.0;
        \\  n_ts = vec3<f32>(n_ts.xy * normal_scale, n_ts.z);
        \\  let TBN = mat3x3<f32>(normalize(in.tangent), normalize(in.bitangent), normalize(in.normal));
        \\  var N = normalize(TBN * n_ts);
        \\
    ;
    const fs_normal_plain =
        \\  let N = normalize(in.normal);
        \\
    ;
    const fs_normal_plain_ds =
        \\  var N = normalize(in.normal);
        \\
    ;
    const fs_ds_flip =
        \\  N = select(-N, N, front_facing);
        \\
    ;
    // Light loop, split so the shadow variants can inject a per-light shadow
    // attenuation of `radiance` BEFORE the BRDF accumulation. For non-shadow
    // variants, fs_lighting_head ++ fs_lighting_tail is byte-identical to the
    // original single fs_lighting string. Mirrors the GLSL split exactly.
    const fs_lighting_head =
        \\  let V = normalize(u.camera_pos - in.world_pos);
        \\  let NdotV = max(dot(N, V), 0.0);
        \\  let F0 = mix(vec3<f32>(0.04), albedo, metallic);
        \\  let k_direct = (roughness + 1.0) * (roughness + 1.0) / 8.0;
        \\  let alpha = roughness * roughness;
        \\  var Lo = vec3<f32>(0.0);
        \\  for (var i: i32 = 0; i < u.light_count; i = i + 1) {
        \\    let v0 = u.lights[4 * i];
        \\    let v1 = u.lights[4 * i + 1];
        \\    let v2 = u.lights[4 * i + 2];
        \\    let v3 = u.lights[4 * i + 3];
        \\    let ltype = v0.x;
        \\    let intensity = v0.y;
        \\    let lpos = vec3<f32>(v0.z, v0.w, v1.x);
        \\    let ldir = normalize(vec3<f32>(v1.y, v1.z, v1.w));
        \\    let lcolor = v2.xyz;
        \\    let lrange = v2.w;
        \\    let cosIn = v3.x;
        \\    let cosOut = v3.y;
        \\    var L: vec3<f32>;
        \\    var radiance: vec3<f32>;
        \\    if (ltype < 0.5) {
        \\      L = -ldir;
        \\      radiance = lcolor * intensity;
        \\    } else {
        \\      let Lvec = lpos - in.world_pos;
        \\      let dist = length(Lvec);
        \\      L = Lvec / max(dist, 1e-4);
        \\      var atten = 1.0 / max(dist * dist, 1e-4);
        \\      if (lrange > 0.0 && dist > lrange) { atten = 0.0; }
        \\      radiance = lcolor * intensity * atten;
        \\      if (ltype > 1.5) {
        \\        let cosA = dot(-L, ldir);
        \\        radiance = radiance * smoothstep(cosOut, cosIn, cosA);
        \\      }
        \\    }
        \\
    ;
    // Per-light shadow attenuation (WGSL twin of the GLSL lighting_shadow_* snippets).
    // Range-bounded guards stay mutually exclusive: sk>2.5 → CSM (3), sk>1.5 →
    // point (2), sk>0.5 → single 2D (1). Mirrors the GLSL order/math exactly.
    const fs_lighting_shadow_csm =
        \\    if (v3.w > 2.5) { radiance = radiance * csmFactor(in.world_pos, i32(v3.z + 0.5)); }
        \\
    ;
    const fs_lighting_shadow_2d =
        \\    if (v3.w > 0.5 && v3.w < 1.5) { radiance = radiance * shadowFactor2D(in.world_pos, i32(v3.z + 0.5)); }
        \\
    ;
    const fs_lighting_shadow_point =
        \\    if (v3.w > 1.5 && v3.w < 2.5) { radiance = radiance * pointShadowFactor(in.world_pos, lpos, lrange, i32(v3.z + 0.5)); }
        \\
    ;
    const fs_lighting_tail =
        \\    let H = normalize(V + L);
        \\    let NdotL = max(dot(N, L), 0.0);
        \\    let D = distributionGGX(N, H, alpha);
        \\    let G = geometrySmith(N, V, L, k_direct);
        \\    let F = fresnelSchlick(max(dot(H, V), 0.0), F0);
        \\    let spec = (D * G * F) / max(4.0 * NdotV * NdotL, 0.0001);
        \\    let kD = (vec3<f32>(1.0) - F) * (1.0 - metallic);
        \\    Lo = Lo + (kD * albedo / PI + spec) * radiance * NdotL;
        \\  }
        \\
    ;
    // Rect area lights (LTC), WGSL twin of area_lighting_*. ALWAYS emitted; world_pos
    // threaded as in.world_pos into the free ltcEvaluate helper. Shadow line emitted
    // only under variant_shadow (shadowFactor2D lives in fs_shadow_decl).
    const fs_area_lighting_head =
        \\  for (var ai: i32 = 0; ai < u.area_count; ai = ai + 1) {
        \\    let a0 = u.area_lights[4 * ai];
        \\    let a1 = u.area_lights[4 * ai + 1];
        \\    let a2 = u.area_lights[4 * ai + 2];
        \\    let a3 = u.area_lights[4 * ai + 3];
        \\    let a_pos = a0.xyz;
        \\    let a_intensity = a0.w;
        \\    let ex = a1.xyz;
        \\    let ey = a2.xyz;
        \\    let a_color = a3.xyz;
        \\    let c0 = a_pos + ex - ey;
        \\    let c1 = a_pos - ex - ey;
        \\    let c2 = a_pos - ex + ey;
        \\    let c3 = a_pos + ex + ey;
        \\    let ltc_uv = vec2<f32>(roughness, sqrt(1.0 - NdotV)) * (63.0 / 64.0) + 0.5 / 64.0;
        \\    let t1 = textureSampleLevel(ltc_mat, samp, ltc_uv, 0.0);
        \\    let t2 = textureSampleLevel(ltc_mag, samp, ltc_uv, 0.0);
        \\    let Minv = mat3x3<f32>(vec3<f32>(t1.x, 0.0, t1.y), vec3<f32>(0.0, 1.0, 0.0), vec3<f32>(t1.z, 0.0, t1.w));
        \\    let a_fresnel = F0 * t2.x + (vec3<f32>(1.0) - F0) * t2.y;
        \\    let a_diffuse = ltcEvaluate(N, V, in.world_pos, mat3x3<f32>(1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0), c0, c1, c2, c3);
        \\    let a_spec = a_fresnel * ltcEvaluate(N, V, in.world_pos, Minv, c0, c1, c2, c3);
        \\    let area_radiance = a_color * a_intensity;
        \\    var area_contrib = area_radiance * (albedo * a_diffuse + a_spec);
        \\
    ;
    const fs_area_lighting_shadow_2d =
        \\    if (a3.w > 0.5) { area_contrib = area_contrib * shadowFactor2D(in.world_pos, i32(a2.w + 0.5)); }
        \\
    ;
    const fs_area_lighting_tail =
        \\    Lo = Lo + area_contrib;
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
    // Per-caster 3×3 PCF over the depth-compare sampler into the 4096² 2D atlas.
    // Light-space position is recomputed per caster from u.shadow_vp[slot]·world_pos.
    // The chunk supplies a shadow_vp that already remaps clip z to WebGPU's [0,1]
    // range (Zfix·ortho·view), so the depth ref is ndc.z directly; uv flips Y for
    // WebGPU texture space. PCF samples are confined to the caster's 1024² tile
    // (row 0, col = slot). Atlas geometry mirrors the GLSL shadowFactor2D exactly.
    const fs_shadow_decl =
        \\fn shadowFactor2D(world_pos: vec3<f32>, slot: i32) -> f32 {
        \\  let lp = u.shadow_vp[slot] * vec4<f32>(world_pos, 1.0);
        \\  let ndc = lp.xyz / lp.w;
        \\  if (ndc.z > 1.0) { return 1.0; }
        \\  let uv = vec2<f32>(ndc.x * 0.5 + 0.5, ndc.y * -0.5 + 0.5);
        \\  let bias = 0.0015;
        \\  let tileScale = 1024.0 / 4096.0;
        \\  let tile = vec2<f32>(f32(slot % 4), f32(slot / 4));
        \\  let texel = 1.0 / 4096.0;
        \\  let pclamp = clamp(uv, vec2<f32>(0.0), vec2<f32>(1.0));
        \\  var sum = 0.0;
        \\  for (var y = -1; y <= 1; y = y + 1) {
        \\    for (var x = -1; x <= 1; x = x + 1) {
        \\      let t = clamp(pclamp + vec2<f32>(f32(x), f32(y)) * texel, vec2<f32>(0.0), vec2<f32>(1.0));
        \\      let atlasUv = (tile + t) * tileScale;
        \\      sum = sum + textureSampleCompareLevel(shadow_map, shadow_samp, atlasUv, ndc.z - bias);
        \\    }
        \\  }
        \\  return sum / 9.0;
        \\}
        \\// CSM: select a cascade by view-space depth (viewZ = dot(world-camera, fwd)),
        \\// sample shadow_vp[base+ci], blend into the next cascade near the boundary.
        \\// Free fn: world_pos is a PARAM; u.* is module-scope (OK), no in.* refs.
        \\fn csmFactor(world_pos: vec3<f32>, base: i32) -> f32 {
        \\  let viewZ = dot(world_pos - u.camera_pos, u.view_forward);
        \\  var ci = u.cascade_count - 1;
        \\  for (var i = 0; i < 4; i = i + 1) {
        \\    if (i >= u.cascade_count) { break; }
        \\    if (viewZ <= u.cascade_splits[i]) { ci = i; break; }
        \\  }
        \\  var f = shadowFactor2D(world_pos, base + ci);
        \\  if (ci < u.cascade_count - 1) {
        \\    var prev = 0.0;
        \\    if (ci > 0) { prev = u.cascade_splits[ci - 1]; }
        \\    let far = u.cascade_splits[ci];
        \\    let band = 0.1 * (far - prev);
        \\    if (band > 0.0001 && viewZ > far - band) {
        \\      let t = clamp((viewZ - (far - band)) / band, 0.0, 1.0);
        \\      f = mix(f, shadowFactor2D(world_pos, base + ci + 1), t);
        \\    }
        \\  }
        \\  return f;
        \\}
        \\
    ;
    const fs_combine_plain =
        \\  var color = ambient + Lo;
        \\
    ;
    // Point-shadow receiver (variant_shadow_point): WGSL twin of the GLSL
    // pointShadowFactor(). unpackDist + dominant-axis cubemap face select +
    // 3×3 PCF over the RGBA8 atlas. Face signs are BYTE-IDENTICAL to the GLSL:
    //   face 0 (+X): (-v.z,-v.y)  face 1 (-X): (v.z,-v.y)
    //   face 2 (+Y): (v.x, v.z)  face 3 (-Y): (v.x,-v.z)
    //   face 4 (+Z): (v.x,-v.y)  face 5 (-Z): (-v.x,-v.y)
    // Atlas: 1536×4096, 3 cols × 8 rows of 512² tiles. Caster `pidx` occupies rows
    // [pidx*2, pidx*2+1]; tile = (f%3, pidx*2 + f/3). lpos/far come from the loop.
    // Bias: 0.01. In-tile margin clamp: [0.0008, 0.9992] (tile-local).
    const fs_point_shadow_decl =
        \\fn unpackDist(c: vec4f) -> f32 { return dot(c, vec4f(1.0,1.0/255.0,1.0/65025.0,1.0/16581375.0)); }
        \\fn pointShadowFactor(world_pos: vec3<f32>, lpos: vec3<f32>, far: f32, pidx: i32) -> f32 {
        \\  let v = world_pos - lpos;
        \\  let cur = length(v) / far;
        \\  let a = abs(v);
        \\  var ma: f32; var face: i32; var uvc: vec2<f32>;
        \\  if (a.x >= a.y && a.x >= a.z) {
        \\    ma = a.x;
        \\    if (v.x > 0.0) { face = 0; uvc = vec2<f32>(-v.z, -v.y); }
        \\    else           { face = 1; uvc = vec2<f32>( v.z, -v.y); }
        \\  } else if (a.y >= a.z) {
        \\    ma = a.y;
        \\    if (v.y > 0.0) { face = 2; uvc = vec2<f32>( v.x,  v.z); }
        \\    else           { face = 3; uvc = vec2<f32>( v.x, -v.z); }
        \\  } else {
        \\    ma = a.z;
        \\    if (v.z > 0.0) { face = 4; uvc = vec2<f32>( v.x, -v.y); }
        \\    else           { face = 5; uvc = vec2<f32>(-v.x, -v.y); }
        \\  }
        \\  let uv = 0.5 * (uvc / ma + vec2<f32>(1.0));
        \\  let col = face % 3;
        \\  let row = pidx * 2 + face / 3;
        \\  let tile = vec2<f32>(f32(col), f32(row));
        \\  let bias: f32 = 0.01;
        \\  let texel = vec2<f32>(1.0 / 1536.0, 1.0 / 4096.0);
        \\  var lit: f32 = 0.0;
        \\  for (var dy: i32 = -1; dy <= 1; dy = dy + 1) {
        \\    for (var dx: i32 = -1; dx <= 1; dx = dx + 1) {
        \\      let fuv = clamp(uv + vec2<f32>(f32(dx), f32(dy)) * vec2<f32>(1.0/512.0), vec2<f32>(0.0008), vec2<f32>(0.9992));
        \\      let atlasUv = (tile + fuv) * vec2<f32>(1.0/3.0, 1.0/8.0);
        \\      let stored = unpackDist(textureSampleLevel(point_atlas, samp, atlasUv, 0.0));
        \\      lit = lit + select(0.0, 1.0, cur <= stored + bias);
        \\    }
        \\  }
        \\  return lit / 9.0;
        \\}
        \\
    ;
    const fs_emissive =
        \\  color = color + emissive_factor * textureSample(emissive_tex, samp, in.uv).rgb;
        \\
    ;
    // Fog mix (variant_fog). Applied after emissive, before tonemap.
    const fs_fog_mix =
        \\  let fog_dist = length(u.camera_pos - in.world_pos);
        \\  var fog_factor = 1.0;
        \\  if (fog.a.x > 0.5) {
        \\    if (fog.a.x < 1.5) {
        \\      fog_factor = (fog.b.y - fog_dist) / max(fog.b.y - fog.b.x, 1e-4);
        \\    } else if (fog.a.x < 2.5) {
        \\      fog_factor = exp(-fog.b.z * fog_dist);
        \\    } else {
        \\      let fd = fog.b.z * fog_dist;
        \\      fog_factor = exp(-fd * fd);
        \\    }
        \\    color = mix(fog.a.yzw, color, clamp(fog_factor, 0.0, 1.0));
        \\  }
        \\
    ;
    // ACES tonemap + gamma. Skipped for variant_linear_output (the post
    // pipeline renders linear HDR offscreen and tonemaps in the composite pass).
    const fs_tail_tonemap =
        \\  color = clamp((color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14), vec3<f32>(0.0), vec3<f32>(1.0));
        \\  color = pow(color, vec3<f32>(1.0 / 2.2));
        \\
    ;
    const fs_tail_close =
        \\  return vec4<f32>(color, base_color.a);
        \\}
        \\
    ;

    const nm = flags & variant_normal_map != 0;
    const em = flags & variant_emissive != 0;
    const shadow = flags & variant_shadow != 0;
    const point_shadow = flags & variant_shadow_point != 0;
    const skinned = flags & variant_skinned != 0;
    const morphed = flags & variant_morph != 0;
    const lin = flags & variant_linear_output != 0;
    const ds = flags & variant_double_sided != 0;
    const inst = flags & variant_instanced != 0;
    if (morphed and skinned) @compileError("variant_morph + variant_skinned not supported this slice");
    comptime var src: []const u8 = uniforms_head;
    if (shadow) src = src ++ uniforms_shadow;
    if (inst) src = src ++ uniforms_vp;
    src = src ++ uniforms_tail;
    if (skinned) src = src ++ uniforms_bones;
    if (flags & variant_fog != 0) src = src ++ uniforms_fog;
    if (morphed) src = src ++ uniforms_morph;
    src = src ++ samp ++ tex_base;
    if (nm) src = src ++ tex_normal;
    if (em) src = src ++ tex_emissive;
    src = src ++ tex_ibl;
    if (shadow) src = src ++ tex_shadow;
    if (point_shadow) src = src ++ tex_point_shadow;
    src = src ++ tex_ltc;
    src = src ++ vsout_head;
    if (nm) src = src ++ vsout_nm;
    if (inst) src = src ++ vsout_inst_color;
    src = src ++ vsout_tail;
    if (inst) {
        src = src ++ vs_head_instanced;
    } else if (morphed and !skinned) {
        src = src ++ vs_head_morph;
        if (nm) src = src ++ vs_nm;
        src = src ++ vs_tail_morph;
    } else {
        src = src ++ (if (skinned) vs_head_skinned else vs_head);
        if (nm) src = src ++ (if (skinned) vs_nm_skinned else vs_nm);
        src = src ++ (if (skinned) vs_tail_skinned else vs_tail);
    }
    src = src ++ helpers;
    if (shadow) src = src ++ fs_shadow_decl;
    if (point_shadow) src = src ++ fs_point_shadow_decl;
    src = src ++ (if (inst) fs_open_instanced else (if (ds) fs_open_ds else fs_open));
    if (flags & variant_alpha_test != 0) src = src ++ fs_alpha_test;
    src = src ++ (if (nm) (if (ds) fs_normal_nm_ds else fs_normal_nm) else (if (ds) fs_normal_plain_ds else fs_normal_plain));
    if (ds) src = src ++ fs_ds_flip;
    src = src ++ fs_lighting_head;
    if (shadow) src = src ++ fs_lighting_shadow_csm;
    if (point_shadow) src = src ++ fs_lighting_shadow_point;
    if (shadow) src = src ++ fs_lighting_shadow_2d;
    src = src ++ fs_lighting_tail;
    src = src ++ fs_area_lighting_head;
    if (shadow) src = src ++ fs_area_lighting_shadow_2d;
    src = src ++ fs_area_lighting_tail;
    src = src ++ fs_combine_plain;
    if (em) src = src ++ fs_emissive;
    if (flags & variant_fog != 0) src = src ++ fs_fog_mix;
    if (!lin) src = src ++ fs_tail_tonemap;
    src = src ++ fs_tail_close;
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

/// Depth-alpha-test WGSL for the WebGPU shadow pass. Parallel to
/// depthAtVertexSrc/depthAtFragmentSrc (GLSL). Samples the base texture and
/// discards pixels below the alpha cutoff so cutout (MASK) shadows have holes.
pub fn wgslDepthAt() []const u8 {
    return
    \\struct U {
    \\  mvp: mat4x4<f32>,
    \\  material: array<vec4<f32>, 3>,
    \\};
    \\@group(0) @binding(0) var<uniform> u: U;
    \\@group(0) @binding(1) var base_tex: texture_2d<f32>;
    \\@group(0) @binding(2) var samp: sampler;
    \\struct VsOut {
    \\  @builtin(position) pos: vec4<f32>,
    \\  @location(0) uv: vec2<f32>,
    \\};
    \\@vertex
    \\fn vs_main(@location(0) a_pos: vec3<f32>, @location(1) a_uv: vec2<f32>) -> VsOut {
    \\  var out: VsOut;
    \\  out.uv = a_uv;
    \\  out.pos = u.mvp * vec4<f32>(a_pos, 1.0);
    \\  return out;
    \\}
    \\@fragment
    \\fn fs_main(in: VsOut) {
    \\  if (textureSample(base_tex, samp, in.uv).a * u.material[0].w < u.material[2].w) { discard; }
    \\}
    \\
    ;
}

/// Depth + view-space normal prepass WGSL (variant_prepass). Standalone shader
/// pair rendered once into the rgba16f G-buffer before the main PBR pass. Reads
/// pos (location 0) + normal (location 1) of the stride-48 PBR layout. Writes
/// rgb = viewNormal*0.5+0.5, a = -viewPos.z (linear view-space depth). Private
/// 128-byte UBO {mvp @0, mv @64} — does NOT touch PBR_U. mvp = proj·view·model;
/// mv = view·model (view-space position + normal transform).
pub fn wgslPrepass() []const u8 {
    return
    \\struct U {
    \\  mvp: mat4x4<f32>,
    \\  mv: mat4x4<f32>,
    \\};
    \\@group(0) @binding(0) var<uniform> u: U;
    \\struct VsOut {
    \\  @builtin(position) pos: vec4<f32>,
    \\  @location(0) view_normal: vec3<f32>,
    \\  @location(1) view_pos: vec3<f32>,
    \\};
    \\@vertex
    \\fn vs_main(@location(0) a_pos: vec3<f32>, @location(1) a_normal: vec3<f32>) -> VsOut {
    \\  var out: VsOut;
    \\  let mv3 = mat3x3<f32>(u.mv[0].xyz, u.mv[1].xyz, u.mv[2].xyz);
    \\  out.view_normal = mv3 * a_normal;
    \\  out.view_pos = (u.mv * vec4<f32>(a_pos, 1.0)).xyz;
    \\  out.pos = u.mvp * vec4<f32>(a_pos, 1.0);
    \\  return out;
    \\}
    \\@fragment
    \\fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    \\  let n = normalize(in.view_normal);
    \\  return vec4<f32>(n * 0.5 + 0.5, -in.view_pos.z);
    \\}
    \\
    ;
}

/// G-buffer debug fullscreen WGSL (variant_post). Samples the prepass G-buffer
/// at tex0 and selects a mode via P.params.x: 0 = view normals (rgb passthrough),
/// 1 = linearized depth grayscale (alpha / fixed range). The Params struct is
/// 80 bytes: params vec4 @0, inv_proj mat4 @16 (inv_proj is unused by the debug
/// viz but rides the widened post params buffer for downstream slices). Threads
/// `uv` as a fs_main parameter (WGSL free-fn restriction does not apply — no
/// helper references it).
pub fn wgslGbufferDebug() []const u8 {
    return
    \\struct VsOut { @builtin(position) pos: vec4<f32>, @location(0) uv: vec2<f32> };
    \\@vertex fn vs_main(@builtin(vertex_index) vi: u32) -> VsOut {
    \\  var o: VsOut;
    \\  let p = vec2<f32>(f32((vi << 1u) & 2u), f32(vi & 2u));
    \\  o.uv = p;
    \\  o.pos = vec4<f32>(p * 2.0 - 1.0, 0.0, 1.0);
    \\  return o;
    \\}
    \\struct Params { params: vec4<f32>, inv_proj: mat4x4<f32> };
    \\@group(0) @binding(0) var<uniform> P: Params;
    \\@group(1) @binding(0) var samp: sampler;
    \\@group(1) @binding(1) var tex0: texture_2d<f32>;
    \\@group(1) @binding(2) var tex1: texture_2d<f32>;
    \\@fragment fn fs_main(@location(0) uv: vec2<f32>) -> @location(0) vec4<f32> {
    \\  let g = textureSample(tex0, samp, uv);
    \\  if (P.params.x > 0.5) {
    \\    let d = clamp(g.a / 10.0, 0.0, 1.0);
    \\    return vec4<f32>(vec3<f32>(d), 1.0);
    \\  }
    \\  return vec4<f32>(g.rgb, 1.0);
    \\}
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
    \\// Params (16B, one vec4): intensity=bloom blend, tonemap=op index,
    \\// vig_intensity=vignette strength, vig_radius=vignette falloff start.
    \\struct Params { intensity: f32, tonemap: f32, vig_intensity: f32, vig_radius: f32 };
    \\@group(0) @binding(0) var<uniform> P: Params;
    \\@group(1) @binding(0) var samp: sampler;
    \\@group(1) @binding(1) var tex0: texture_2d<f32>;
    \\@group(1) @binding(2) var tex1: texture_2d<f32>;
    \\fn aces(x: vec3<f32>) -> vec3<f32> {
    \\  let a = 2.51; let b = 0.03; let c = 2.43; let d = 0.59; let e = 0.14;
    \\  return clamp((x*(a*x+b))/(x*(c*x+d)+e), vec3<f32>(0.0), vec3<f32>(1.0));
    \\}
    \\// Minimal AgX tone-mapper (Troy Sobotka / Filament).  This is the same
    \\// approximation that underlies three.js AgXToneMapping (r160+).
    \\// Steps: (1) linear sRGB → AgX log via input matrix; (2) log2-encode and
    \\// normalise over [-12.47393, 4.026069]; (3) 7th-order per-channel contrast
    \\// polynomial; (4) AgX output (inverse) matrix; (5) EOTF pow(·,2.2).
    \\// GLSL and WGSL twins share byte-identical matrices and coefficients.
    \\fn agxDefaultContrastApprox(x: vec3<f32>) -> vec3<f32> {
    \\  return -0.00232 + x * (0.1191 + x * (0.4298 + x * (-6.868 +
    \\    x * (31.96 + x * (-40.14 + x * 15.5)))));
    \\}
    \\fn agx(v_in: vec3<f32>) -> vec3<f32> {
    \\  // (1) input matrix: linear sRGB -> AgX log space
    \\  let agxMat = mat3x3<f32>(
    \\    vec3<f32>(0.842479062253094, 0.0423282422610123, 0.0423756549057051),
    \\    vec3<f32>(0.0784335999999992, 0.878468636469772, 0.0784336),
    \\    vec3<f32>(0.0792237451477643, 0.0791661274605434, 0.879142973793104));
    \\  let LOG2_MIN = vec3<f32>(-12.47393);
    \\  let LOG2_MAX = vec3<f32>(4.026069);
    \\  var v = agxMat * v_in;
    \\  // (2) log2-encode + normalise to [0,1]
    \\  v = clamp(log2(max(v, vec3<f32>(1e-10))), LOG2_MIN, LOG2_MAX);
    \\  v = (v - LOG2_MIN) / (LOG2_MAX - LOG2_MIN);
    \\  // (3) per-channel contrast polynomial
    \\  v = agxDefaultContrastApprox(clamp(v, vec3<f32>(0.0), vec3<f32>(1.0)));
    \\  // (4) output matrix: AgX log space -> linear sRGB
    \\  let agxMatInv = mat3x3<f32>(
    \\    vec3<f32>(1.19687900512017, -0.0528968517574562, -0.0529716355144438),
    \\    vec3<f32>(-0.0980208811401368, 1.15190312990417, -0.0980434501171241),
    \\    vec3<f32>(-0.0990297440797205, -0.099043597298276, 1.15107367264116));
    \\  v = agxMatInv * v;
    \\  // (5) EOTF: AgX output gamma
    \\  return pow(clamp(v, vec3<f32>(0.0), vec3<f32>(1.0)), vec3<f32>(2.2));
    \\}
    \\fn hable(x: vec3<f32>) -> vec3<f32> {
    \\  let A = 0.15; let B = 0.50; let C = 0.10; let D = 0.20; let E = 0.02; let F = 0.30;
    \\  return ((x*(A*x+C*B)+D*E)/(x*(A*x+B)+D*F))-E/F;
    \\}
    \\@fragment fn fs_main(@location(0) uv: vec2<f32>) -> @location(0) vec4<f32> {
    \\  let hdr = textureSample(tex0, samp, uv).rgb + P.intensity * textureSample(tex1, samp, uv).rgb;
    \\  let op = i32(P.tonemap + 0.5);
    \\  var rgb: vec3<f32>;
    \\  if (op == 0) {
    \\    rgb = pow(clamp(hdr, vec3<f32>(0.0), vec3<f32>(1.0)), vec3<f32>(1.0/2.2));
    \\  } else if (op == 1) {
    \\    let x = hdr / (vec3<f32>(1.0) + hdr);
    \\    rgb = pow(x, vec3<f32>(1.0/2.2));
    \\  } else if (op == 2) {
    \\    let W = 4.0;
    \\    let x = hdr * (vec3<f32>(1.0) + hdr/(W*W)) / (vec3<f32>(1.0) + hdr);
    \\    rgb = pow(x, vec3<f32>(1.0/2.2));
    \\  } else if (op == 3) {
    \\    rgb = aces(hdr);
    \\  } else if (op == 4) {
    \\    rgb = agx(hdr);
    \\  } else {
    \\    let W = 11.2;
    \\    let x = hable(hdr * 2.0) / hable(vec3<f32>(W));
    \\    rgb = pow(x, vec3<f32>(1.0/2.2));
    \\  }
    \\  let d = length(uv - vec2<f32>(0.5));
    \\  let v = smoothstep(P.vig_radius, P.vig_radius - 0.45, d);
    \\  rgb = rgb * mix(1.0, v, P.vig_intensity);
    \\  return vec4<f32>(rgb, 1.0);
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

/// Tone-mapping operator applied in the composite stage (image-quality slice 2).
/// These integer values are the wire contract with the composite shader
/// (`let op = i32(P.tonemap + 0.5)` selects the branch).
pub const ToneMap = enum(u8) {
    /// Linear/None: `pow(clamp(hdr,0,1), 1/2.2)` — clips high values to white.
    linear = 0,
    /// Reinhard: `x = hdr/(1+hdr)`, then gamma 2.2.
    reinhard = 1,
    /// Reinhard-extended: `x = hdr*(1+hdr/(W*W))/(1+hdr)`, W=4, then gamma 2.2.
    reinhard_ext = 2,
    /// ACES (default): Hill fit (a=2.51,b=0.03,c=2.43,d=0.59,e=0.14), NO gamma.
    /// This is byte-identical to the pre-slice-2 composite output.
    aces = 3,
    /// AgX: minimal AgX approximation (Sobotka/Filament).  Input matrix → log2 encode
    /// over [-12.47393, 4.026069] → 7th-order contrast polynomial → output matrix →
    /// pow(·,2.2) EOTF.  This is the basis for three.js `AgXToneMapping` (r160+).
    agx = 4,
    /// Uncharted2/Hable filmic: Hable curve, exposure-bias 2, white-scale W=11.2, gamma 2.2.
    uncharted2 = 5,
};

/// Optional vignette applied after tone-mapping in the composite shader.
pub const Vignette = struct {
    /// 0 = off, 1 = full effect.
    intensity: f32 = 0.0,
    /// Distance from center at which vignette starts; typical 0.5–0.8.
    radius: f32 = 0.75,
};

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
    /// Tone-mapping operator applied in the composite stage.
    /// Default `.aces` reproduces pre-slice-2 output byte-for-byte.
    tonemap: ToneMap = .aces,
    /// Optional vignette applied after tone-mapping.
    /// `null` = off (vig_intensity=0 in the shader, no effect).
    vignette: ?Vignette = null,
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
    p_comp: [4]f32 = .{ 0, 0, 0, 0 }, // [intensity, tonemap, vig_intensity, vig_radius]
    p_fxaa: [4]f32 = .{ 0, 0, 0, 0 }, // [texel.x, texel.y, 0, 0]
};

/// Persistent state for the depth + view-space normal prepass (image-quality
/// slice 1). Parallels `PostCtx`: fixed handles + a created/last_w/last_h guard.
/// Handle reservation: 248–250 (251 spare) — after PostCtx's 240–247, before app
/// handles. `h_gbuffer` (248) is the documented public consumption handle that
/// downstream slices (SSAO/SSR/DOF) sample. The G-buffer is rgba16f WITH depth
/// (rt_flag_with_depth) so the prepass can depth-test and future slices can bind
/// hardware depth.
pub const PrepassCtx = struct {
    pub const h_gbuffer: u32 = 248; // rgba16f color RT (+depth) — public G-buffer handle
    pub const sh_prepass: u32 = 249; // variant_prepass shader (mvp+mv UBO)
    pub const sh_gdebug: u32 = 250; // variant_post G-buffer debug-viz shader
    // 251 spare.

    /// True once the shaders + target have been emitted for the first time.
    created: bool = false,
    last_w: u32 = 0,
    last_h: u32 = 0,
    webgpu: bool = false,
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

    /// Encode set_csm: frame-global cascaded-shadow params for the directional caster.
    /// splits_ptr -> 4 f32 cascade_splits (view-space far per cascade); view_forward_ptr
    /// -> 3 f32 normalized camera look dir. Per-frame transient like setLights (not recorded).
    pub fn setCsm(self: *Encoder, cascade_count: u32, splits_ptr: u32, view_forward_ptr: u32) void {
        self.header(.set_csm, 12);
        self.putU32(cascade_count);
        self.putU32(splits_ptr);
        self.putU32(view_forward_ptr);
    }

    /// Encode a set_fog command: ptr -> 8 f32 FogParams [mode, r,g,b, near, far, density, _pad].
    pub fn setFog(self: *Encoder, ptr: u32) void {
        self.header(.set_fog, 4);
        self.putU32(ptr);
    }

    /// Encode set_morph_weights: the active morph influence set (≤ morph_max_active).
    /// idx_ptr -> count u32 target indices; wt_ptr -> count f32 weights.
    pub fn setMorphWeights(self: *Encoder, count: u32, idx_ptr: u32, wt_ptr: u32) void {
        self.header(.set_morph_weights, 12);
        self.putU32(count);
        self.putU32(idx_ptr);
        self.putU32(wt_ptr);
    }

    /// Encode create_morph_tex: build the morph data texture from f16 POSITION+NORMAL
    /// deltas. ptr -> byte_len bytes of half-float delta payload (vmesh morph section).
    pub fn createMorphTex(self: *Encoder, handle: u32, width: u32, height: u32, ptr: u32, byte_len: u32) void {
        self.header(.create_morph_tex, 20);
        self.putU32(handle);
        self.putU32(width);
        self.putU32(height);
        self.putU32(ptr);
        self.putU32(byte_len);
    }

    pub fn setBones(self: *Encoder, count: u32, ptr: u32) void {
        self.header(.set_bones, 8);
        self.putU32(count);
        self.putU32(ptr);
    }

    /// Encode set_area_lights: per-frame rect-area-light array (≤ max_area_lights).
    /// `ptr` → count*16 f32 (4 vec4/area light; see max_area_lights packing). The
    /// bridge writes them into the active PBR program's U at area_count@504 /
    /// area_lights@512. Per-frame transient like setLights (not recorded into the registry).
    pub fn setAreaLights(self: *Encoder, count: u32, ptr: u32) void {
        self.header(.set_area_lights, 8);
        self.putU32(count);
        self.putU32(ptr);
    }

    /// Encode bind_ltc_lut: bind the two LTC LUT textures to tex_slot_ltc_mat(10) /
    /// tex_slot_ltc_mag(11). Mirrors bindIbl. The bridge binds dummy 1×1 LUTs when no
    /// area light. Must follow SET_PIPELINE (writes binds on the active program).
    pub fn bindLtcLut(self: *Encoder, ltc_mat_handle: u32, ltc_mag_handle: u32) void {
        self.header(.bind_ltc_lut, 8);
        self.putU32(ltc_mat_handle);
        self.putU32(ltc_mag_handle);
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

    /// Begin the depth pass into an atlas tile: bind the atlas FBO, set
    /// viewport + scissor to `(col*tile, row*tile, tile, tile)`, scissor-clear
    /// only that tile's depth channel, and bind the depth shader. Mirrors the
    /// `{col, row, tile}` convention of `beginPointShadowFace` (tag 32).
    /// `drawDepth` / `drawDepthAt` calls follow; `endShadowPass` closes.
    pub fn beginShadowPass(self: *Encoder, atlas_handle: u32, depth_shader: u32, col: u32, row: u32, tile: u32) void {
        self.header(.begin_shadow_pass, 20);
        self.putU32(atlas_handle);
        self.putU32(depth_shader);
        self.putU32(col);
        self.putU32(row);
        self.putU32(tile);
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

    /// Prepass geometry draw into the G-buffer (image-quality slice 1). Mirrors
    /// `drawDepth` plus a second mat4 pointer. `mvp_ptr` = proj·view·model (clip
    /// position); `mv_ptr` = view·model (view-space position + normal transform).
    pub fn drawPrepass(self: *Encoder, vbuf: u32, ibuf: u32, index_byte_off: u32, index_count: u32, mvp_ptr: u32, mv_ptr: u32) void {
        self.header(.draw_prepass, 24);
        self.putU32(vbuf);
        self.putU32(ibuf);
        self.putU32(index_byte_off);
        self.putU32(index_count);
        self.putU32(mvp_ptr);
        self.putU32(mv_ptr);
    }

    /// Alpha-tested depth draw (MASK cutout shadows): binds `shader` (the depth-at
    /// program), reads the base texture (bound via bind_texture slot 0) + `u_material`
    /// (from `material_ptr`), discards below the cutoff. `mvp_ptr` = light_vp·world.
    pub fn drawDepthAt(self: *Encoder, shader: u32, vbuf: u32, ibuf: u32, index_byte_off: u32, index_count: u32, mvp_ptr: u32, material_ptr: u32) void {
        self.header(.draw_depth_at, 28);
        self.putU32(shader);
        self.putU32(vbuf);
        self.putU32(ibuf);
        self.putU32(index_byte_off);
        self.putU32(index_count);
        self.putU32(mvp_ptr);
        self.putU32(material_ptr);
    }

    /// Instanced PBR draw: N copies of a mesh in one call. Per-instance model
    /// matrix columns (loc 4-7) + color (loc 8) come from `instance_ptr`;
    /// `vp_ptr` is the view-projection matrix (replaces per-draw u_mvp/u_model).
    pub fn drawPbrInstanced(self: *Encoder, vbuf: u32, ibuf: u32, index_byte_off: u32, index_count: u32, instance_ptr: u32, instance_count: u32, vp_ptr: u32, material_ptr: u32, camera_ptr: u32) void {
        self.header(.draw_pbr_instanced, 36);
        self.putU32(vbuf);
        self.putU32(ibuf);
        self.putU32(index_byte_off);
        self.putU32(index_count);
        self.putU32(instance_ptr);
        self.putU32(instance_count);
        self.putU32(vp_ptr);
        self.putU32(material_ptr);
        self.putU32(camera_ptr);
    }

    /// Bind the 2D shadow ATLAS to `slot` and upload `count` consecutive mat4 from
    /// `vp_ptr` into `u_shadow_vp[0..count]` (GLSL) / `shadow_vp[0..count]` (WGSL)
    /// on the active program. `count` is the number of 2D shadow casters this draw
    /// receives (0..max_2d_casters). Like setLights / bindIbl, must be re-emitted
    /// after each SET_PIPELINE since it writes uniforms on the active program.
    pub fn bindShadowMap(self: *Encoder, slot: u32, atlas_handle: u32, vp_ptr: u32, count: u32) void {
        self.header(.bind_shadow_map, 16);
        self.putU32(slot);
        self.putU32(atlas_handle);
        self.putU32(vp_ptr);
        self.putU32(count);
    }

    // ── Point-light (omnidirectional) shadow atlas ──────────────────────

    /// Allocate the RGBA8 shadow atlas texture (w×h) and a matching depth scratch.
    /// One per point light; recorded for context-restore replay.
    pub fn createPointShadow(self: *Encoder, handle: u32, w: u32, h: u32) void {
        self.header(.create_point_shadow, 12);
        self.putU32(handle);
        self.putU32(w);
        self.putU32(h);
    }

    /// Begin rendering into one cube face tile. `col`/`row` address the tile in
    /// the atlas; `tile` is the tile pixel size. `face_vp_ptr` → 16 f32 VP matrix
    /// (from `cubeFaceVp`); `light_pos_ptr` → 3 f32 world-space position;
    /// `far_bits` = `@as(u32, @bitCast(far))`.
    pub fn beginPointShadowFace(self: *Encoder, handle: u32, col: u32, row: u32, tile: u32, face_vp_ptr: u32, light_pos_ptr: u32, far_bits: u32) void {
        self.header(.begin_point_shadow_face, 28);
        self.putU32(handle);
        self.putU32(col);
        self.putU32(row);
        self.putU32(tile);
        self.putU32(face_vp_ptr);
        self.putU32(light_pos_ptr);
        self.putU32(far_bits);
    }

    /// Depth draw into the point-shadow atlas face. `model_ptr` → 16 f32 model matrix.
    pub fn drawPointDepth(self: *Encoder, vbuf: u32, ibuf: u32, index_byte_off: u32, index_count: u32, model_ptr: u32) void {
        self.header(.draw_point_depth, 20);
        self.putU32(vbuf);
        self.putU32(ibuf);
        self.putU32(index_byte_off);
        self.putU32(index_count);
        self.putU32(model_ptr);
    }

    /// End the point-shadow pass: restore default framebuffer + canvas viewport.
    pub fn endPointShadow(self: *Encoder, width: u32, height: u32) void {
        self.header(.end_point_shadow, 8);
        self.putU32(width);
        self.putU32(height);
    }

    /// Bind the point-shadow atlas to `slot`. Must follow SET_PIPELINE.
    /// Each caster's light position and far distance are read by the receiver
    /// shader from the per-light loop vars (lpos = v0.zw/v1.x, far = v2.w),
    /// so no per-caster uniform fields are needed here.
    pub fn bindPointShadow(self: *Encoder, slot: u32, handle: u32) void {
        self.header(.bind_point_shadow, 8);
        self.putU32(slot);
        self.putU32(handle);
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

        // Composite params: [intensity, tonemap_index, vig_intensity, vig_radius].
        // Written here so both the bloom and no-bloom paths carry all 4 fields.
        const vig = ctx.opts.vignette orelse Vignette{};
        ctx.p_comp[1] = @as(f32, @floatFromInt(@intFromEnum(ctx.opts.tonemap)));
        ctx.p_comp[2] = vig.intensity;
        ctx.p_comp[3] = vig.radius;

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
            // composite (scene_hdr + bloom_a) -> ldr offscreen; 4 params = all of p_comp.
            self.beginOffscreenPass(PostCtx.h_ldr, .{ 0, 0, 0, 1 }, clear_flag_color);
            self.drawFullscreenQuad(PostCtx.sh_composite, PostCtx.h_scene_hdr, PostCtx.h_bloom_a, @truncate(@intFromPtr(&ctx.p_comp)), 4);
            self.endOffscreenPass();
            // fxaa: ldr -> canvas
            ctx.p_fxaa = .{ fw, fh, 0, 0 };
            self.beginFrame(.{ 0, 0, 0, 1 }, w, h);
            self.drawFullscreenQuad(PostCtx.sh_fxaa, PostCtx.h_ldr, 0, @truncate(@intFromPtr(&ctx.p_fxaa)), 2);
            self.endFrame();
        } else {
            // composite straight to canvas; 4 params = all of p_comp.
            self.beginFrame(.{ 0, 0, 0, 1 }, w, h);
            self.drawFullscreenQuad(PostCtx.sh_composite, PostCtx.h_scene_hdr, PostCtx.h_bloom_a, @truncate(@intFromPtr(&ctx.p_comp)), 4);
            self.endFrame();
        }
    }

    // ── Image-quality slice 1: depth + view-space normal prepass API ──

    /// Open the G-buffer prepass for this frame.
    ///
    /// On first call (or on resize) emits `createRenderTarget` for `h_gbuffer`
    /// (rgba16f WITH depth) and (first call only) `createShader` × 2 (the prepass
    /// program + the G-buffer debug-viz program). Ends by opening an offscreen
    /// pass into `h_gbuffer` — the caller re-emits geometry via `drawPrepass`,
    /// then calls `endPrepass`. Mirrors `beginPostProcess`. `webgpu` selects WGSL
    /// vs GLSL exactly like `PostProcess.webgpu`.
    pub fn beginPrepass(self: *Encoder, ctx: *PrepassCtx, webgpu: bool, width: u32, height: u32) void {
        ctx.webgpu = webgpu;
        const resized = width != ctx.last_w or height != ctx.last_h;
        if (!ctx.created or resized) {
            if (resized and ctx.created) {
                self.deleteResource(.render_target, PrepassCtx.h_gbuffer);
            }
            self.createRenderTarget(PrepassCtx.h_gbuffer, width, height, .rgba16f, rt_flag_with_depth);
            ctx.last_w = width;
            ctx.last_h = height;
        }
        if (!ctx.created) {
            if (webgpu) {
                self.createShader(PrepassCtx.sh_prepass, variant_prepass, @truncate(@intFromPtr(wgslPrepass().ptr)), @intCast(wgslPrepass().len), 0, 0);
                self.createPostShaderWgsl(PrepassCtx.sh_gdebug, wgslGbufferDebug());
            } else {
                const vs = prepassVertexSrc();
                const fs = prepassFragmentSrc();
                self.createShader(PrepassCtx.sh_prepass, variant_prepass, @truncate(@intFromPtr(vs.ptr)), @intCast(vs.len), @truncate(@intFromPtr(fs.ptr)), @intCast(fs.len));
                self.createPostShaderGlsl(PrepassCtx.sh_gdebug, gbufferDebugFragmentSrc());
            }
            ctx.created = true;
        }
        // Open the G-buffer pass: clear color to (0,0,0,0) — normals=0 outside
        // geometry, depth alpha 0 (treated as far) — and clear depth. The caller
        // then `setPipeline(sh_prepass, depth_test|cull_back)` + `drawPrepass`,
        // mirroring the beginPostProcess → setPipeline → draw convention.
        self.beginOffscreenPass(PrepassCtx.h_gbuffer, .{ 0, 0, 0, 0 }, clear_flag_color | clear_flag_depth);
    }

    /// Close the G-buffer prepass pass. The next `begin_*` rebinds.
    pub fn endPrepass(self: *Encoder, ctx: *PrepassCtx) void {
        _ = ctx;
        self.endOffscreenPass();
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

test "GLSL lighting: 4-vec4 stride + spot/point falloff present" {
    // Verifies the S1 lighting contract: u_lights[16] (4 vec4/light × max 4 lights),
    // point/spot attenuation, and spot cone smoothstep in the emitted fragment source.
    const fs = pbrFragmentSrc(variant_pbr);
    // Wider uniform array
    try testing.expect(std.mem.indexOf(u8, fs, "u_lights[16]") != null);
    // 4-vec4 per-light reads
    try testing.expect(std.mem.indexOf(u8, fs, "u_lights[4 * i]") != null);
    try testing.expect(std.mem.indexOf(u8, fs, "u_lights[4 * i + 2]") != null);
    // Spot cone falloff
    try testing.expect(std.mem.indexOf(u8, fs, "smoothstep(cosOut, cosIn") != null);
    // Point attenuation (range cutoff guard)
    try testing.expect(std.mem.indexOf(u8, fs, "lrange > 0.0") != null);
    // Directional branch: L = -ldir, radiance = lcolor * intensity (unchanged semantics)
    try testing.expect(std.mem.indexOf(u8, fs, "L = -ldir") != null);
    try testing.expect(std.mem.indexOf(u8, fs, "radiance = lcolor * intensity;") != null);
}

test "WGSL lighting: 4-vec4 stride + spot/point falloff present" {
    // Verifies the T3 lighting contract: lights array<vec4,16> (4 vec4/light × max 4),
    // point/spot attenuation (range cutoff), and spot cone smoothstep in the WGSL src.
    const src = wgslPbr(variant_pbr);
    // Wider uniform array (16 vec4 = 4 lights × 4 vec4 each)
    try testing.expect(std.mem.indexOf(u8, src, "lights: array<vec4<f32>, 16>") != null);
    // 4-vec4 per-light reads
    try testing.expect(std.mem.indexOf(u8, src, "u.lights[4 * i]") != null);
    try testing.expect(std.mem.indexOf(u8, src, "u.lights[4 * i + 2]") != null);
    // Spot cone falloff
    try testing.expect(std.mem.indexOf(u8, src, "smoothstep(cosOut, cosIn, cosA)") != null);
    // Point attenuation (range cutoff guard)
    try testing.expect(std.mem.indexOf(u8, src, "lrange > 0.0") != null);
    // Directional branch: L = -ldir, radiance = lcolor * intensity
    try testing.expect(std.mem.indexOf(u8, src, "L = -ldir") != null);
    try testing.expect(std.mem.indexOf(u8, src, "radiance = lcolor * intensity") != null);
}

test "golden: PBR GLSL hashes frozen (FNV-1a-64)" {
    const F0 = variant_pbr;
    const F1 = variant_pbr | variant_normal_map;
    const F2 = variant_pbr | variant_normal_map | variant_emissive;
    // Frozen from first green run — a change here = deliberate GLSL contract bump.
    // Fragment hashes bumped in S1 (spot-shadows task 1): light stride 8→16 f32,
    // 4-vec4 loop, point/spot attenuation + spot cone smoothstep added.
    // VS hashes unchanged (lighting loop is fragment-only).
    // Re-frozen (Slice 3 LTC): area_count/u_area_lights uniforms + LTC samplers + LTC
    // helper fns + always-on rect-area-light eval loop added to EVERY PBR fragment.
    // VS hashes still unchanged (area lighting is fragment-only).
    try testing.expectEqual(@as(u64, 0x9fc619889b5412ca), fnv64(pbrVertexSrc(F0)));
    try testing.expectEqual(@as(u64, 0x197481afefd351c2), fnv64(pbrVertexSrc(F1)));
    try testing.expectEqual(@as(u64, 0x197481afefd351c2), fnv64(pbrVertexSrc(F2))); // emissive does not touch the VS
    try testing.expectEqual(@as(u64, 0x6cbcc5ac9026b7b2), fnv64(pbrFragmentSrc(F0)));
    try testing.expectEqual(@as(u64, 0x12afc4e9a79f341b), fnv64(pbrFragmentSrc(F1)));
    try testing.expectEqual(@as(u64, 0xdaeef6d1e356244e), fnv64(pbrFragmentSrc(F2)));
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
    // Bumped T3: lights 8→16 vec4, 4-vec4 loop, point/spot/spot-cone added.
    // Re-frozen (Slice 3 LTC): area fields in base U + LTC bindings/helpers/eval.
    try testing.expectEqual(@as(u64, 0xa65614f22334f9be), fnv64(wgslPbr(variant_pbr | variant_skinned)));
}

test "golden: WGSL PBR hashes frozen (FNV-1a-64)" {
    const F0 = variant_pbr;
    const F1 = variant_pbr | variant_normal_map;
    const F2 = variant_pbr | variant_normal_map | variant_emissive;
    // Frozen from first green run — a change here = deliberate WGSL contract bump.
    // Bumped T3: lights 8→16 vec4, 4-vec4 loop, point/spot/spot-cone added.
    // Re-frozen (Slice 3 LTC): area_count/area_lights in base U + tex_ltc bindings
    // (12/13) + LTC helper fns + always-on rect-area-light eval loop.
    try testing.expectEqual(@as(u64, 0x64869f3d4d29920e), fnv64(wgslPbr(F0)));
    try testing.expectEqual(@as(u64, 0x7861284caaa651af), fnv64(wgslPbr(F1)));
    try testing.expectEqual(@as(u64, 0x795f98fe53f113d5), fnv64(wgslPbr(F2)));
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
        try testing.expect(std.mem.indexOf(u8, src, "shadow_vp: array<mat4x4<f32>, 8>") != null);
        // S2 CSM: cascade fields appended to U + cascade-select receiver.
        try testing.expect(std.mem.indexOf(u8, src, "cascade_count: i32") != null);
        try testing.expect(std.mem.indexOf(u8, src, "cascade_splits: vec4<f32>") != null);
        try testing.expect(std.mem.indexOf(u8, src, "view_forward: vec3<f32>") != null);
        try testing.expect(std.mem.indexOf(u8, src, "fn csmFactor(world_pos: vec3<f32>, base: i32)") != null);
        try testing.expect(std.mem.indexOf(u8, src, "if (v3.w > 2.5) { radiance = radiance * csmFactor(in.world_pos, i32(v3.z + 0.5)); }") != null);
        // Per-caster sampling: shadow factor computed in-loop, no light_pos varying.
        try testing.expect(std.mem.indexOf(u8, src, "shadowFactor2D(in.world_pos, i32(v3.z + 0.5))") != null);
        try testing.expect(std.mem.indexOf(u8, src, "light_pos") == null);
    }
    // Non-shadow variants must NOT carry any shadow machinery.
    inline for ([_]u32{ variant_pbr, variant_pbr | variant_normal_map | variant_emissive }) |f| {
        const src = wgslPbr(f);
        try testing.expect(std.mem.indexOf(u8, src, "shadow_map") == null);
        try testing.expect(std.mem.indexOf(u8, src, "shadow_vp") == null);
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
    // Re-frozen (Slice 2 CSM): shadow_vp array<mat4x4,4>→<,8> (offset 512, 512B →
    // 512..1024); +cascade_count@1024/cascade_splits@1040/view_forward@1056 (struct
    // size 1072, PBR_STRIDE 768→1280); +csmFactor helper + reordered loop guards.
    // Re-frozen (Slice 3 LTC): base U gains area_count@504 + area_lights@512..768,
    // shadow_vp shifts 512→768, struct size 1072→1328, PBR_STRIDE 1280→1536;
    // +tex_ltc bindings (12/13) + LTC helpers + always-on area eval (area shadow line
    // emitted under variant_shadow). wgslDepth() unchanged (no lighting in depth shader).
    try testing.expectEqual(@as(u64, 0xcf13de40f43f4d50), fnv64(wgslPbr(S0)));
    try testing.expectEqual(@as(u64, 0xa282355908fba4c7), fnv64(wgslPbr(S1)));
    try testing.expectEqual(@as(u64, 0x71fee8885570c823), fnv64(wgslPbr(S2)));
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
    // Re-frozen (Slice 1 multi-caster): shadow no longer touches the VS, so the
    // shadow-variant VS hashes now EQUAL the non-shadow F0/F1 VS hashes (shadow
    // light-space pos is recomputed per caster in the fragment). The FS hashes move
    // because shadowFactor→shadowFactor2D + in-loop per-light shadow + u_shadow_vp[4].
    // Re-frozen (Slice 2 CSM): VS unchanged (shadow still not in VS); FS hashes move
    // (u_shadow_vp[4]→[8], +cascade uniforms, +csmFactor, reordered loop guards).
    // Re-frozen (Slice 3 LTC): VS still unchanged; FS hashes move (area uniforms +
    // LTC samplers/helpers + always-on area eval, with area-shadow line under shadow).
    try testing.expectEqual(@as(u64, 0x9fc619889b5412ca), fnv64(pbrVertexSrc(S0)));
    try testing.expectEqual(@as(u64, 0x197481afefd351c2), fnv64(pbrVertexSrc(S1)));
    try testing.expectEqual(@as(u64, 0x197481afefd351c2), fnv64(pbrVertexSrc(S2))); // emissive does not touch the VS
    try testing.expectEqual(@as(u64, 0xa12d2fac005271e2), fnv64(pbrFragmentSrc(S0)));
    try testing.expectEqual(@as(u64, 0xd9a325fca962b1f7), fnv64(pbrFragmentSrc(S1)));
    try testing.expectEqual(@as(u64, 0xedf44ca97aeed4d6), fnv64(pbrFragmentSrc(S2)));
    // Depth-only shadow-pass shader (unchanged — area lighting is PBR-only).
    try testing.expectEqual(@as(u64, 0x5bd62d643af5c2d5), fnv64(depthVertexSrc()));
    try testing.expectEqual(@as(u64, 0xe43018c9a1312d96), fnv64(depthFragmentSrc()));
}

test "shadow variant adds receiver uniforms; base variant has none" {
    const S0 = variant_pbr | variant_shadow;
    // The light-space VP array lives in the FRAGMENT shader now; the vertex stage
    // carries no shadow uniform (light pos recomputed per caster from v_world_pos).
    try testing.expect(std.mem.indexOf(u8, pbrFragmentSrc(S0), "u_shadow_map") != null);
    try testing.expect(std.mem.indexOf(u8, pbrFragmentSrc(S0), "uniform mat4 u_shadow_vp[8];") != null);
    // S2 CSM: cascade uniforms + cascade-select receiver in the shadow variant.
    try testing.expect(std.mem.indexOf(u8, pbrFragmentSrc(S0), "uniform int u_cascade_count;") != null);
    try testing.expect(std.mem.indexOf(u8, pbrFragmentSrc(S0), "uniform vec4 u_cascade_splits;") != null);
    try testing.expect(std.mem.indexOf(u8, pbrFragmentSrc(S0), "uniform vec3 u_view_forward;") != null);
    try testing.expect(std.mem.indexOf(u8, pbrFragmentSrc(S0), "float csmFactor(int base)") != null);
    try testing.expect(std.mem.indexOf(u8, pbrFragmentSrc(S0), "if (v3.w > 2.5) radiance *= csmFactor(int(v3.z + 0.5));") != null);
    try testing.expect(std.mem.indexOf(u8, pbrFragmentSrc(S0), "shadowFactor2D(int(v3.z + 0.5))") != null);
    // The shadow is folded into per-light radiance; the combine is plain.
    try testing.expect(std.mem.indexOf(u8, pbrFragmentSrc(S0), "vec3 color = ambient + Lo;") != null);
    try testing.expect(std.mem.indexOf(u8, pbrVertexSrc(S0), "u_shadow_vp") == null);
    try testing.expect(std.mem.indexOf(u8, pbrVertexSrc(S0), "v_light_pos") == null);
    // Base PBR variant carries none of it.
    try testing.expect(std.mem.indexOf(u8, pbrFragmentSrc(variant_pbr), "u_shadow_map") == null);
    try testing.expect(std.mem.indexOf(u8, pbrFragmentSrc(variant_pbr), "u_shadow_vp") == null);
}

test "golden: shadow-pass frame records (tags 16-20)" {
    // begin_shadow_pass grew 12→20 bytes (Task 1b: atlas_handle,depth_shader,col,row,tile).
    // bind_shadow_map stays 16 bytes (Task 1: slot,atlas_handle,vp_ptr,count).
    // Total record bytes: 12+24+24+12+20+4 = 96 = 0x60.
    var buf: [256]u8 = undefined;
    var enc = Encoder.init(&buf);
    enc.createShadowMap(8, 1024);
    enc.beginShadowPass(8, 4, 0, 0, 1024); // atlas=8, depth_shader=4, col=0, row=0, tile=1024
    enc.drawDepth(1, 2, 12, 36, 0x3000);
    enc.endShadowPass(300, 150);
    enc.bindShadowMap(tex_slot_shadow, 8, 0x3500, 2);
    enc.endFrame();
    const stream = enc.finish();
    const hex = try hexAlloc(testing.allocator, stream);
    defer testing.allocator.free(hex);
    try testing.expectEqualStrings(
        "60000000" ++ // length header: 96 record bytes (begin_shadow_pass grew 12→20)
            // CREATE_SHADOW_MAP handle=8 size=1024
            "1000" ++ "0800" ++ "08000000" ++ "00040000" ++
            // BEGIN_SHADOW_PASS atlas=8 depth_shader=4 col=0 row=0 tile=1024
            "1100" ++ "1400" ++ "08000000" ++ "04000000" ++ "00000000" ++ "00000000" ++ "00040000" ++
            // DRAW_DEPTH vbuf=1 ibuf=2 idx_off=12 count=36 mvp=0x3000
            "1300" ++ "1400" ++ "01000000" ++ "02000000" ++ "0c000000" ++ "24000000" ++ "00300000" ++
            // END_SHADOW_PASS width=300 height=150
            "1200" ++ "0800" ++ "2c010000" ++ "96000000" ++
            // BIND_SHADOW_MAP slot=8 atlas_handle=8 vp_ptr=0x3500 count=2
            "1400" ++ "1000" ++ "08000000" ++ "08000000" ++ "00350000" ++ "02000000" ++
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

test "variant_linear_output skips ACES in WGSL PBR fragment (backend parity)" {
    const lit = wgslPbr(variant_pbr);
    const linear = wgslPbr(variant_pbr | variant_linear_output);
    // WGSL twin must gate the in-shader tonemap identically to the GLSL path,
    // else the WebGPU scene double-tonemaps and nothing exceeds the bloom threshold.
    try testing.expect(std.mem.indexOf(u8, lit, "2.51") != null);
    try testing.expect(std.mem.indexOf(u8, linear, "2.51") == null); // ACES omitted in linear output
    try testing.expect(linear.len < lit.len); // linear omits the tonemap block
}

test "variant_alpha_test bit + GLSL discard appended only when set" {
    try testing.expectEqual(@as(u32, 1024), variant_alpha_test);
    const mask = pbrFragmentSrc(variant_pbr | variant_alpha_test);
    try testing.expect(std.mem.indexOf(u8, mask, "discard") != null);
    try testing.expect(std.mem.indexOf(u8, mask, "u_material[2].w") != null);
    const plain = pbrFragmentSrc(variant_pbr);
    try testing.expect(std.mem.indexOf(u8, plain, "discard") == null);
}

test "variant_alpha_test WGSL discard appended only when set" {
    const mask = wgslPbr(variant_pbr | variant_alpha_test);
    try testing.expect(std.mem.indexOf(u8, mask, "discard") != null);
    const plain = wgslPbr(variant_pbr);
    try testing.expect(std.mem.indexOf(u8, plain, "discard") == null);
}

test "fog WGSL: fog binding + mix; non-fog frozen" {
    const w = wgslPbr(variant_pbr | variant_fog);
    try testing.expect(std.mem.indexOf(u8, w, "@group(0) @binding(2) var<uniform> fog: Fog;") != null);
    try testing.expect(std.mem.indexOf(u8, w, "mix(fog.a.yzw, color") != null);
    try testing.expect(std.mem.indexOf(u8, w, "fog.a.x > 0.5") != null); // mode-0 no-op guard
    const plain = wgslPbr(variant_pbr);
    try testing.expect(std.mem.indexOf(u8, plain, "fog: Fog") == null);
}

test "golden: post shader sources frozen (FNV-1a-64)" {
    // Frozen from first green run — a change here = deliberate shader contract bump.
    // GLSL (composite intentionally changed in slice 2 — see slice-2 golden test below)
    try testing.expectEqual(@as(u64, 0xd8e25fe0c5f0c5c3), fnv64(fullscreenVertexSrc));
    try testing.expectEqual(@as(u64, 0xceff6b2f105a92ec), fnv64(brightFragmentSrc));
    try testing.expectEqual(@as(u64, 0x221d8b95dd9492ba), fnv64(blurFragmentSrc));
    try testing.expectEqual(@as(u64, 0x9d052976fb0b2105), fnv64(fxaaFragmentSrc));
    // WGSL (composite intentionally changed in slice 2 — see slice-2 golden test below)
    try testing.expectEqual(@as(u64, 0xefa46fcd8c5003b6), fnv64(wgslBright()));
    try testing.expectEqual(@as(u64, 0xb93270d3619361ca), fnv64(wgslBlur()));
    try testing.expectEqual(@as(u64, 0xe8ac45e2d1276dfd), fnv64(wgslFxaa()));
    // linear-output PBR variant (omits tonemap+gamma; post composite pass tonemaps instead)
    // wgslPbr(variant_linear_output) bumped T3: lights 8→16 vec4, 4-vec4 loop.
    // Re-frozen (Slice 3 LTC): area uniforms + LTC eval added to all PBR fragments.
    try testing.expectEqual(@as(u64, 0x54e229ed5e77c27a), fnv64(pbrFragmentSrc(variant_pbr | variant_linear_output)));
    try testing.expectEqual(@as(u64, 0x903208e333ab2def), fnv64(wgslPbr(variant_pbr | variant_linear_output)));
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

test "state_blend bit value" {
    try testing.expectEqual(@as(u32, 4), state_blend);
}

test "depthAt shaders: UV + discard + base/material; plain depth frozen" {
    const gv = depthAtVertexSrc();
    try testing.expect(std.mem.indexOf(u8, gv, "a_uv") != null);
    try testing.expect(std.mem.indexOf(u8, gv, "v_uv = a_uv") != null);
    const gf = depthAtFragmentSrc();
    try testing.expect(std.mem.indexOf(u8, gf, "discard") != null);
    try testing.expect(std.mem.indexOf(u8, gf, "u_base_tex") != null);
    try testing.expect(std.mem.indexOf(u8, gf, "u_material[2].w") != null);
    const w = wgslDepthAt();
    try testing.expect(std.mem.indexOf(u8, w, "discard") != null);
    try testing.expect(std.mem.indexOf(u8, w, "textureSample") != null);
    // plain depth fragment unchanged (no discard).
    try testing.expect(std.mem.indexOf(u8, depthFragmentSrc(), "discard") == null);
}

test "drawDepthAt encodes tag 26 + 7 u32 payload" {
    var buf: [64]u8 = undefined;
    var enc = Encoder.init(&buf);
    enc.drawDepthAt(10, 1, 2, 48, 36, 0x1000, 0x2000);
    // Buffer layout: [0..4) = reserved length header; record starts at 4.
    // [4..6) = tag u16, [6..8) = payload_size u16, [8..36) = 7×u32 payload.
    try testing.expectEqual(@as(u16, 26), std.mem.readInt(u16, buf[4..6], .little)); // tag
    try testing.expectEqual(@as(u16, 28), std.mem.readInt(u16, buf[6..8], .little)); // payload_size
    try testing.expectEqual(@as(u32, 10), std.mem.readInt(u32, buf[8..12], .little)); // shader
    try testing.expectEqual(@as(u32, 0x2000), std.mem.readInt(u32, buf[32..36], .little)); // material_ptr (7th u32)
}

test "drawPrepass encodes tag 39 + 6 u32 payload" {
    var buf: [64]u8 = undefined;
    var enc = Encoder.init(&buf);
    enc.drawPrepass(1, 2, 48, 36, 0x1000, 0x2000);
    // [4..6) tag, [6..8) payload_size, [8..32) 6×u32 payload.
    try testing.expectEqual(@as(u16, 39), std.mem.readInt(u16, buf[4..6], .little)); // tag
    try testing.expectEqual(@as(u16, 24), std.mem.readInt(u16, buf[6..8], .little)); // payload_size
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, buf[8..12], .little)); // vbuf
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, buf[12..16], .little)); // ibuf
    try testing.expectEqual(@as(u32, 48), std.mem.readInt(u32, buf[16..20], .little)); // index_byte_off
    try testing.expectEqual(@as(u32, 36), std.mem.readInt(u32, buf[20..24], .little)); // index_count
    try testing.expectEqual(@as(u32, 0x1000), std.mem.readInt(u32, buf[24..28], .little)); // mvp_ptr
    try testing.expectEqual(@as(u32, 0x2000), std.mem.readInt(u32, buf[28..32], .little)); // mv_ptr
}

test "variant_prepass bit value (1<<16) is free" {
    try testing.expectEqual(@as(u32, 1 << 16), variant_prepass);
    // No collision with any existing variant bit (0..15).
    try testing.expect(variant_prepass & variant_shadow_point == 0);
    try testing.expect(variant_prepass & variant_post == 0);
}

test "beginPrepass/endPrepass emit the G-buffer pass" {
    var buf: [4096]u8 = undefined;
    var enc = Encoder.init(&buf);
    var ctx = PrepassCtx{};
    enc.beginPrepass(&ctx, false, 800, 600);
    enc.setPipeline(PrepassCtx.sh_prepass, state_depth_test | state_cull_back);
    enc.drawPrepass(1, 2, 0, 36, 0x1000, 0x2000);
    enc.endPrepass(&ctx);
    const out = enc.finish();
    var tag_buf: [64]Tag = undefined;
    const n = collectTags(out, &tag_buf);
    // First frame: G-buffer RT created, prepass + gdebug shaders created, then the
    // offscreen pass opened, geometry drawn, pass closed.
    try expectContainsInOrder(tag_buf[0..n], n, &.{
        .create_render_target, // h_gbuffer
        .create_shader, // sh_prepass
        .create_shader, // sh_gdebug
        .begin_offscreen_pass, // -> h_gbuffer
        .set_pipeline,
        .draw_prepass,
        .end_offscreen_pass,
    });
}

test "PrepassCtx handles do not collide with PostCtx handles" {
    // 248–250 sit after PostCtx's 240–247; 251 is spare.
    try testing.expectEqual(@as(u32, 248), PrepassCtx.h_gbuffer);
    try testing.expectEqual(@as(u32, 249), PrepassCtx.sh_prepass);
    try testing.expectEqual(@as(u32, 250), PrepassCtx.sh_gdebug);
    try testing.expect(PrepassCtx.h_gbuffer > PostCtx.sh_fxaa);
}

test "prepass + gdebug shader content (both backends)" {
    // GLSL prepass: pos + normal in, view normal/pos out, mv+mvp uniforms, gbuffer out.
    const pv = prepassVertexSrc();
    try testing.expect(std.mem.indexOf(u8, pv, "a_normal") != null);
    try testing.expect(std.mem.indexOf(u8, pv, "u_mv") != null);
    try testing.expect(std.mem.indexOf(u8, pv, "u_mvp") != null);
    const pf = prepassFragmentSrc();
    try testing.expect(std.mem.indexOf(u8, pf, "n * 0.5 + 0.5") != null);
    try testing.expect(std.mem.indexOf(u8, pf, "-v_view_pos.z") != null);
    // WGSL prepass: private U {mvp, mv}, threads varyings as VsOut, NO PBR_U.
    const wp = wgslPrepass();
    try testing.expect(std.mem.indexOf(u8, wp, "mvp: mat4x4<f32>") != null);
    try testing.expect(std.mem.indexOf(u8, wp, "mv: mat4x4<f32>") != null);
    try testing.expect(std.mem.indexOf(u8, wp, "n * 0.5 + 0.5") != null);
    // gdebug: mode-select on params.x in both backends.
    const gf = gbufferDebugFragmentSrc();
    try testing.expect(std.mem.indexOf(u8, gf, "u_threshold > 0.5") != null);
    try testing.expect(std.mem.indexOf(u8, gf, "u_tex0") != null);
    const wg = wgslGbufferDebug();
    try testing.expect(std.mem.indexOf(u8, wg, "P.params.x > 0.5") != null);
    try testing.expect(std.mem.indexOf(u8, wg, "inv_proj: mat4x4<f32>") != null);
}

test "golden: prepass + gdebug shader sources frozen (FNV-1a-64)" {
    // Frozen from first green run — a change here = a deliberate shader bump.
    try testing.expectEqual(@as(u64, 0x91c87241e3a67f02), fnv64(prepassVertexSrc()));
    try testing.expectEqual(@as(u64, 0x177573915216ade5), fnv64(prepassFragmentSrc()));
    try testing.expectEqual(@as(u64, 0xfe0b7897c73027c0), fnv64(gbufferDebugFragmentSrc()));
    try testing.expectEqual(@as(u64, 0x30c9a8f934c49b91), fnv64(wgslPrepass()));
    try testing.expectEqual(@as(u64, 0x10e6f50be5ce2b92), fnv64(wgslGbufferDebug()));
}

test "variant_double_sided flips normal; non-DS frozen; state_cull_front" {
    try testing.expectEqual(@as(u32, 8), state_cull_front);
    const ds = pbrFragmentSrc(variant_pbr | variant_double_sided);
    try testing.expect(std.mem.indexOf(u8, ds, "gl_FrontFacing") != null);
    const plain = pbrFragmentSrc(variant_pbr);
    try testing.expect(std.mem.indexOf(u8, plain, "gl_FrontFacing") == null);
    const wds = wgslPbr(variant_pbr | variant_double_sided);
    try testing.expect(std.mem.indexOf(u8, wds, "front_facing") != null);
    const wplain = wgslPbr(variant_pbr);
    try testing.expect(std.mem.indexOf(u8, wplain, "front_facing") == null);
}

// ── Task 3 (instancing): variant_instanced + draw_pbr_instanced ──────

test "variant_instanced shader + draw_pbr_instanced tag; non-instanced frozen" {
    try testing.expectEqual(@as(u32, 1 << 12), variant_instanced);
    try testing.expectEqual(@as(u8, 27), @intFromEnum(Tag.draw_pbr_instanced));
    const ins = pbrVertexSrc(variant_pbr | variant_instanced);
    try testing.expect(std.mem.indexOf(u8, ins, "location = 4") != null); // instance mat4 attr
    const plain = pbrVertexSrc(variant_pbr);
    try testing.expect(std.mem.indexOf(u8, plain, "location = 4") == null); // non-instanced unchanged
    const wins = wgslPbr(variant_pbr | variant_instanced);
    try testing.expect(std.mem.indexOf(u8, wins, "@location(8)") != null); // instance color
}

test "variant_instanced GLSL: instance attribs + u_vp present; non-instanced absent" {
    const ins_vs = pbrVertexSrc(variant_pbr | variant_instanced);
    try testing.expect(std.mem.indexOf(u8, ins_vs, "a_inst_model0") != null);
    try testing.expect(std.mem.indexOf(u8, ins_vs, "a_inst_color") != null);
    try testing.expect(std.mem.indexOf(u8, ins_vs, "u_vp") != null);
    try testing.expect(std.mem.indexOf(u8, ins_vs, "v_inst_color") != null);
    const ins_fs = pbrFragmentSrc(variant_pbr | variant_instanced);
    try testing.expect(std.mem.indexOf(u8, ins_fs, "v_inst_color") != null);
    // Non-instanced GLSL must not leak any instancing declarations.
    const plain_vs = pbrVertexSrc(variant_pbr);
    try testing.expect(std.mem.indexOf(u8, plain_vs, "a_inst_model0") == null);
    try testing.expect(std.mem.indexOf(u8, plain_vs, "u_vp") == null);
    const plain_fs = pbrFragmentSrc(variant_pbr);
    try testing.expect(std.mem.indexOf(u8, plain_fs, "v_inst_color") == null);
}

test "variant_instanced WGSL: inst_color varying + u.vp present; non-instanced absent" {
    const wins = wgslPbr(variant_pbr | variant_instanced);
    try testing.expect(std.mem.indexOf(u8, wins, "inst_color") != null);
    try testing.expect(std.mem.indexOf(u8, wins, "u.vp") != null);
    try testing.expect(std.mem.indexOf(u8, wins, "@location(8)") != null);
    // Non-instanced WGSL must not carry instancing machinery.
    const wplain = wgslPbr(variant_pbr);
    try testing.expect(std.mem.indexOf(u8, wplain, "inst_color") == null);
    try testing.expect(std.mem.indexOf(u8, wplain, "u.vp") == null);
}

test "drawPbrInstanced encodes tag 27 + 9 u32 payload (36 bytes)" {
    var buf: [64]u8 = undefined;
    var enc = Encoder.init(&buf);
    enc.drawPbrInstanced(1, 2, 48, 36, 0x1000, 10, 0x2000, 0x3000, 0x4000);
    // record starts at offset 4 (after length header)
    try testing.expectEqual(@as(u16, 27), std.mem.readInt(u16, buf[4..6], .little)); // tag
    try testing.expectEqual(@as(u16, 36), std.mem.readInt(u16, buf[6..8], .little)); // payload_size
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, buf[8..12], .little)); // vbuf
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, buf[12..16], .little)); // ibuf
    try testing.expectEqual(@as(u32, 48), std.mem.readInt(u32, buf[16..20], .little)); // index_byte_off
    try testing.expectEqual(@as(u32, 36), std.mem.readInt(u32, buf[20..24], .little)); // index_count
    try testing.expectEqual(@as(u32, 0x1000), std.mem.readInt(u32, buf[24..28], .little)); // instance_ptr
    try testing.expectEqual(@as(u32, 10), std.mem.readInt(u32, buf[28..32], .little)); // instance_count
    try testing.expectEqual(@as(u32, 0x2000), std.mem.readInt(u32, buf[32..36], .little)); // vp_ptr
    try testing.expectEqual(@as(u32, 0x3000), std.mem.readInt(u32, buf[36..40], .little)); // material_ptr
    try testing.expectEqual(@as(u32, 0x4000), std.mem.readInt(u32, buf[40..44], .little)); // camera_ptr
}

test "fog: variant bit + set_fog tag + setFog encoding" {
    try testing.expectEqual(@as(u32, 1 << 13), variant_fog);
    try testing.expectEqual(@as(u8, 28), @intFromEnum(Tag.set_fog));
    try testing.expectEqual(@as(u32, 8), fog_params_f32);

    var buf: [64]u8 = undefined;
    var enc = Encoder.init(&buf);
    enc.setFog(0x4000);
    const stream = enc.finish();
    // length header (4) + record header (4) + ptr (4) = 12
    try testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, stream[0..4], .little));
    try testing.expectEqual(@as(u16, 28), std.mem.readInt(u16, stream[4..6], .little)); // tag
    try testing.expectEqual(@as(u16, 4), std.mem.readInt(u16, stream[6..8], .little)); // payload size
    try testing.expectEqual(@as(u32, 0x4000), std.mem.readInt(u32, stream[8..12], .little)); // ptr
}

test "morph: variant bit + tags + encoder payloads" {
    try testing.expectEqual(@as(u32, 1 << 14), variant_morph);
    try testing.expectEqual(@as(u8, 29), @intFromEnum(Tag.set_morph_weights));
    try testing.expectEqual(@as(u8, 30), @intFromEnum(Tag.create_morph_tex));
    try testing.expectEqual(@as(u32, 8), morph_max_active);

    var buf: [128]u8 = undefined;
    var enc = Encoder.init(&buf);
    enc.setMorphWeights(2, 0x1000, 0x2000);
    const s = enc.finish();
    // length header (4) + record header (tag u16 + size u16 = 4) + 3 u32 payload.
    try testing.expectEqual(@as(u16, 29), std.mem.readInt(u16, s[4..6], .little)); // tag
    try testing.expectEqual(@as(u16, 12), std.mem.readInt(u16, s[6..8], .little)); // payload size
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, s[8..12], .little));
    try testing.expectEqual(@as(u32, 0x1000), std.mem.readInt(u32, s[12..16], .little));
    try testing.expectEqual(@as(u32, 0x2000), std.mem.readInt(u32, s[16..20], .little));
}

test "fog GLSL: fog variant has u_fog uniforms + mix; non-fog frozen" {
    const f = pbrFragmentSrc(variant_pbr | variant_fog);
    try testing.expect(std.mem.indexOf(u8, f, "u_fog0") != null);
    try testing.expect(std.mem.indexOf(u8, f, "u_fog1") != null);
    try testing.expect(std.mem.indexOf(u8, f, "mix(u_fog0.yzw, color") != null);
    try testing.expect(std.mem.indexOf(u8, f, "u_fog0.x > 0.5") != null); // mode-0 no-op guard
    const plain = pbrFragmentSrc(variant_pbr);
    try testing.expect(std.mem.indexOf(u8, plain, "u_fog0") == null);
}

// ── Task 4 (morph): variant_morph GLSL vertex path ───────────────────────────

test "morph GLSL: variant emits morph uniforms + texelFetch loop; non-morph frozen" {
    const v = pbrVertexSrc(variant_pbr | variant_morph);
    try testing.expect(std.mem.indexOf(u8, v, "u_morph_tex") != null);
    try testing.expect(std.mem.indexOf(u8, v, "u_morph_count") != null);
    try testing.expect(std.mem.indexOf(u8, v, "texelFetch") != null);
    try testing.expect(std.mem.indexOf(u8, v, "u_morph_idx") != null);
    const plain = pbrVertexSrc(variant_pbr);
    try testing.expect(std.mem.indexOf(u8, plain, "u_morph_tex") == null);
}

// ── Task 5 (morph): variant_morph WGSL vertex path ───────────────────────────

test "morph WGSL: variant emits morph binding + textureLoad; non-morph frozen" {
    const w = wgslPbr(variant_pbr | variant_morph);
    try testing.expect(std.mem.indexOf(u8, w, "@group(0) @binding(4)") != null);
    try testing.expect(std.mem.indexOf(u8, w, "u_morph_tex") != null);
    try testing.expect(std.mem.indexOf(u8, w, "textureLoad") != null);
    try testing.expect(std.mem.indexOf(u8, w, "morph.count") != null);
    const plain = wgslPbr(variant_pbr);
    try testing.expect(std.mem.indexOf(u8, plain, "u_morph_tex") == null);
}

// ── Point-light shadow: variant + tags + encoder payloads ─────────────────────

test "point shadow: variant bit + tag values" {
    try testing.expectEqual(@as(u32, 1 << 15), variant_shadow_point);
    try testing.expectEqual(@as(u8, 31), @intFromEnum(Tag.create_point_shadow));
    try testing.expectEqual(@as(u8, 32), @intFromEnum(Tag.begin_point_shadow_face));
    try testing.expectEqual(@as(u8, 33), @intFromEnum(Tag.draw_point_depth));
    try testing.expectEqual(@as(u8, 34), @intFromEnum(Tag.end_point_shadow));
    try testing.expectEqual(@as(u8, 35), @intFromEnum(Tag.bind_point_shadow));
}

test "createPointShadow encodes tag 31 + 3 u32 payload (12 bytes)" {
    var buf: [64]u8 = undefined;
    var enc = Encoder.init(&buf);
    enc.createPointShadow(7, 1536, 1024);
    const s = enc.finish();
    // length header (4) + record header (4) + 3×u32 payload (12) = 16 record bytes
    try testing.expectEqual(@as(u32, 16), std.mem.readInt(u32, s[0..4], .little)); // length
    try testing.expectEqual(@as(u16, 31), std.mem.readInt(u16, s[4..6], .little)); // tag
    try testing.expectEqual(@as(u16, 12), std.mem.readInt(u16, s[6..8], .little)); // payload_size
    try testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, s[8..12], .little)); // handle
    try testing.expectEqual(@as(u32, 1536), std.mem.readInt(u32, s[12..16], .little)); // w
    try testing.expectEqual(@as(u32, 1024), std.mem.readInt(u32, s[16..20], .little)); // h
}

test "setCsm encodes tag 36 + 3 u32 payload (12 bytes)" {
    var buf: [64]u8 = undefined;
    var enc = Encoder.init(&buf);
    enc.setCsm(4, 0x1000, 0x2000);
    const s = enc.finish();
    // length header (4) + record header (4) + 3×u32 payload (12) = 16 record bytes
    try testing.expectEqual(@as(u32, 16), std.mem.readInt(u32, s[0..4], .little)); // length
    try testing.expectEqual(@as(u16, 36), std.mem.readInt(u16, s[4..6], .little)); // tag
    try testing.expectEqual(@as(u16, 12), std.mem.readInt(u16, s[6..8], .little)); // payload_size
    try testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, s[8..12], .little)); // cascade_count
    try testing.expectEqual(@as(u32, 0x1000), std.mem.readInt(u32, s[12..16], .little)); // splits_ptr
    try testing.expectEqual(@as(u32, 0x2000), std.mem.readInt(u32, s[16..20], .little)); // view_forward_ptr
}

test "beginPointShadowFace encodes tag 32 + 7 u32 payload (28 bytes)" {
    var buf: [64]u8 = undefined;
    var enc = Encoder.init(&buf);
    enc.beginPointShadowFace(7, 1, 0, 256, 0x1000, 0x2000, 0x3F800000); // far=1.0
    const s = enc.finish();
    try testing.expectEqual(@as(u16, 32), std.mem.readInt(u16, s[4..6], .little)); // tag
    try testing.expectEqual(@as(u16, 28), std.mem.readInt(u16, s[6..8], .little)); // payload_size
    try testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, s[8..12], .little)); // handle
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, s[12..16], .little)); // col
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, s[16..20], .little)); // row
    try testing.expectEqual(@as(u32, 256), std.mem.readInt(u32, s[20..24], .little)); // tile
    try testing.expectEqual(@as(u32, 0x1000), std.mem.readInt(u32, s[24..28], .little)); // face_vp_ptr
    try testing.expectEqual(@as(u32, 0x2000), std.mem.readInt(u32, s[28..32], .little)); // light_pos_ptr
    try testing.expectEqual(@as(u32, 0x3F800000), std.mem.readInt(u32, s[32..36], .little)); // far_bits
}

test "drawPointDepth encodes tag 33 + 5 u32 payload (20 bytes)" {
    var buf: [64]u8 = undefined;
    var enc = Encoder.init(&buf);
    enc.drawPointDepth(1, 2, 12, 36, 0x4000);
    const s = enc.finish();
    try testing.expectEqual(@as(u16, 33), std.mem.readInt(u16, s[4..6], .little)); // tag
    try testing.expectEqual(@as(u16, 20), std.mem.readInt(u16, s[6..8], .little)); // payload_size
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, s[8..12], .little)); // vbuf
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, s[12..16], .little)); // ibuf
    try testing.expectEqual(@as(u32, 12), std.mem.readInt(u32, s[16..20], .little)); // index_byte_off
    try testing.expectEqual(@as(u32, 36), std.mem.readInt(u32, s[20..24], .little)); // index_count
    try testing.expectEqual(@as(u32, 0x4000), std.mem.readInt(u32, s[24..28], .little)); // model_ptr
}

test "endPointShadow encodes tag 34 + 2 u32 payload (8 bytes)" {
    var buf: [32]u8 = undefined;
    var enc = Encoder.init(&buf);
    enc.endPointShadow(800, 600);
    const s = enc.finish();
    try testing.expectEqual(@as(u16, 34), std.mem.readInt(u16, s[4..6], .little)); // tag
    try testing.expectEqual(@as(u16, 8), std.mem.readInt(u16, s[6..8], .little)); // payload_size
    try testing.expectEqual(@as(u32, 800), std.mem.readInt(u32, s[8..12], .little)); // width
    try testing.expectEqual(@as(u32, 600), std.mem.readInt(u32, s[12..16], .little)); // height
}

test "bindPointShadow encodes tag 35 + 2 u32 payload (8 bytes)" {
    // Task 1b: bind_point_shadow shrank 16→8 bytes; light_pos_ptr + far_bits dropped
    // because the receiver reads lpos/far from the per-light loop vars (no dedicated uniform).
    var buf: [32]u8 = undefined;
    var enc = Encoder.init(&buf);
    enc.bindPointShadow(9, 7);
    const s = enc.finish();
    // length header (4) + record header (4) + 2×u32 payload (8) = 16 total stream bytes
    try testing.expectEqual(@as(u32, 12), std.mem.readInt(u32, s[0..4], .little)); // record bytes = 12
    try testing.expectEqual(@as(u16, 35), std.mem.readInt(u16, s[4..6], .little)); // tag
    try testing.expectEqual(@as(u16, 8), std.mem.readInt(u16, s[6..8], .little)); // payload_size
    try testing.expectEqual(@as(u32, 9), std.mem.readInt(u32, s[8..12], .little)); // slot
    try testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, s[12..16], .little)); // handle
}

test "golden: begin_shadow_pass (tag 17) 20-byte layout" {
    // Task 1b: begin_shadow_pass widened from {shadow,depth_shader,size}=12B
    // to {atlas_handle,depth_shader,col,row,tile}=20B so depth passes can target
    // individual tiles in the 4096² atlas. Mirrors begin_point_shadow_face col/row/tile convention.
    var buf: [64]u8 = undefined;
    var enc = Encoder.init(&buf);
    enc.beginShadowPass(3, 5, 1, 0, 1024); // atlas=3, depth_shader=5, col=1, row=0, tile=1024
    enc.endFrame();
    const stream = enc.finish();
    const hex = try hexAlloc(testing.allocator, stream);
    defer testing.allocator.free(hex);
    // length header (4) + BEGIN_SHADOW_PASS (4+20=24) + END_FRAME (4) = 28 record bytes
    try testing.expectEqualStrings(
        "1c000000" ++ // length header: 28 record bytes
            // BEGIN_SHADOW_PASS tag=17=0x11 payload=20=0x14
            "1100" ++ "1400" ++
            "03000000" ++ // atlas_handle=3
            "05000000" ++ // depth_shader=5
            "01000000" ++ // col=1
            "00000000" ++ // row=0
            "00040000" ++ // tile=1024=0x400
            // END_FRAME
            "0600" ++ "0000",
        hex,
    );
}

test "golden: bind_point_shadow (tag 35) 8-byte layout" {
    // Task 1b: bind_point_shadow shrank from {slot,handle,light_pos_ptr,far_bits}=16B
    // to {slot,handle}=8B. The receiver reads lpos/far from the per-light loop
    // (v0.zw/v1.x = lpos, v2.w = lrange = far), matching the Task 1 shader redesign.
    var buf: [32]u8 = undefined;
    var enc = Encoder.init(&buf);
    enc.bindPointShadow(tex_slot_point_shadow, 12);
    enc.endFrame();
    const stream = enc.finish();
    const hex = try hexAlloc(testing.allocator, stream);
    defer testing.allocator.free(hex);
    // length header (4) + BIND_POINT_SHADOW (4+8=12) + END_FRAME (4) = 16 record bytes
    try testing.expectEqualStrings(
        "10000000" ++ // length header: 16 record bytes
            // BIND_POINT_SHADOW tag=35=0x23 payload=8
            "2300" ++ "0800" ++
            "09000000" ++ // slot=tex_slot_point_shadow=9
            "0c000000" ++ // handle=12
            // END_FRAME
            "0600" ++ "0000",
        hex,
    );
}

// ── Point-depth shader sources (T2) ──────────────────────────────────────────

test "point-depth GLSL: vertex emits u_face_vp + u_model + v_world; fragment has packDist + u_light_pos + u_far" {
    const vs = pointDepthVertexSrc();
    try testing.expect(std.mem.indexOf(u8, vs, "u_face_vp") != null);
    try testing.expect(std.mem.indexOf(u8, vs, "u_model") != null);
    try testing.expect(std.mem.indexOf(u8, vs, "v_world") != null);
    const fs = pointDepthFragmentSrc();
    try testing.expect(std.mem.indexOf(u8, fs, "packDist") != null);
    try testing.expect(std.mem.indexOf(u8, fs, "u_light_pos") != null);
    try testing.expect(std.mem.indexOf(u8, fs, "u_far") != null);
}

test "point-depth WGSL: combined src has packDist + u_face_vp (via face_vp) + u_light_pos (via light_pos)" {
    const w = pointDepthWgslSrc();
    try testing.expect(std.mem.indexOf(u8, w, "packDist") != null);
    try testing.expect(std.mem.indexOf(u8, w, "face_vp") != null);
    try testing.expect(std.mem.indexOf(u8, w, "light_pos") != null);
    try testing.expect(std.mem.indexOf(u8, w, "vs_main") != null);
    try testing.expect(std.mem.indexOf(u8, w, "fs_main") != null);
}

// ── Point-shadow receiver GLSL (T3) ──────────────────────────────────────────

test "GLSL variant_shadow_point: receiver emits u_point_atlas, unpackDist, pointShadowFactor" {
    const f = pbrFragmentSrc(variant_pbr | variant_shadow_point);
    try testing.expect(std.mem.indexOf(u8, f, "u_point_atlas") != null);
    try testing.expect(std.mem.indexOf(u8, f, "unpackDist") != null);
    try testing.expect(std.mem.indexOf(u8, f, "pointShadowFactor(vec3 lpos, float far, int pidx)") != null);
    // The shadow is folded into per-light radiance; the combine is plain.
    try testing.expect(std.mem.indexOf(u8, f, "radiance *= pointShadowFactor(lpos, lrange, int(v3.z + 0.5))") != null);
    try testing.expect(std.mem.indexOf(u8, f, "vec3 color = ambient + Lo;") != null);
    // Plain PBR variant carries none of it.
    const plain = pbrFragmentSrc(variant_pbr);
    try testing.expect(std.mem.indexOf(u8, plain, "u_point_atlas") == null);
    // Directional/spot shadow variant is unaffected.
    const shadow2d = pbrFragmentSrc(variant_pbr | variant_shadow);
    try testing.expect(std.mem.indexOf(u8, shadow2d, "u_point_atlas") == null);
}

test "golden: variant_shadow_point GLSL fragment hash frozen (FNV-1a-64)" {
    // Re-frozen (Slice 1 multi-caster): pointShadowFactor now takes (lpos, far, pidx),
    // samples the 1536×4096 atlas per caster, and is folded into per-light radiance.
    const SP = variant_pbr | variant_shadow_point;
    // Re-frozen (Slice 2 CSM): loop guards reordered + range-bounded (point now
    // `>1.5 && <2.5`, csm slot inserted before point/2d). pointShadowFactor body
    // unchanged; the in-loop guard text + emission order shifted the FS hash.
    // Re-frozen (Slice 3 LTC): area uniforms + LTC eval added to all PBR fragments.
    try testing.expectEqual(@as(u64, 0x5fc23591bcddf578), fnv64(pbrFragmentSrc(SP)));
}

// ── Point-shadow receiver WGSL (T4) ──────────────────────────────────────────

test "WGSL variant_shadow_point: receiver emits binding(11), unpackDist, pointShadowFactor" {
    const SP = variant_pbr | variant_shadow_point;
    const w = wgslPbr(SP);
    // Atlas texture at group(1) binding 11.
    try testing.expect(std.mem.indexOf(u8, w, "@group(1) @binding(11) var point_atlas") != null);
    // No dedicated point-shadow uniform: lpos/far come from the per-light loop now.
    try testing.expect(std.mem.indexOf(u8, w, "PointShadow") == null);
    // unpackDist helper present.
    try testing.expect(std.mem.indexOf(u8, w, "unpackDist") != null);
    // pointShadowFactor takes per-caster args.
    try testing.expect(std.mem.indexOf(u8, w, "fn pointShadowFactor(world_pos: vec3<f32>, lpos: vec3<f32>, far: f32, pidx: i32)") != null);
    // Shadow folded into radiance; combine is plain.
    try testing.expect(std.mem.indexOf(u8, w, "radiance = radiance * pointShadowFactor(in.world_pos, lpos, lrange, i32(v3.z + 0.5))") != null);
    try testing.expect(std.mem.indexOf(u8, w, "var color = ambient + Lo;") != null);
    // Plain PBR variant carries none of it.
    const plain = wgslPbr(variant_pbr);
    try testing.expect(std.mem.indexOf(u8, plain, "point_atlas") == null);
    try testing.expect(std.mem.indexOf(u8, plain, "pointShadowFactor") == null);
    // Directional/spot shadow variant is unaffected.
    const shadow2d = wgslPbr(variant_pbr | variant_shadow);
    try testing.expect(std.mem.indexOf(u8, shadow2d, "point_atlas") == null);
}

test "golden: variant_shadow_point WGSL hash frozen (FNV-1a-64)" {
    // Re-frozen (Slice 1 multi-caster): PointShadow uniform removed (lpos/far from
    // the loop), pointShadowFactor takes (world_pos, lpos, far, pidx), 1536×4096 atlas.
    const SP = variant_pbr | variant_shadow_point;
    // Re-frozen (Slice 2 CSM): loop guards reordered + range-bounded (point now
    // `>1.5 && <2.5`, csm slot inserted before point/2d in emission). pointShadowFactor
    // body unchanged; the in-loop guard text + emission order shifted the FS hash.
    // Re-frozen (Slice 3 LTC): area fields in base U + LTC bindings/helpers/eval.
    try testing.expectEqual(@as(u64, 0xfd6be0911979ca4e), fnv64(wgslPbr(SP)));
}

// ── Slice 3: rect area lights (LTC) ─────────────────────────────────

test "area lights: tag values + constants" {
    try testing.expectEqual(@as(u16, 37), @intFromEnum(Tag.set_area_lights));
    try testing.expectEqual(@as(u16, 38), @intFromEnum(Tag.bind_ltc_lut));
    try testing.expectEqual(@as(u32, 4), max_area_lights);
    try testing.expectEqual(@as(u32, 16), area_light_stride_f32);
    try testing.expectEqual(@as(u32, 10), tex_slot_ltc_mat);
    try testing.expectEqual(@as(u32, 11), tex_slot_ltc_mag);
}

test "GLSL PBR: area-light uniforms + LTC samplers + eval present in every variant" {
    // area_lights is in the BASE U → present in EVERY pbr fragment variant.
    inline for (.{
        variant_pbr,
        variant_pbr | variant_normal_map,
        variant_pbr | variant_emissive,
        variant_pbr | variant_shadow,
        variant_pbr | variant_shadow_point,
        variant_pbr | variant_skinned,
    }) |F| {
        const fs = pbrFragmentSrc(F);
        try testing.expect(std.mem.indexOf(u8, fs, "uniform int u_area_count;") != null);
        try testing.expect(std.mem.indexOf(u8, fs, "uniform vec4 u_area_lights[16];") != null);
        try testing.expect(std.mem.indexOf(u8, fs, "uniform sampler2D u_ltc_mat;") != null);
        try testing.expect(std.mem.indexOf(u8, fs, "uniform sampler2D u_ltc_mag;") != null);
        try testing.expect(std.mem.indexOf(u8, fs, "vec3 ltcEvaluate(") != null);
        try testing.expect(std.mem.indexOf(u8, fs, "ai < u_area_count") != null);
        // Corner construction (pos ± ex ± ey).
        try testing.expect(std.mem.indexOf(u8, fs, "vec3 c0 = a_pos + ex - ey;") != null);
        // LTC UV mapping (63/64 scale + 0.5/64 bias).
        try testing.expect(std.mem.indexOf(u8, fs, "(63.0 / 64.0) + 0.5 / 64.0") != null);
        // Fresnel from LTC_2 channels (no extra /PI on the form factor).
        try testing.expect(std.mem.indexOf(u8, fs, "F0 * t2.x + (vec3(1.0) - F0) * t2.y") != null);
    }
}

test "GLSL area shadow line only under variant_shadow" {
    const with = pbrFragmentSrc(variant_pbr | variant_shadow);
    const without = pbrFragmentSrc(variant_pbr);
    try testing.expect(std.mem.indexOf(u8, with, "area_contrib *= shadowFactor2D(int(a2.w + 0.5))") != null);
    try testing.expect(std.mem.indexOf(u8, without, "area_contrib *= shadowFactor2D") == null);
    // Area eval loop itself is ALWAYS present (even without shadow).
    try testing.expect(std.mem.indexOf(u8, without, "ai < u_area_count") != null);
}

test "WGSL PBR: area fields in U + LTC bindings + eval present in every variant" {
    inline for (.{
        variant_pbr,
        variant_pbr | variant_normal_map,
        variant_pbr | variant_shadow,
        variant_pbr | variant_shadow_point,
        variant_pbr | variant_skinned,
    }) |F| {
        const src = wgslPbr(F);
        try testing.expect(std.mem.indexOf(u8, src, "area_count: i32,") != null);
        try testing.expect(std.mem.indexOf(u8, src, "area_lights: array<vec4<f32>, 16>,") != null);
        try testing.expect(std.mem.indexOf(u8, src, "@binding(12) var ltc_mat: texture_2d<f32>;") != null);
        try testing.expect(std.mem.indexOf(u8, src, "@binding(13) var ltc_mag: texture_2d<f32>;") != null);
        try testing.expect(std.mem.indexOf(u8, src, "fn ltcEvaluate(") != null);
        try testing.expect(std.mem.indexOf(u8, src, "ai < u.area_count") != null);
        // Free helper threads world_pos as a PARAM (no in.* ref inside ltcEvaluate).
        try testing.expect(std.mem.indexOf(u8, src, "ltcEvaluate(N, V, in.world_pos") != null);
    }
}

test "WGSL U layout order: area_count/area_lights between prefiltered_mips and shadow_vp" {
    const src = wgslPbr(variant_pbr | variant_shadow);
    const i_mips = std.mem.indexOf(u8, src, "prefiltered_mips: f32,").?;
    const i_acount = std.mem.indexOf(u8, src, "area_count: i32,").?;
    const i_alights = std.mem.indexOf(u8, src, "area_lights: array<vec4<f32>, 16>,").?;
    const i_shadow = std.mem.indexOf(u8, src, "shadow_vp: array<mat4x4<f32>, 8>,").?;
    // Byte order in the struct = field offset order: mips@500 < area_count@504 <
    // area_lights@512 < shadow_vp@768.
    try testing.expect(i_mips < i_acount);
    try testing.expect(i_acount < i_alights);
    try testing.expect(i_alights < i_shadow);
}

test "WGSL instanced vp lands AFTER area_lights (offset 512→768)" {
    // Instanced draws are non-shadow + non-area; their `vp` must NOT collide with
    // area_lights@512. It now follows area_lights (offset 768).
    const src = wgslPbr(variant_pbr | variant_instanced);
    const i_alights = std.mem.indexOf(u8, src, "area_lights: array<vec4<f32>, 16>,").?;
    // Match the instanced `vp` line specifically (leading newline+spaces avoids the
    // `mvp:` field, which also ends in "vp:").
    const i_vp = std.mem.indexOf(u8, src, "\n  vp: mat4x4<f32>,").?;
    try testing.expect(i_alights < i_vp);
}

test "golden: set_area_lights (tag 37) 8-byte payload" {
    var buf: [64]u8 = undefined;
    var enc = Encoder.init(&buf);
    enc.setAreaLights(2, 0x1000);
    enc.endFrame();
    const stream = enc.finish();
    const hex = try hexAlloc(testing.allocator, stream);
    defer testing.allocator.free(hex);
    try testing.expectEqualStrings(
        "10000000" ++ // 16 record bytes
            // SET_AREA_LIGHTS count=2 ptr=0x1000
            "2500" ++ "0800" ++ "02000000" ++ "00100000" ++
            // END_FRAME
            "0600" ++ "0000",
        hex,
    );
}

test "golden: bind_ltc_lut (tag 38) 8-byte payload" {
    var buf: [64]u8 = undefined;
    var enc = Encoder.init(&buf);
    enc.bindLtcLut(0x20, 0x21);
    enc.endFrame();
    const stream = enc.finish();
    const hex = try hexAlloc(testing.allocator, stream);
    defer testing.allocator.free(hex);
    try testing.expectEqualStrings(
        "10000000" ++ // 16 record bytes
            // BIND_LTC_LUT ltc_mat=0x20 ltc_mag=0x21
            "2600" ++ "0800" ++ "20000000" ++ "21000000" ++
            // END_FRAME
            "0600" ++ "0000",
        hex,
    );
}

test "non-PBR shaders unchanged by Slice 3 (no area/LTC leakage)" {
    // Area lighting is PBR-only: unlit/lit/depth must NOT gain area uniforms.
    try testing.expect(std.mem.indexOf(u8, unlit_fs, "u_area") == null);
    try testing.expect(std.mem.indexOf(u8, lit_fs, "u_area") == null);
    try testing.expect(std.mem.indexOf(u8, depthFragmentSrc(), "u_area") == null);
    try testing.expect(std.mem.indexOf(u8, depthVertexSrc(), "u_ltc") == null);
    // Frozen non-pbr hashes (must not move).
    try testing.expectEqual(@as(u64, 0xa159f35e040f6f8f), fnv64(wgslUnlit));
}

// ── Image-quality slice 2: tone-mapping + vignette ───────────────────────────

test "ToneMap enum integer values (wire contract)" {
    // These integer values are the wire contract between Zig and the composite shader.
    // Changing any of them is a breaking change.
    try testing.expectEqual(@as(u8, 0), @intFromEnum(ToneMap.linear));
    try testing.expectEqual(@as(u8, 1), @intFromEnum(ToneMap.reinhard));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(ToneMap.reinhard_ext));
    try testing.expectEqual(@as(u8, 3), @intFromEnum(ToneMap.aces));
    try testing.expectEqual(@as(u8, 4), @intFromEnum(ToneMap.agx));
    try testing.expectEqual(@as(u8, 5), @intFromEnum(ToneMap.uncharted2));
}

test "PostProcess defaults: tonemap=aces, vignette=null" {
    const pp = PostProcess{};
    try testing.expectEqual(ToneMap.aces, pp.tonemap);
    try testing.expect(pp.vignette == null);
}

test "Vignette default values" {
    const v = Vignette{};
    try testing.expectEqual(@as(f32, 0.0), v.intensity);
    try testing.expectEqual(@as(f32, 0.75), v.radius);
}

test "composite param layout: 4 floats [intensity, tonemap, vig_intensity, vig_radius]" {
    // p_comp is [4]f32; verify endPostProcess sets all 4 fields.
    var buf: [4096]u8 = undefined;
    var enc = Encoder.init(&buf);
    var ctx = PostCtx{};
    enc.beginPostProcess(&ctx, .{
        .bloom = .{ .intensity = 0.6 },
        .tonemap = .reinhard,
        .vignette = .{ .intensity = 0.5, .radius = 0.8 },
    }, 800, 600);
    enc.endPostProcess(&ctx);
    // p_comp[0] = bloom intensity, [1] = tonemap index, [2] = vig_intensity, [3] = vig_radius.
    try testing.expectApproxEqAbs(@as(f32, 0.6), ctx.p_comp[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), ctx.p_comp[1], 1e-6); // reinhard = 1
    try testing.expectApproxEqAbs(@as(f32, 0.5), ctx.p_comp[2], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.8), ctx.p_comp[3], 1e-6);
}

test "composite param: aces default writes index 3.0" {
    var buf: [4096]u8 = undefined;
    var enc = Encoder.init(&buf);
    var ctx = PostCtx{};
    enc.beginPostProcess(&ctx, .{ .bloom = .{ .intensity = 0.8 } }, 800, 600);
    enc.endPostProcess(&ctx);
    try testing.expectApproxEqAbs(@as(f32, 3.0), ctx.p_comp[1], 1e-6); // aces = 3
    try testing.expectApproxEqAbs(@as(f32, 0.0), ctx.p_comp[2], 1e-6); // no vignette
}

test "composite param: no-bloom path still writes tonemap + vignette" {
    var buf: [4096]u8 = undefined;
    var enc = Encoder.init(&buf);
    var ctx = PostCtx{};
    enc.beginPostProcess(&ctx, .{
        .bloom = null,
        .tonemap = .agx,
        .vignette = .{ .intensity = 1.0, .radius = 0.6 },
    }, 800, 600);
    enc.endPostProcess(&ctx);
    try testing.expectApproxEqAbs(@as(f32, 0.0), ctx.p_comp[0], 1e-6); // no bloom
    try testing.expectApproxEqAbs(@as(f32, 4.0), ctx.p_comp[1], 1e-6); // agx = 4
    try testing.expectApproxEqAbs(@as(f32, 1.0), ctx.p_comp[2], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.6), ctx.p_comp[3], 1e-6);
}

test "WGSL composite: all 6 operator branches + vignette + struct Params repacked" {
    const src = wgslComposite();
    // Repacked Params struct (vec4, 16B).
    try testing.expect(std.mem.indexOf(u8, src, "struct Params { intensity: f32, tonemap: f32, vig_intensity: f32, vig_radius: f32 }") != null);
    // Operator dispatch.
    try testing.expect(std.mem.indexOf(u8, src, "let op = i32(P.tonemap + 0.5)") != null);
    // Each operator branch.
    try testing.expect(std.mem.indexOf(u8, src, "if (op == 0)") != null); // linear
    try testing.expect(std.mem.indexOf(u8, src, "else if (op == 1)") != null); // reinhard
    try testing.expect(std.mem.indexOf(u8, src, "else if (op == 2)") != null); // reinhard_ext
    try testing.expect(std.mem.indexOf(u8, src, "else if (op == 3)") != null); // aces (default)
    try testing.expect(std.mem.indexOf(u8, src, "else if (op == 4)") != null); // agx
    // ACES branch contains the original coefficients (byte-identical guard).
    try testing.expect(std.mem.indexOf(u8, src, "let a = 2.51; let b = 0.03; let c = 2.43; let d = 0.59; let e = 0.14;") != null);
    // Vignette applied after tonemap.
    try testing.expect(std.mem.indexOf(u8, src, "vig_radius") != null);
    try testing.expect(std.mem.indexOf(u8, src, "smoothstep") != null);
    try testing.expect(std.mem.indexOf(u8, src, "vig_intensity") != null);
}

test "GLSL composite: all 6 operators + vignette + u_tonemap + u_vig_intensity + u_vig_radius" {
    const src = compositeFragmentSrc;
    try testing.expect(std.mem.indexOf(u8, src, "u_tonemap") != null);
    try testing.expect(std.mem.indexOf(u8, src, "u_vig_intensity") != null);
    try testing.expect(std.mem.indexOf(u8, src, "u_vig_radius") != null);
    // All 6 operator branches.
    try testing.expect(std.mem.indexOf(u8, src, "op == 0") != null); // linear
    try testing.expect(std.mem.indexOf(u8, src, "op == 1") != null); // reinhard
    try testing.expect(std.mem.indexOf(u8, src, "op == 2") != null); // reinhard_ext
    try testing.expect(std.mem.indexOf(u8, src, "op == 3") != null); // aces
    try testing.expect(std.mem.indexOf(u8, src, "op == 4") != null); // agx
    // ACES coefficients unchanged.
    try testing.expect(std.mem.indexOf(u8, src, "2.51") != null);
    try testing.expect(std.mem.indexOf(u8, src, "2.43") != null);
    // Vignette.
    try testing.expect(std.mem.indexOf(u8, src, "smoothstep") != null);
}

test "golden: post shader sources frozen after slice 2 (FNV-1a-64)" {
    // Composite hashes changed intentionally (new operators + vignette).
    // Non-composite post shaders must NOT change.
    try testing.expectEqual(@as(u64, 0xd8e25fe0c5f0c5c3), fnv64(fullscreenVertexSrc));
    try testing.expectEqual(@as(u64, 0xceff6b2f105a92ec), fnv64(brightFragmentSrc));
    try testing.expectEqual(@as(u64, 0x221d8b95dd9492ba), fnv64(blurFragmentSrc));
    try testing.expectEqual(@as(u64, 0x9d052976fb0b2105), fnv64(fxaaFragmentSrc));
    try testing.expectEqual(@as(u64, 0xefa46fcd8c5003b6), fnv64(wgslBright()));
    try testing.expectEqual(@as(u64, 0xb93270d3619361ca), fnv64(wgslBlur()));
    try testing.expectEqual(@as(u64, 0xe8ac45e2d1276dfd), fnv64(wgslFxaa()));
    // Composite goldens UPDATED for AgX fix (real Sobotka/Filament minimal AgX —
    // replaces the mislabeled Reinhard-variant that shipped in commit ebe2373):
    try testing.expectEqual(@as(u64, 0xeaacf23156d5b2bd), fnv64(compositeFragmentSrc));
    try testing.expectEqual(@as(u64, 0x0d62d18cbf80d694), fnv64(wgslComposite()));
}
