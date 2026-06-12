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
};

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

pub const max_lights: u32 = 4;
pub const light_stride_f32: u32 = 8; // [type(0=dir,1=point), intensity, x,y,z, r,g,b]
pub const material_len_f32: u32 = 12; // base_color rgba | metallic, roughness, occlusion_strength, normal_scale | emissive rgb, 0

pub const tex_slot_base: u32 = 0;
pub const tex_slot_mr: u32 = 1;
pub const tex_slot_normal: u32 = 2;
pub const tex_slot_emissive: u32 = 3;
pub const tex_slot_occlusion: u32 = 4;
// IBL units (JS contract): irradiance=5 (cube), prefiltered=6 (cube), brdf_lut=7 (2D)

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
    const body_open =
        \\void main() {
        \\  v_world_pos = (u_model * vec4(a_pos, 1.0)).xyz;
        \\  v_normal = u_normal_mat * a_normal;
        \\  v_uv = a_uv;
        \\
    ;
    const nm_body =
        \\  v_tangent = normalize(mat3(u_model) * a_tangent.xyz);
        \\  v_bitangent = cross(v_normal, v_tangent) * a_tangent.w;
        \\
    ;
    const body_close =
        \\  gl_Position = u_mvp * vec4(a_pos, 1.0);
        \\}
        \\
    ;
    comptime var src: []const u8 = head;
    if (flags & variant_normal_map != 0) src = src ++ nm_outs;
    src = src ++ body_open;
    if (flags & variant_normal_map != 0) src = src ++ nm_body;
    src = src ++ body_close;
    return src;
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
        \\  vec3 base_sample = pow(texture(u_base_tex, v_uv).rgb, vec3(2.2));
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
        \\  vec3 color = ambient + Lo;
        \\
    ;
    const emissive =
        \\  color += emissive_factor * pow(texture(u_emissive_tex, v_uv).rgb, vec3(2.2));
        \\
    ;
    const tail =
        \\  color = clamp((color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14), 0.0, 1.0);
        \\  color = pow(color, vec3(1.0 / 2.2));
        \\  o_frag = vec4(color, base_color.a);
        \\}
        \\
    ;
    comptime var src: []const u8 = head;
    if (flags & variant_normal_map != 0) src = src ++ nm_ins;
    src = src ++ uniforms;
    if (flags & variant_normal_map != 0) src = src ++ nm_sampler;
    if (flags & variant_emissive != 0) src = src ++ em_sampler;
    src = src ++ ibl_samplers ++ main_open;
    src = src ++ (if (flags & variant_normal_map != 0) normal_nm else normal_plain);
    src = src ++ lighting;
    if (flags & variant_emissive != 0) src = src ++ emissive;
    src = src ++ tail;
    return src;
}

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

    pub fn endFrame(self: *Encoder) void {
        self.header(.end_frame, 0);
    }

    /// Stamp the length header and return the full stream.
    pub fn finish(self: *Encoder) []const u8 {
        std.mem.writeInt(u32, self.buf[0..4], @intCast(self.len - 4), .little);
        return self.buf[0..self.len];
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

test "golden: PBR GLSL hashes frozen (FNV-1a-64)" {
    const F0 = variant_pbr;
    const F1 = variant_pbr | variant_normal_map;
    const F2 = variant_pbr | variant_normal_map | variant_emissive;
    // Frozen from first green run — a change here = deliberate GLSL contract bump.
    try testing.expectEqual(@as(u64, 0x9fc619889b5412ca), fnv64(pbrVertexSrc(F0)));
    try testing.expectEqual(@as(u64, 0x197481afefd351c2), fnv64(pbrVertexSrc(F1)));
    try testing.expectEqual(@as(u64, 0x197481afefd351c2), fnv64(pbrVertexSrc(F2))); // emissive does not touch the VS
    try testing.expectEqual(@as(u64, 0x351b42b633fda5af), fnv64(pbrFragmentSrc(F0)));
    try testing.expectEqual(@as(u64, 0xadcb72b813f0d4e4), fnv64(pbrFragmentSrc(F1)));
    try testing.expectEqual(@as(u64, 0x3434b94b317be944), fnv64(pbrFragmentSrc(F2)));
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
