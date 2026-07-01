//! verve.gl custom shader material builder.
//! `Material(comptime opts)` — app-facing comptime API for baked custom PBR shader
//! materials. Computes a packing table for `.uniforms` (std140-simplified layout),
//! generates alias preambles for both GLSL and WGSL so snippet authors use bare
//! declared names, then calls the hook seam in command.zig to assemble the frozen
//! custom shader source. Everything runs entirely at comptime.

const std = @import("std");
const math = @import("math.zig");
const command = @import("command.zig");

// ── helpers ────────────────────────────────────────────────────────────────────

/// FNV-1a-32: stable, JS-computable name hash (glmat_set looks up by this in slice 3).
/// Quota raised to handle full assembled shader sources (several KiB).
fn fnv32(comptime s: []const u8) u32 {
    @setEvalBranchQuota(1_000_000);
    comptime var h: u32 = 0x811c9dc5;
    inline for (s) |c| {
        h ^= @as(u32, c);
        h *%= 0x01000193;
    }
    return h;
}

fn comptimeU8Str(comptime n: u8) []const u8 {
    return switch (n) {
        0 => "0",
        1 => "1",
        2 => "2",
        3 => "3",
        else => @compileError("vec4_index out of range"),
    };
}

fn uniformKindOf(comptime T: type, comptime fname: []const u8) UniformKind {
    return if (T == f32)
        .scalar
    else if (T == math.Vec2)
        .vec2
    else if (T == math.Vec3)
        .vec3
    else if (T == math.Vec4)
        .vec4
    else
        @compileError("unsupported uniform type for field: " ++ fname);
}

fn swizzleStr(comptime lane: u8, comptime lanes: u8) []const u8 {
    if (lanes == 4) return "";
    return "." ++ ("xyzw"[lane .. lane + lanes]);
}

fn glslTypeName(comptime kind: UniformKind) []const u8 {
    return switch (kind) {
        .scalar => "float",
        .vec2 => "vec2",
        .vec3 => "vec3",
        .vec4 => "vec4",
    };
}

// ── public types ───────────────────────────────────────────────────────────────

pub const UniformKind = enum { scalar, vec2, vec3, vec4 };

pub const UniformSlot = struct {
    name: []const u8,
    name_id: u32, // fnv32(name) — stable, JS-computable (glmat_set in slice 3)
    kind: UniformKind,
    vec4_index: u8, // index into params[]
    lane: u8, // starting lane 0..3
    lanes: u8, // scalar=1, vec2=2, vec3=3, vec4=4
};

pub const MaterialDesc = struct {
    flags: u32, // command.variant_pbr | command.variant_custom
    wgsl: []const u8, // wgslPbrHooked(flags, hooks)
    glsl_vs: []const u8, // pbrVertexSrcHooked(flags, hooks) — hooked when vertex opts present
    glsl_fs: []const u8, // pbrFragmentSrcHooked(flags, hooks)
    uniforms: []const UniformSlot, // declaration order
    param_vec4_count: u8, // K vec4s actually used (must be ≤ 4)
    id: u32, // fnv32(wgsl ++ "|" ++ glsl_fs) — stable identity for data-glmat attribute
};

// ── builder ────────────────────────────────────────────────────────────────────

/// `Material(comptime opts) MaterialDesc` — entirely comptime.
///
/// `opts` fields (all optional):
/// - `.frag_albedo = .{ .glsl = "...", .wgsl = "..." }` — replaces albedo in PBR pipeline.
/// - `.frag_final = .{ .glsl = "...", .wgsl = "..." }` — post-tonemap color hook.
/// - `.vertex_displace = .{ .glsl = "...", .wgsl = "..." }` — writes `vrv_pos` (local-space position).
/// - `.vertex_normal = .{ .glsl = "...", .wgsl = "..." }` — writes `vrv_normal` (local-space normal).
/// - `.uniforms = .{ .name = Type, ... }` — uniform type markers; Type ∈ {f32, Vec2, Vec3, Vec4}.
///
/// Packed into params[] vec4s (std140-simplified, declaration order).
/// Alias preambles prepended to each hook snippet so snippets use bare names + `u_time`.
pub fn Material(comptime opts: anytype) MaterialDesc {
    const flags = command.variant_pbr | command.variant_custom;

    const has_uniforms = @hasField(@TypeOf(opts), "uniforms");
    const has_frag_albedo = @hasField(@TypeOf(opts), "frag_albedo");
    const has_frag_final = @hasField(@TypeOf(opts), "frag_final");
    const has_vertex_displace = @hasField(@TypeOf(opts), "vertex_displace");
    const has_vertex_normal = @hasField(@TypeOf(opts), "vertex_normal");

    // Validate dual-language requirement
    if (has_frag_albedo) {
        if (!@hasField(@TypeOf(opts.frag_albedo), "glsl") or !@hasField(@TypeOf(opts.frag_albedo), "wgsl"))
            @compileError("frag_albedo requires both .glsl and .wgsl");
    }
    if (has_frag_final) {
        if (!@hasField(@TypeOf(opts.frag_final), "glsl") or !@hasField(@TypeOf(opts.frag_final), "wgsl"))
            @compileError("frag_final requires both .glsl and .wgsl");
    }
    if (has_vertex_displace) {
        if (!@hasField(@TypeOf(opts.vertex_displace), "glsl") or !@hasField(@TypeOf(opts.vertex_displace), "wgsl"))
            @compileError("vertex_displace requires both .glsl and .wgsl");
    }
    if (has_vertex_normal) {
        if (!@hasField(@TypeOf(opts.vertex_normal), "glsl") or !@hasField(@TypeOf(opts.vertex_normal), "wgsl"))
            @compileError("vertex_normal requires both .glsl and .wgsl");
    }

    const n_uniforms: usize = if (has_uniforms) std.meta.fields(@TypeOf(opts.uniforms)).len else 0;

    // Use a comptime struct so slots + preambles get static (rodata) lifetime.
    const S = struct {
        const slots: [n_uniforms]UniformSlot = blk: {
            var s: [n_uniforms]UniformSlot = undefined;
            if (has_uniforms) {
                var vi: u8 = 0;
                var lc: u8 = 0;
                for (std.meta.fields(@TypeOf(opts.uniforms)), 0..) |field, i| {
                    const T = @field(opts.uniforms, field.name);
                    const kind = uniformKindOf(T, field.name);
                    switch (kind) {
                        .scalar => {
                            s[i] = .{ .name = field.name, .name_id = fnv32(field.name), .kind = kind, .vec4_index = vi, .lane = lc, .lanes = 1 };
                            lc += 1;
                            if (lc == 4) {
                                vi += 1;
                                lc = 0;
                            }
                        },
                        .vec2 => {
                            // 8-byte align: start lane must be even
                            if (lc == 1) {
                                lc = 2;
                            } else if (lc == 3) {
                                vi += 1;
                                lc = 0;
                            }
                            s[i] = .{ .name = field.name, .name_id = fnv32(field.name), .kind = kind, .vec4_index = vi, .lane = lc, .lanes = 2 };
                            lc += 2;
                            if (lc == 4) {
                                vi += 1;
                                lc = 0;
                            }
                        },
                        .vec3 => {
                            // own vec4 — align to lane 0
                            if (lc != 0) {
                                vi += 1;
                                lc = 0;
                            }
                            s[i] = .{ .name = field.name, .name_id = fnv32(field.name), .kind = kind, .vec4_index = vi, .lane = 0, .lanes = 3 };
                            vi += 1;
                            lc = 0;
                        },
                        .vec4 => {
                            // own vec4 — align to lane 0
                            if (lc != 0) {
                                vi += 1;
                                lc = 0;
                            }
                            s[i] = .{ .name = field.name, .name_id = fnv32(field.name), .kind = kind, .vec4_index = vi, .lane = 0, .lanes = 4 };
                            vi += 1;
                            lc = 0;
                        },
                    }
                }
            }
            break :blk s;
        };

        const param_vec4_count: u8 = if (n_uniforms == 0) 0 else slots[n_uniforms - 1].vec4_index + 1;

        // WGSL alias preamble: "let u_time = custom.u_time;" then one line per uniform.
        // Unconditionally emitted for every hook present; unused-alias warnings are benign.
        const wgsl_preamble: []const u8 = wp: {
            var pre: []const u8 = "  let u_time = custom.u_time;\n";
            for (slots) |slot| {
                const idx = comptimeU8Str(slot.vec4_index);
                const sw = swizzleStr(slot.lane, slot.lanes);
                pre = pre ++ "  let " ++ slot.name ++ " = custom.params[" ++ idx ++ "]" ++ sw ++ ";\n";
            }
            break :wp pre;
        };

        // GLSL alias preamble: one line per uniform. u_time is already the real GLSL
        // uniform name so we do NOT alias it (would self-reference).
        const glsl_preamble: []const u8 = gp: {
            var pre: []const u8 = "";
            for (slots) |slot| {
                const idx = comptimeU8Str(slot.vec4_index);
                const sw = swizzleStr(slot.lane, slot.lanes);
                const gt = glslTypeName(slot.kind);
                pre = pre ++ "  " ++ gt ++ " " ++ slot.name ++ " = u_params[" ++ idx ++ "]" ++ sw ++ ";\n";
            }
            break :gp pre;
        };
    };

    if (S.param_vec4_count > 4) @compileError("custom material exceeds 4 param vec4s");

    // Compose hooks — prepend alias preamble to each supplied snippet body.
    comptime var hooks = command.ShaderHooks{};
    if (has_frag_albedo) {
        hooks.frag_albedo_wgsl = S.wgsl_preamble ++ opts.frag_albedo.wgsl;
        hooks.frag_albedo_glsl = S.glsl_preamble ++ opts.frag_albedo.glsl;
    }
    if (has_frag_final) {
        hooks.frag_final_wgsl = S.wgsl_preamble ++ opts.frag_final.wgsl;
        hooks.frag_final_glsl = S.glsl_preamble ++ opts.frag_final.glsl;
    }
    // Vertex hooks — same preamble builder (works in VS scope: 2A added custom_uniforms to GLSL VS,
    // WGSL custom is module-global). block-scoped splices prevent cross-hook redeclaration (C1 fix).
    if (has_vertex_displace) {
        hooks.vertex_displace_wgsl = S.wgsl_preamble ++ opts.vertex_displace.wgsl;
        hooks.vertex_displace_glsl = S.glsl_preamble ++ opts.vertex_displace.glsl;
    }
    if (has_vertex_normal) {
        hooks.vertex_normal_wgsl = S.wgsl_preamble ++ opts.vertex_normal.wgsl;
        hooks.vertex_normal_glsl = S.glsl_preamble ++ opts.vertex_normal.glsl;
    }

    const mat_wgsl = command.wgslPbrHooked(flags, hooks);
    const mat_glsl_fs = command.pbrFragmentSrcHooked(flags, hooks);
    return MaterialDesc{
        .flags = flags,
        .wgsl = mat_wgsl,
        .glsl_vs = command.pbrVertexSrcHooked(flags, hooks),
        .glsl_fs = mat_glsl_fs,
        .uniforms = &S.slots,
        .param_vec4_count = S.param_vec4_count,
        .id = fnv32(mat_wgsl ++ "|" ++ mat_glsl_fs),
    };
}

// ── tests ──────────────────────────────────────────────────────────────────────

test "Material: shape + assembly (Vec3 uniform, frag_final hook)" {
    const Vec3 = math.Vec3;
    const desc = comptime Material(.{
        .frag_final = .{
            .glsl = "vrv_color = vrv_color * tint;",
            .wgsl = "vrv_color = vrv_color * tint;",
        },
        .uniforms = .{ .tint = Vec3 },
    });

    // Flags
    try std.testing.expectEqual(command.variant_pbr | command.variant_custom, desc.flags);

    // Slot shape
    try std.testing.expectEqual(@as(usize, 1), desc.uniforms.len);
    const slot = desc.uniforms[0];
    try std.testing.expectEqualStrings("tint", slot.name);
    try std.testing.expectEqual(fnv32("tint"), slot.name_id);
    try std.testing.expectEqual(UniformKind.vec3, slot.kind);
    try std.testing.expectEqual(@as(u8, 0), slot.vec4_index);
    try std.testing.expectEqual(@as(u8, 0), slot.lane);
    try std.testing.expectEqual(@as(u8, 3), slot.lanes);
    try std.testing.expectEqual(@as(u8, 1), desc.param_vec4_count);

    // id: non-zero stable hash of assembled sources
    try std.testing.expect(desc.id != 0);
    try std.testing.expectEqual(comptime fnv32(desc.wgsl ++ "|" ++ desc.glsl_fs), desc.id);

    // WGSL assembled source contains the snippet and the aliases
    try std.testing.expect(std.mem.indexOf(u8, desc.wgsl, "vrv_color = vrv_color * tint;") != null);
    try std.testing.expect(std.mem.indexOf(u8, desc.wgsl, "let tint = custom.params[0].xyz;") != null);
    try std.testing.expect(std.mem.indexOf(u8, desc.wgsl, "let u_time = custom.u_time;") != null);

    // GLSL assembled source contains the snippet and the GLSL alias (NOT a u_time self-alias)
    try std.testing.expect(std.mem.indexOf(u8, desc.glsl_fs, "vrv_color = vrv_color * tint;") != null);
    try std.testing.expect(std.mem.indexOf(u8, desc.glsl_fs, "vec3 tint = u_params[0].xyz;") != null);
    try std.testing.expect(std.mem.indexOf(u8, desc.glsl_fs, "float u_time =") == null);
}

test "Material: packing — scalar+vec2+vec3, vec2 at lane 2 uses .zw" {
    const Vec2 = math.Vec2;
    const Vec3 = math.Vec3;
    const desc = comptime Material(.{
        .frag_final = .{ .glsl = "vrv_color = vrv_color;", .wgsl = "vrv_color = vrv_color;" },
        .uniforms = .{ .a = f32, .b = Vec2, .c = Vec3 },
    });

    try std.testing.expectEqual(@as(usize, 3), desc.uniforms.len);

    // a: scalar → (vi=0, lc=0, lanes=1)
    const a = desc.uniforms[0];
    try std.testing.expectEqualStrings("a", a.name);
    try std.testing.expectEqual(UniformKind.scalar, a.kind);
    try std.testing.expectEqual(@as(u8, 0), a.vec4_index);
    try std.testing.expectEqual(@as(u8, 0), a.lane);
    try std.testing.expectEqual(@as(u8, 1), a.lanes);

    // b: vec2 → lc=1 bumps to lc=2 → (vi=0, lc=2, lanes=2)
    const b = desc.uniforms[1];
    try std.testing.expectEqualStrings("b", b.name);
    try std.testing.expectEqual(UniformKind.vec2, b.kind);
    try std.testing.expectEqual(@as(u8, 0), b.vec4_index);
    try std.testing.expectEqual(@as(u8, 2), b.lane);
    try std.testing.expectEqual(@as(u8, 2), b.lanes);

    // c: vec3 → lc==0 after b exhausts lane 4 → (vi=1, lc=0, lanes=3)
    const c = desc.uniforms[2];
    try std.testing.expectEqualStrings("c", c.name);
    try std.testing.expectEqual(UniformKind.vec3, c.kind);
    try std.testing.expectEqual(@as(u8, 1), c.vec4_index);
    try std.testing.expectEqual(@as(u8, 0), c.lane);
    try std.testing.expectEqual(@as(u8, 3), c.lanes);

    try std.testing.expectEqual(@as(u8, 2), desc.param_vec4_count);

    // Alias swizzles in assembled source
    try std.testing.expect(std.mem.indexOf(u8, desc.wgsl, "let b = custom.params[0].zw;") != null);
    try std.testing.expect(std.mem.indexOf(u8, desc.wgsl, "let c = custom.params[1].xyz;") != null);
    try std.testing.expect(std.mem.indexOf(u8, desc.glsl_fs, "vec2 b = u_params[0].zw;") != null);
    try std.testing.expect(std.mem.indexOf(u8, desc.glsl_fs, "vec3 c = u_params[1].xyz;") != null);
}

test "Material: frag_albedo present → var albedo; frag_final-only → let albedo" {
    const desc_albedo = comptime Material(.{
        .frag_albedo = .{
            .glsl = "vrv_albedo = vrv_albedo * 0.5;",
            .wgsl = "vrv_albedo = vrv_albedo * 0.5;",
        },
    });
    // frag_albedo hook → fs_open_custom → "var albedo"
    try std.testing.expect(std.mem.indexOf(u8, desc_albedo.wgsl, "var albedo") != null);
    try std.testing.expect(std.mem.indexOf(u8, desc_albedo.wgsl, "vrv_albedo = vrv_albedo * 0.5;") != null);

    const desc_final = comptime Material(.{
        .frag_final = .{
            .glsl = "vrv_color = vrv_color * 0.5;",
            .wgsl = "vrv_color = vrv_color * 0.5;",
        },
    });
    // frag_final-only → normal path → "let albedo" (immutable)
    try std.testing.expect(std.mem.indexOf(u8, desc_final.wgsl, "let albedo") != null);
    try std.testing.expect(std.mem.indexOf(u8, desc_final.wgsl, "var albedo") == null);
}

test "Material: glsl_vs unchanged from pbrVertexSrc (frag-only, no vertex hooks)" {
    const desc = comptime Material(.{
        .frag_final = .{ .glsl = "vrv_color = vrv_color;", .wgsl = "vrv_color = vrv_color;" },
    });
    const expected_vs = comptime command.pbrVertexSrc(command.variant_pbr | command.variant_custom);
    try std.testing.expectEqualStrings(expected_vs, desc.glsl_vs);
}

test "Material: vertex_displace + vertex_normal + uniform → VS contains hooks + preamble" {
    const desc = comptime Material(.{
        .vertex_displace = .{
            .glsl = "vrv_pos.y += sin(u_time) * amp;",
            .wgsl = "vrv_pos.y = vrv_pos.y + sin(u_time) * amp;",
        },
        .vertex_normal = .{
            .glsl = "vrv_normal = normalize(vrv_normal + vec3(0.0, amp, 0.0));",
            .wgsl = "vrv_normal = normalize(vrv_normal + vec3<f32>(0.0, amp, 0.0));",
        },
        .uniforms = .{ .amp = f32 },
    });

    // GLSL VS contains both vertex snippets
    try std.testing.expect(std.mem.indexOf(u8, desc.glsl_vs, "vrv_pos.y += sin(u_time) * amp;") != null);
    try std.testing.expect(std.mem.indexOf(u8, desc.glsl_vs, "vrv_normal = normalize(vrv_normal + vec3(0.0, amp, 0.0));") != null);
    // GLSL VS contains the preamble alias for amp
    try std.testing.expect(std.mem.indexOf(u8, desc.glsl_vs, "float amp = u_params[0].x;") != null);
    // GLSL VS has the vrv_pos declaration (added by hooked VS when vertex hooks present)
    try std.testing.expect(std.mem.indexOf(u8, desc.glsl_vs, "vrv_pos") != null);

    // WGSL combined module contains both vertex snippets (in vs_main)
    try std.testing.expect(std.mem.indexOf(u8, desc.wgsl, "vrv_pos.y = vrv_pos.y + sin(u_time) * amp;") != null);
    try std.testing.expect(std.mem.indexOf(u8, desc.wgsl, "vrv_normal = normalize(vrv_normal + vec3<f32>(0.0, amp, 0.0));") != null);
    // WGSL contains vrv_pos
    try std.testing.expect(std.mem.indexOf(u8, desc.wgsl, "vrv_pos") != null);
    // WGSL contains u_time alias (from preamble prepended to each hook)
    try std.testing.expect(std.mem.indexOf(u8, desc.wgsl, "let u_time = custom.u_time;") != null);
}

test "Material: vertex-only → FS is plain (no frag splice)" {
    const desc = comptime Material(.{
        .vertex_displace = .{
            .glsl = "vrv_pos.y += 0.5;",
            .wgsl = "vrv_pos.y = vrv_pos.y + 0.5;",
        },
    });
    const plain_fs = comptime command.pbrFragmentSrc(command.variant_pbr | command.variant_custom);
    try std.testing.expectEqualStrings(plain_fs, desc.glsl_fs);
}

test "Material: vertex+frag+uniform → WGSL brace-balanced + u_time count per-hook" {
    const desc = comptime Material(.{
        .vertex_displace = .{
            .glsl = "vrv_pos.y += sin(u_time) * amp;",
            .wgsl = "vrv_pos.y = vrv_pos.y + sin(u_time) * amp;",
        },
        .vertex_normal = .{
            .glsl = "vrv_normal = normalize(vrv_normal);",
            .wgsl = "vrv_normal = normalize(vrv_normal);",
        },
        .frag_final = .{
            .glsl = "vrv_color = vrv_color * amp;",
            .wgsl = "vrv_color = vrv_color * amp;",
        },
        .uniforms = .{ .amp = f32 },
    });

    // WGSL must be brace-balanced (block-scoped splices each add matched { })
    var balance: i64 = 0;
    for (desc.wgsl) |c| {
        if (c == '{') balance += 1;
        if (c == '}') balance -= 1;
    }
    try std.testing.expectEqual(@as(i64, 0), balance);

    // let u_time = custom.u_time; appears exactly once per hook (3 hooks: vd, vn, ff)
    const needle = "let u_time = custom.u_time;";
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOf(u8, desc.wgsl[i..], needle)) |pos| {
        count += 1;
        i += pos + needle.len;
    }
    try std.testing.expectEqual(@as(usize, 3), count);
}

// Test 4 — Dual-language guard: structural invariant, not runtime-testable.
// Material(.{ .vertex_displace = .{ .glsl = "..." } })  — missing .wgsl —
// triggers @compileError("vertex_displace requires both .glsl and .wgsl").
// Likewise for .vertex_normal. Guard mirrors the frag-hook guards above it.
