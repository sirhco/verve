//! anim_target — frozen target-id encoding for verve.gl animations.
//!
//! Target id u32:
//!   bits [31:24]  kind     (0=camera, 1=material, 2=model, 3=node)
//!   bits [23:8]   submesh  (material and node only; 0 otherwise)
//!   bits [7:0]    field
//!
//! Fields:
//!   camera   yaw=0  pitch=1  distance=2
//!   material metallic=0  roughness=1  emissive_r=2  emissive_g=3  emissive_b=4
//!   model    yaw=0
//!   node     rotation_x=0  rotation_y=1  rotation_z=2
//!            translate_x=3  translate_y=4  translate_z=5
//!            scale_x=6      scale_y=7      scale_z=8
//!
//! Path grammar (resolve once at setup via resolvePath):
//!   "camera.yaw" | "camera.pitch" | "camera.distance"
//!   "material:<Name>.metallic" | "material:<Name>.roughness"
//!   "material:<Name>.emissiveR" | "material:<Name>.emissiveG" | "material:<Name>.emissiveB"
//!   "model.yaw"
//!   "node:<Name>.rotationX" | "node:<Name>.rotationY" | "node:<Name>.rotationZ"
//!   "node:<Name>.translateX" | "node:<Name>.translateY" | "node:<Name>.translateZ"
//!   "node:<Name>.scaleX" | "node:<Name>.scaleY" | "node:<Name>.scaleZ"
//!   "morph:<index>"  (index 0–255; submesh always 0)
//!
//! resolvePathStatic handles ONLY camera.* and model.* (no name-table lookup needed).
//! Use it for SSR where no vmesh Reader is available.
//!
//! Freestanding-safe: std.mem only (runs in wasm32 island chunks).

const std = @import("std");
const vmesh = @import("vmesh.zig");

// ── enumerations ──────────────────────────────────────────────────────────────

pub const Kind = enum(u8) { camera = 0, material = 1, model = 2, node = 3, morph = 4 };
pub const CameraField = enum(u8) { yaw = 0, pitch = 1, distance = 2 };
pub const MaterialField = enum(u8) { metallic = 0, roughness = 1, emissive_r = 2, emissive_g = 3, emissive_b = 4, base_color_r = 5, base_color_g = 6, base_color_b = 7, base_color_a = 8 };
pub const ModelField = enum(u8) { yaw = 0 };
pub const NodeField = enum(u8) {
    rotation_x = 0,
    rotation_y = 1,
    rotation_z = 2,
    translate_x = 3,
    translate_y = 4,
    translate_z = 5,
    scale_x = 6,
    scale_y = 7,
    scale_z = 8,
};

// ── Decoded ───────────────────────────────────────────────────────────────────

pub const Decoded = struct { kind: Kind, submesh: u16, field: u8 };

// ── encode / decode ───────────────────────────────────────────────────────────

/// Pack (kind, submesh, field) into a 32-bit target id.
pub fn encode(kind: Kind, submesh: u16, field: u8) u32 {
    const k: u32 = @as(u32, @intFromEnum(kind)) << 24;
    const s: u32 = @as(u32, submesh) << 8;
    const f: u32 = field;
    return k | s | f;
}

/// Unpack a target id.  Returns null for unknown kind or out-of-range field.
pub fn decode(id: u32) ?Decoded {
    const kind_raw: u8 = @truncate(id >> 24);
    const submesh: u16 = @truncate((id >> 8) & 0xFFFF);
    const field: u8 = @truncate(id & 0xFF);

    const kind = enumFromIntChecked(Kind, kind_raw) orelse return null;
    switch (kind) {
        .camera => {
            _ = enumFromIntChecked(CameraField, field) orelse return null;
        },
        .material => {
            _ = enumFromIntChecked(MaterialField, field) orelse return null;
        },
        .model => {
            _ = enumFromIntChecked(ModelField, field) orelse return null;
        },
        .node => {
            _ = enumFromIntChecked(NodeField, field) orelse return null;
        },
        .morph => {
            // field is the morph target index (0–255); all values valid.
        },
    }
    return Decoded{ .kind = kind, .submesh = submesh, .field = field };
}

/// Freestanding-safe checked integer → enum conversion.
/// Returns null when `v` is not a valid tag value.
fn enumFromIntChecked(comptime E: type, v: anytype) ?E {
    const fields = std.meta.fields(E);
    inline for (fields) |f| {
        if (f.value == v) return @enumFromInt(v);
    }
    return null;
}

// ── shared camera/model path parsing (reader-free) ───────────────────────────

/// Resolve camera.* and model.* paths without a name-table lookup.
/// Returns null for anything that requires a reader (material:*, node:*) or is unknown.
fn resolveCameraModel(path: []const u8) ?u32 {
    if (path.len == 0) return null;

    // "camera.<field>"
    if (std.mem.startsWith(u8, path, "camera.")) {
        const field_str = path["camera.".len..];
        if (std.mem.eql(u8, field_str, "yaw")) return encode(.camera, 0, @intFromEnum(CameraField.yaw));
        if (std.mem.eql(u8, field_str, "pitch")) return encode(.camera, 0, @intFromEnum(CameraField.pitch));
        if (std.mem.eql(u8, field_str, "distance")) return encode(.camera, 0, @intFromEnum(CameraField.distance));
        return null;
    }

    // "model.<field>"
    if (std.mem.startsWith(u8, path, "model.")) {
        const field_str = path["model.".len..];
        if (std.mem.eql(u8, field_str, "yaw")) return encode(.model, 0, @intFromEnum(ModelField.yaw));
        return null;
    }

    return null;
}

// ── shared material/node field parsing ────────────────────────────────────────

fn materialField(s: []const u8) ?u8 {
    if (std.mem.eql(u8, s, "metallic")) return @intFromEnum(MaterialField.metallic);
    if (std.mem.eql(u8, s, "roughness")) return @intFromEnum(MaterialField.roughness);
    if (std.mem.eql(u8, s, "emissiveR")) return @intFromEnum(MaterialField.emissive_r);
    if (std.mem.eql(u8, s, "emissiveG")) return @intFromEnum(MaterialField.emissive_g);
    if (std.mem.eql(u8, s, "emissiveB")) return @intFromEnum(MaterialField.emissive_b);
    if (std.mem.eql(u8, s, "baseColorR")) return @intFromEnum(MaterialField.base_color_r);
    if (std.mem.eql(u8, s, "baseColorG")) return @intFromEnum(MaterialField.base_color_g);
    if (std.mem.eql(u8, s, "baseColorB")) return @intFromEnum(MaterialField.base_color_b);
    if (std.mem.eql(u8, s, "baseColorA")) return @intFromEnum(MaterialField.base_color_a);
    return null;
}

fn nodeField(s: []const u8) ?u8 {
    if (std.mem.eql(u8, s, "rotationX")) return @intFromEnum(NodeField.rotation_x);
    if (std.mem.eql(u8, s, "rotationY")) return @intFromEnum(NodeField.rotation_y);
    if (std.mem.eql(u8, s, "rotationZ")) return @intFromEnum(NodeField.rotation_z);
    if (std.mem.eql(u8, s, "translateX")) return @intFromEnum(NodeField.translate_x);
    if (std.mem.eql(u8, s, "translateY")) return @intFromEnum(NodeField.translate_y);
    if (std.mem.eql(u8, s, "translateZ")) return @intFromEnum(NodeField.translate_z);
    if (std.mem.eql(u8, s, "scaleX")) return @intFromEnum(NodeField.scale_x);
    if (std.mem.eql(u8, s, "scaleY")) return @intFromEnum(NodeField.scale_y);
    if (std.mem.eql(u8, s, "scaleZ")) return @intFromEnum(NodeField.scale_z);
    return null;
}

pub const Deferred = struct { kind: Kind, field: u8, name_hash: u32 };

/// Reader-free resolver for SSR material:/node: targets. Parses the field and
/// computes the FNV name hash (both pure); the submesh INDEX is resolved on the
/// client via Reader.findName. Returns null for camera/model (use resolvePathStatic)
/// and for any unknown path/field.
pub fn resolvePathStaticDeferred(path: []const u8) ?Deferred {
    if (std.mem.startsWith(u8, path, "material:")) {
        const rest = path["material:".len..];
        const dot = std.mem.lastIndexOfScalar(u8, rest, '.') orelse return null;
        const f = materialField(rest[dot + 1 ..]) orelse return null;
        return Deferred{ .kind = .material, .field = f, .name_hash = vmesh.Reader.nameHash(rest[0..dot]) };
    }
    if (std.mem.startsWith(u8, path, "node:")) {
        const rest = path["node:".len..];
        const dot = std.mem.lastIndexOfScalar(u8, rest, '.') orelse return null;
        const f = nodeField(rest[dot + 1 ..]) orelse return null;
        return Deferred{ .kind = .node, .field = f, .name_hash = vmesh.Reader.nameHash(rest[0..dot]) };
    }
    return null;
}

// ── resolvePath ───────────────────────────────────────────────────────────────

/// Resolve a frozen path string to a target id.  Call once at setup.
/// Material and node names are looked up through the vmesh v3 name table.
/// Returns null for any unknown path, kind, field, or mesh name.
pub fn resolvePath(reader: *const vmesh.Reader, path: []const u8) ?u32 {
    // Delegate camera/model to shared reader-free helper.
    if (resolveCameraModel(path)) |id| return id;

    // "material:<Name>.<field>"
    if (std.mem.startsWith(u8, path, "material:")) {
        const rest = path["material:".len..];
        // Find the last '.' to split Name from field.
        const dot = std.mem.lastIndexOfScalar(u8, rest, '.') orelse return null;
        const name_str = rest[0..dot];
        const field_str = rest[dot + 1 ..];

        // Resolve material field.
        const mat_field: u8 = materialField(field_str) orelse return null;

        // Look up name in the vmesh name table.
        const hash = vmesh.Reader.nameHash(name_str);
        const submesh_idx = reader.findName(hash) orelse return null;
        const submesh: u16 = @intCast(submesh_idx);
        return encode(.material, submesh, mat_field);
    }

    // "node:<Name>.<field>"
    if (std.mem.startsWith(u8, path, "node:")) {
        const rest = path["node:".len..];
        // Find the last '.' to split Name from field.
        const dot = std.mem.lastIndexOfScalar(u8, rest, '.') orelse return null;
        const name_str = rest[0..dot];
        const field_str = rest[dot + 1 ..];

        // Resolve node field.
        const node_field: u8 = nodeField(field_str) orelse return null;

        // Look up name in the vmesh name table.
        const hash = vmesh.Reader.nameHash(name_str);
        const submesh_idx = reader.findName(hash) orelse return null;
        const submesh: u16 = @intCast(submesh_idx);
        return encode(.node, submesh, node_field);
    }

    // "morph:<index>"  (field = morph target index 0–255; submesh always 0)
    if (std.mem.startsWith(u8, path, "morph:")) {
        const idx_str = path["morph:".len..];
        const idx = std.fmt.parseInt(u8, idx_str, 10) catch return null;
        return encode(.morph, 0, idx);
    }

    return null;
}

// ── resolvePathStatic ─────────────────────────────────────────────────────────

/// Reader-free resolver for SSR.  Handles ONLY camera.* and model.* paths.
/// material:*, node:*, and unknowns → null.
pub fn resolvePathStatic(path: []const u8) ?u32 {
    return resolveCameraModel(path);
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

// ── (a) encode/decode round-trip ─────────────────────────────────────────────

test "(a) encode/decode round-trip: camera fields" {
    const cases = [_]struct { kind: Kind, sub: u16, field: u8 }{
        .{ .kind = .camera, .sub = 0, .field = @intFromEnum(CameraField.yaw) },
        .{ .kind = .camera, .sub = 0, .field = @intFromEnum(CameraField.pitch) },
        .{ .kind = .camera, .sub = 0, .field = @intFromEnum(CameraField.distance) },
    };
    for (cases) |c| {
        const id = encode(c.kind, c.sub, c.field);
        const d = decode(id) orelse return error.TestUnexpectedNull;
        try testing.expectEqual(c.kind, d.kind);
        try testing.expectEqual(c.sub, d.submesh);
        try testing.expectEqual(c.field, d.field);
    }
}

test "(a) encode/decode round-trip: material fields + submesh indices" {
    const submeshes = [_]u16{ 0, 1, 0xFFFF };
    const fields = [_]u8{
        @intFromEnum(MaterialField.metallic),
        @intFromEnum(MaterialField.roughness),
    };
    for (submeshes) |sub| {
        for (fields) |f| {
            const id = encode(.material, sub, f);
            const d = decode(id) orelse return error.TestUnexpectedNull;
            try testing.expectEqual(Kind.material, d.kind);
            try testing.expectEqual(sub, d.submesh);
            try testing.expectEqual(f, d.field);
        }
    }
}

test "(a) encode/decode round-trip: model yaw" {
    const id = encode(.model, 0, @intFromEnum(ModelField.yaw));
    const d = decode(id) orelse return error.TestUnexpectedNull;
    try testing.expectEqual(Kind.model, d.kind);
    try testing.expectEqual(@as(u16, 0), d.submesh);
    try testing.expectEqual(@as(u8, 0), d.field);
}

test "(a) encode/decode round-trip: node rotation fields + submesh indices" {
    const submeshes = [_]u16{ 0, 1, 0xFFFF };
    const fields = [_]u8{
        @intFromEnum(NodeField.rotation_x),
        @intFromEnum(NodeField.rotation_y),
        @intFromEnum(NodeField.rotation_z),
    };
    for (submeshes) |sub| {
        for (fields) |f| {
            const id = encode(.node, sub, f);
            const d = decode(id) orelse return error.TestUnexpectedNull;
            try testing.expectEqual(Kind.node, d.kind);
            try testing.expectEqual(sub, d.submesh);
            try testing.expectEqual(f, d.field);
        }
    }
}

test "(a) encode/decode round-trip: material emissive fields" {
    const submeshes = [_]u16{ 0, 1, 0xFFFF };
    const fields = [_]u8{
        @intFromEnum(MaterialField.emissive_r),
        @intFromEnum(MaterialField.emissive_g),
        @intFromEnum(MaterialField.emissive_b),
    };
    for (submeshes) |sub| {
        for (fields) |f| {
            const id = encode(.material, sub, f);
            const d = decode(id) orelse return error.TestUnexpectedNull;
            try testing.expectEqual(Kind.material, d.kind);
            try testing.expectEqual(sub, d.submesh);
            try testing.expectEqual(f, d.field);
        }
    }
}

// ── (b) decode rejects invalid ids ───────────────────────────────────────────

test "(b) decode rejects kind 5" {
    // kind=5 is unknown (0–4 are now valid: camera/material/model/node/morph)
    const id: u32 = (5 << 24) | 0;
    try testing.expectEqual(@as(?Decoded, null), decode(id));
}

test "(b) decode accepts morph kind 4" {
    // kind=4 is morph; field is an arbitrary target index (0–255)
    const id = encode(.morph, 0, 3);
    const d = decode(id) orelse return error.TestUnexpectedNull;
    try testing.expectEqual(Kind.morph, d.kind);
    try testing.expectEqual(@as(u16, 0), d.submesh);
    try testing.expectEqual(@as(u8, 3), d.field);
}

test "(b) decode rejects camera field 3" {
    const id = encode(.camera, 0, 3);
    try testing.expectEqual(@as(?Decoded, null), decode(id));
}

test "(b) decode rejects material field 9" {
    const id = encode(.material, 0, 9);
    try testing.expectEqual(@as(?Decoded, null), decode(id));
}

test "(b) decode rejects model field 1" {
    const id = encode(.model, 0, 1);
    try testing.expectEqual(@as(?Decoded, null), decode(id));
}

test "(b) decode rejects node field 9" {
    const id = encode(.node, 0, 9);
    try testing.expectEqual(@as(?Decoded, null), decode(id));
}

// ── (c) resolvePath against real fixture Reader ───────────────────────────────

/// Build a vmesh Reader from pbrCubeGlb → gltf.parse → vmesh.pack (with names).
fn makeFixtureReader(alloc: std.mem.Allocator) !struct {
    bytes: []u8,
    reader: vmesh.Reader,
} {
    const gltf = @import("gltf.zig");
    const fixture = @import("fixture.zig");
    const vmesh_mod = @import("vmesh.zig");

    const glb = try fixture.pbrCubeGlb(alloc, .{ .with_tangents = true });
    defer alloc.free(glb);

    var model = try gltf.parseGlb(alloc, glb);
    defer model.deinit();

    const bytes = try vmesh_mod.pack(
        alloc,
        model.vertices,
        model.indices,
        model.submeshes,
        model.textures,
        &.{}, // no BVH
        &.{},
        model.names,
        false,
        &.{},
        &.{},
        &.{},
        null,
        &.{},
        0,
        null,
        null,
    );
    const reader = try vmesh_mod.Reader.init(bytes);
    return .{ .bytes = bytes, .reader = reader };
}

test "(c) resolvePath camera.yaw" {
    const fr = try makeFixtureReader(testing.allocator);
    defer testing.allocator.free(fr.bytes);
    const id = resolvePath(&fr.reader, "camera.yaw") orelse return error.TestUnexpectedNull;
    try testing.expectEqual(encode(.camera, 0, @intFromEnum(CameraField.yaw)), id);
}

test "(c) resolvePath camera.distance" {
    const fr = try makeFixtureReader(testing.allocator);
    defer testing.allocator.free(fr.bytes);
    const id = resolvePath(&fr.reader, "camera.distance") orelse return error.TestUnexpectedNull;
    try testing.expectEqual(encode(.camera, 0, @intFromEnum(CameraField.distance)), id);
}

test "(c) resolvePath material:Cube.roughness" {
    const fr = try makeFixtureReader(testing.allocator);
    defer testing.allocator.free(fr.bytes);
    const id = resolvePath(&fr.reader, "material:Cube.roughness") orelse return error.TestUnexpectedNull;
    try testing.expectEqual(encode(.material, 0, @intFromEnum(MaterialField.roughness)), id);
}

test "(c) resolvePath material:Cube.metallic" {
    const fr = try makeFixtureReader(testing.allocator);
    defer testing.allocator.free(fr.bytes);
    const id = resolvePath(&fr.reader, "material:Cube.metallic") orelse return error.TestUnexpectedNull;
    try testing.expectEqual(encode(.material, 0, @intFromEnum(MaterialField.metallic)), id);
}

test "(c) resolvePath model.yaw" {
    const fr = try makeFixtureReader(testing.allocator);
    defer testing.allocator.free(fr.bytes);
    const id = resolvePath(&fr.reader, "model.yaw") orelse return error.TestUnexpectedNull;
    try testing.expectEqual(encode(.model, 0, @intFromEnum(ModelField.yaw)), id);
}

test "(c) resolvePath node:Cube.rotationY" {
    const fr = try makeFixtureReader(testing.allocator);
    defer testing.allocator.free(fr.bytes);
    const id = resolvePath(&fr.reader, "node:Cube.rotationY") orelse return error.TestUnexpectedNull;
    try testing.expectEqual(encode(.node, 0, @intFromEnum(NodeField.rotation_y)), id);
}

test "(c) resolvePath material:Cube.emissiveG" {
    const fr = try makeFixtureReader(testing.allocator);
    defer testing.allocator.free(fr.bytes);
    const id = resolvePath(&fr.reader, "material:Cube.emissiveG") orelse return error.TestUnexpectedNull;
    try testing.expectEqual(encode(.material, 0, @intFromEnum(MaterialField.emissive_g)), id);
}

// ── (d) unknown paths → null ──────────────────────────────────────────────────

test "(d) unknown paths return null" {
    const fr = try makeFixtureReader(testing.allocator);
    defer testing.allocator.free(fr.bytes);
    const unknowns = [_][]const u8{
        "camera.zoom",
        "material:Nope.roughness",
        "material:Cube.shininess",
        "node:Cube.rotationW",
        "node:Nope.rotationX",
        "material:Cube.emissiveA",
        "banana",
        "",
    };
    for (unknowns) |p| {
        try testing.expectEqual(@as(?u32, null), resolvePath(&fr.reader, p));
    }
}

// ── (e) camera/model paths work with zero-name reader ────────────────────────

test "(e) camera/model paths work with zero-name reader" {
    const vmesh_mod = @import("vmesh.zig");
    // Minimal geometry: 1 triangle, no names.
    const verts = [_]f32{0} ** 12;
    const idx = [_]u16{ 0, 0, 0 };
    const bytes = try vmesh_mod.pack(
        testing.allocator,
        &verts,
        &idx,
        &.{},
        &.{},
        &.{},
        &.{},
        &.{}, // empty names
        false,
        &.{},
        &.{},
        &.{},
        null,
        &.{},
        0,
        null,
        null,
    );
    defer testing.allocator.free(bytes);
    const reader = try vmesh_mod.Reader.init(bytes);
    try testing.expectEqual(@as(u32, 0), reader.name_count);

    const cam_yaw = resolvePath(&reader, "camera.yaw") orelse return error.TestUnexpectedNull;
    try testing.expectEqual(encode(.camera, 0, @intFromEnum(CameraField.yaw)), cam_yaw);

    const cam_pitch = resolvePath(&reader, "camera.pitch") orelse return error.TestUnexpectedNull;
    try testing.expectEqual(encode(.camera, 0, @intFromEnum(CameraField.pitch)), cam_pitch);

    const cam_dist = resolvePath(&reader, "camera.distance") orelse return error.TestUnexpectedNull;
    try testing.expectEqual(encode(.camera, 0, @intFromEnum(CameraField.distance)), cam_dist);

    const mod_yaw = resolvePath(&reader, "model.yaw") orelse return error.TestUnexpectedNull;
    try testing.expectEqual(encode(.model, 0, @intFromEnum(ModelField.yaw)), mod_yaw);
}

// ── (f) resolvePathStatic ─────────────────────────────────────────────────────

test "(f) resolvePathStatic equals resolvePath for camera.* and model.yaw" {
    const vmesh_mod = @import("vmesh.zig");
    const verts = [_]f32{0} ** 12;
    const idx = [_]u16{ 0, 0, 0 };
    const bytes = try vmesh_mod.pack(
        testing.allocator,
        &verts,
        &idx,
        &.{},
        &.{},
        &.{},
        &.{},
        &.{},
        false,
        &.{},
        &.{},
        &.{},
        null,
        &.{},
        0,
        null,
        null,
    );
    defer testing.allocator.free(bytes);
    const reader = try vmesh_mod.Reader.init(bytes);

    const paths = [_][]const u8{
        "camera.yaw",
        "camera.pitch",
        "camera.distance",
        "model.yaw",
    };
    for (paths) |p| {
        const from_reader = resolvePath(&reader, p) orelse return error.TestUnexpectedNull;
        const from_static = resolvePathStatic(p) orelse return error.TestUnexpectedNull;
        try testing.expectEqual(from_reader, from_static);
    }

    // Explicit value checks against encode().
    try testing.expectEqual(encode(.camera, 0, @intFromEnum(CameraField.yaw)), resolvePathStatic("camera.yaw").?);
    try testing.expectEqual(encode(.camera, 0, @intFromEnum(CameraField.pitch)), resolvePathStatic("camera.pitch").?);
    try testing.expectEqual(encode(.camera, 0, @intFromEnum(CameraField.distance)), resolvePathStatic("camera.distance").?);
    try testing.expectEqual(encode(.model, 0, @intFromEnum(ModelField.yaw)), resolvePathStatic("model.yaw").?);
}

test "(f) resolvePathStatic returns null for material:*, node:*, and unknowns" {
    const nulls = [_][]const u8{
        "material:Cube.roughness",
        "node:Cube.rotationX",
        "banana",
        "",
    };
    for (nulls) |p| {
        try testing.expectEqual(@as(?u32, null), resolvePathStatic(p));
    }
}

// ── (g) frozen-id regression ──────────────────────────────────────────────────

test "(g) frozen-id regression: pre-P6 ids byte-identical" {
    // These literals are the frozen contract.  Any encoding drift breaks them.
    //
    // Pre-P6 ids (kind bits [31:24], submesh bits [23:8], field bits [7:0]):
    //   camera.yaw      kind=0x00 submesh=0x0000 field=0x00 → 0x00000000
    //   camera.pitch    kind=0x00 submesh=0x0000 field=0x01 → 0x00000001
    //   camera.distance kind=0x00 submesh=0x0000 field=0x02 → 0x00000002
    //   model.yaw       kind=0x02 submesh=0x0000 field=0x00 → 0x02000000
    //   material:Cube.metallic  (submesh 0) kind=0x01 submesh=0x0000 field=0x00 → 0x01000000
    //   material:Cube.roughness (submesh 0) kind=0x01 submesh=0x0000 field=0x01 → 0x01000001

    try testing.expectEqual(@as(u32, 0x00000000), encode(.camera, 0, @intFromEnum(CameraField.yaw)));
    try testing.expectEqual(@as(u32, 0x00000001), encode(.camera, 0, @intFromEnum(CameraField.pitch)));
    try testing.expectEqual(@as(u32, 0x00000002), encode(.camera, 0, @intFromEnum(CameraField.distance)));
    try testing.expectEqual(@as(u32, 0x02000000), encode(.model, 0, @intFromEnum(ModelField.yaw)));
    try testing.expectEqual(@as(u32, 0x01000000), encode(.material, 0, @intFromEnum(MaterialField.metallic)));
    try testing.expectEqual(@as(u32, 0x01000001), encode(.material, 0, @intFromEnum(MaterialField.roughness)));
}

test "(g) frozen-id regression: new P6 ids" {
    // New P6 ids:
    //   node:Cube.rotationX (submesh 0) kind=0x03 submesh=0x0000 field=0x00 → 0x03000000
    //   node:Cube.rotationY (submesh 0) kind=0x03 submesh=0x0000 field=0x01 → 0x03000001
    //   node:Cube.rotationZ (submesh 0) kind=0x03 submesh=0x0000 field=0x02 → 0x03000002
    //   material:Cube.emissiveR (submesh 0) kind=0x01 submesh=0x0000 field=0x02 → 0x01000002
    //   material:Cube.emissiveG (submesh 0) kind=0x01 submesh=0x0000 field=0x03 → 0x01000003
    //   material:Cube.emissiveB (submesh 0) kind=0x01 submesh=0x0000 field=0x04 → 0x01000004

    try testing.expectEqual(@as(u32, 0x03000000), encode(.node, 0, @intFromEnum(NodeField.rotation_x)));
    try testing.expectEqual(@as(u32, 0x03000001), encode(.node, 0, @intFromEnum(NodeField.rotation_y)));
    try testing.expectEqual(@as(u32, 0x03000002), encode(.node, 0, @intFromEnum(NodeField.rotation_z)));
    try testing.expectEqual(@as(u32, 0x01000002), encode(.material, 0, @intFromEnum(MaterialField.emissive_r)));
    try testing.expectEqual(@as(u32, 0x01000003), encode(.material, 0, @intFromEnum(MaterialField.emissive_g)));
    try testing.expectEqual(@as(u32, 0x01000004), encode(.material, 0, @intFromEnum(MaterialField.emissive_b)));
}

test "(g) frozen-id regression: resolvePath pre-P6 paths via fixture reader" {
    const fr = try makeFixtureReader(testing.allocator);
    defer testing.allocator.free(fr.bytes);

    try testing.expectEqual(@as(?u32, 0x00000000), resolvePath(&fr.reader, "camera.yaw"));
    try testing.expectEqual(@as(?u32, 0x00000001), resolvePath(&fr.reader, "camera.pitch"));
    try testing.expectEqual(@as(?u32, 0x00000002), resolvePath(&fr.reader, "camera.distance"));
    try testing.expectEqual(@as(?u32, 0x02000000), resolvePath(&fr.reader, "model.yaw"));
    try testing.expectEqual(@as(?u32, 0x01000000), resolvePath(&fr.reader, "material:Cube.metallic"));
    try testing.expectEqual(@as(?u32, 0x01000001), resolvePath(&fr.reader, "material:Cube.roughness"));
}

test "(g) frozen-id regression: resolvePath new P6 paths via fixture reader" {
    const fr = try makeFixtureReader(testing.allocator);
    defer testing.allocator.free(fr.bytes);

    try testing.expectEqual(@as(?u32, 0x03000000), resolvePath(&fr.reader, "node:Cube.rotationX"));
    try testing.expectEqual(@as(?u32, 0x03000001), resolvePath(&fr.reader, "node:Cube.rotationY"));
    try testing.expectEqual(@as(?u32, 0x03000002), resolvePath(&fr.reader, "node:Cube.rotationZ"));
    try testing.expectEqual(@as(?u32, 0x01000002), resolvePath(&fr.reader, "material:Cube.emissiveR"));
    try testing.expectEqual(@as(?u32, 0x01000003), resolvePath(&fr.reader, "material:Cube.emissiveG"));
    try testing.expectEqual(@as(?u32, 0x01000004), resolvePath(&fr.reader, "material:Cube.emissiveB"));
}

// ── (h) resolvePathStaticDeferred (reader-free material:/node:) ───────────────

test "(h) resolvePathStaticDeferred: material/node carry kind+field+hash" {
    const m = resolvePathStaticDeferred("material:Cube.roughness") orelse return error.TestUnexpectedNull;
    try testing.expectEqual(Kind.material, m.kind);
    try testing.expectEqual(@as(u8, @intFromEnum(MaterialField.roughness)), m.field);
    try testing.expectEqual(vmesh.Reader.nameHash("Cube"), m.name_hash);

    const e = resolvePathStaticDeferred("material:Cube.emissiveG") orelse return error.TestUnexpectedNull;
    try testing.expectEqual(@as(u8, @intFromEnum(MaterialField.emissive_g)), e.field);

    const n = resolvePathStaticDeferred("node:rotor1.rotationZ") orelse return error.TestUnexpectedNull;
    try testing.expectEqual(Kind.node, n.kind);
    try testing.expectEqual(@as(u8, @intFromEnum(NodeField.rotation_z)), n.field);
    try testing.expectEqual(vmesh.Reader.nameHash("rotor1"), n.name_hash);
}

test "(h) resolvePathStaticDeferred: camera/model/unknown → null" {
    const nulls = [_][]const u8{
        "camera.yaw",          "model.yaw",     "material:Cube.bogus",
        "node:Cube.rotationW", "material:Cube", "banana",
        "",
    };
    for (nulls) |p| try testing.expectEqual(@as(?Deferred, null), resolvePathStaticDeferred(p));
}

test "(h) resolvePathStaticDeferred is comptime-evaluable" {
    const d = comptime resolvePathStaticDeferred("material:Cube.roughness").?;
    try testing.expectEqual(Kind.material, d.kind);
}

test "(h) resolvePathStaticDeferred: node translate/scale carry kind+field+hash" {
    const tx = resolvePathStaticDeferred("node:rotor1.translateX") orelse return error.TestUnexpectedNull;
    try testing.expectEqual(Kind.node, tx.kind);
    try testing.expectEqual(@as(u8, @intFromEnum(NodeField.translate_x)), tx.field);
    try testing.expectEqual(vmesh.Reader.nameHash("rotor1"), tx.name_hash);

    const sy = resolvePathStaticDeferred("node:rotor1.scaleY") orelse return error.TestUnexpectedNull;
    try testing.expectEqual(@as(u8, @intFromEnum(NodeField.scale_y)), sy.field);

    const tz = resolvePathStaticDeferred("node:rotor1.translateZ") orelse return error.TestUnexpectedNull;
    try testing.expectEqual(@as(u8, @intFromEnum(NodeField.translate_z)), tz.field);
}

test "(c) resolvePath node:Cube.translateY / scaleX via fixture reader" {
    const fr = try makeFixtureReader(testing.allocator);
    defer testing.allocator.free(fr.bytes);
    try testing.expectEqual(
        encode(.node, 0, @intFromEnum(NodeField.translate_y)),
        resolvePath(&fr.reader, "node:Cube.translateY") orelse return error.TestUnexpectedNull,
    );
    try testing.expectEqual(
        encode(.node, 0, @intFromEnum(NodeField.scale_x)),
        resolvePath(&fr.reader, "node:Cube.scaleX") orelse return error.TestUnexpectedNull,
    );
}

test "(g) frozen-id regression: node translate/scale ids" {
    // node kind=0x03, submesh 0:
    //   translateX/Y/Z field 3/4/5 → 0x03000003 / 04 / 05
    //   scaleX/Y/Z     field 6/7/8 → 0x03000006 / 07 / 08
    try testing.expectEqual(@as(u32, 0x03000003), encode(.node, 0, @intFromEnum(NodeField.translate_x)));
    try testing.expectEqual(@as(u32, 0x03000004), encode(.node, 0, @intFromEnum(NodeField.translate_y)));
    try testing.expectEqual(@as(u32, 0x03000005), encode(.node, 0, @intFromEnum(NodeField.translate_z)));
    try testing.expectEqual(@as(u32, 0x03000006), encode(.node, 0, @intFromEnum(NodeField.scale_x)));
    try testing.expectEqual(@as(u32, 0x03000007), encode(.node, 0, @intFromEnum(NodeField.scale_y)));
    try testing.expectEqual(@as(u32, 0x03000008), encode(.node, 0, @intFromEnum(NodeField.scale_z)));
}

test "(h) resolvePathStaticDeferred: material baseColor carries kind+field+hash" {
    const r = resolvePathStaticDeferred("material:Cube.baseColorR") orelse return error.TestUnexpectedNull;
    try testing.expectEqual(Kind.material, r.kind);
    try testing.expectEqual(@as(u8, @intFromEnum(MaterialField.base_color_r)), r.field);
    try testing.expectEqual(vmesh.Reader.nameHash("Cube"), r.name_hash);

    const b = resolvePathStaticDeferred("material:Cube.baseColorB") orelse return error.TestUnexpectedNull;
    try testing.expectEqual(@as(u8, @intFromEnum(MaterialField.base_color_b)), b.field);
}

test "(c) resolvePath material:Cube.baseColorR / baseColorG via fixture reader" {
    const fr = try makeFixtureReader(testing.allocator);
    defer testing.allocator.free(fr.bytes);
    try testing.expectEqual(
        encode(.material, 0, @intFromEnum(MaterialField.base_color_r)),
        resolvePath(&fr.reader, "material:Cube.baseColorR") orelse return error.TestUnexpectedNull,
    );
    try testing.expectEqual(
        encode(.material, 0, @intFromEnum(MaterialField.base_color_g)),
        resolvePath(&fr.reader, "material:Cube.baseColorG") orelse return error.TestUnexpectedNull,
    );
}

test "(g) frozen-id regression: material baseColor ids" {
    // material kind=0x01, submesh 0: baseColorR/G/B field 5/6/7 → 0x01000005 / 06 / 07
    try testing.expectEqual(@as(u32, 0x01000005), encode(.material, 0, @intFromEnum(MaterialField.base_color_r)));
    try testing.expectEqual(@as(u32, 0x01000006), encode(.material, 0, @intFromEnum(MaterialField.base_color_g)));
    try testing.expectEqual(@as(u32, 0x01000007), encode(.material, 0, @intFromEnum(MaterialField.base_color_b)));
}

test "(h) resolvePathStaticDeferred: material baseColorA carries kind+field+hash" {
    const r = resolvePathStaticDeferred("material:Cube.baseColorA") orelse return error.TestUnexpectedNull;
    try testing.expectEqual(Kind.material, r.kind);
    try testing.expectEqual(@as(u8, @intFromEnum(MaterialField.base_color_a)), r.field);
    try testing.expectEqual(vmesh.Reader.nameHash("Cube"), r.name_hash);
}

test "(c) resolvePath material:Cube.baseColorA via fixture reader" {
    const fr = try makeFixtureReader(testing.allocator);
    defer testing.allocator.free(fr.bytes);
    try testing.expectEqual(
        encode(.material, 0, @intFromEnum(MaterialField.base_color_a)),
        resolvePath(&fr.reader, "material:Cube.baseColorA") orelse return error.TestUnexpectedNull,
    );
}

test "(g) frozen-id regression: material baseColorA id" {
    try testing.expectEqual(@as(u32, 0x01000008), encode(.material, 0, @intFromEnum(MaterialField.base_color_a)));
}

// ── (i) morph target ─────────────────────────────────────────────────────────

test "(i) resolvePath morph:3 returns encode(.morph, 0, 3)" {
    const fr = try makeFixtureReader(testing.allocator);
    defer testing.allocator.free(fr.bytes);
    const id = resolvePath(&fr.reader, "morph:3") orelse return error.TestUnexpectedNull;
    try testing.expectEqual(encode(.morph, 0, 3), id);
}

test "(i) resolvePath morph:0 round-trip decode kind=morph field=0" {
    const fr = try makeFixtureReader(testing.allocator);
    defer testing.allocator.free(fr.bytes);
    const id = resolvePath(&fr.reader, "morph:0") orelse return error.TestUnexpectedNull;
    const d = decode(id) orelse return error.TestUnexpectedNull;
    try testing.expectEqual(Kind.morph, d.kind);
    try testing.expectEqual(@as(u16, 0), d.submesh);
    try testing.expectEqual(@as(u8, 0), d.field);
}

test "(i) frozen-id regression: morph:0 = 0x04000000, morph:3 = 0x04000003" {
    // morph kind=0x04, submesh=0x0000, field=index
    try testing.expectEqual(@as(u32, 0x04000000), encode(.morph, 0, 0));
    try testing.expectEqual(@as(u32, 0x04000003), encode(.morph, 0, 3));
}

test "(i) resolvePath morph: unknown / bad index → null" {
    const fr = try makeFixtureReader(testing.allocator);
    defer testing.allocator.free(fr.bytes);
    // "morph:" with no digits or non-numeric → null
    try testing.expectEqual(@as(?u32, null), resolvePath(&fr.reader, "morph:"));
    try testing.expectEqual(@as(?u32, null), resolvePath(&fr.reader, "morph:abc"));
    // index > 255 → null (u8 parse overflow)
    try testing.expectEqual(@as(?u32, null), resolvePath(&fr.reader, "morph:256"));
}
