//! anim_target — frozen target-id encoding for verve.gl animations.
//!
//! Target id u32:
//!   bits [31:24]  kind     (0=camera, 1=material, 2=model)
//!   bits [23:8]   submesh  (material only; 0 otherwise)
//!   bits [7:0]    field
//!
//! Fields:
//!   camera   yaw=0  pitch=1  distance=2
//!   material metallic=0  roughness=1
//!   model    yaw=0
//!
//! Path grammar (resolve once at setup via resolvePath):
//!   "camera.yaw" | "camera.pitch" | "camera.distance"
//!   "material:<Name>.metallic" | "material:<Name>.roughness"
//!   "model.yaw"
//!
//! Freestanding-safe: std.mem only (runs in wasm32 island chunks).

const std = @import("std");
const vmesh = @import("vmesh.zig");

// ── enumerations ──────────────────────────────────────────────────────────────

pub const Kind = enum(u8) { camera = 0, material = 1, model = 2 };
pub const CameraField = enum(u8) { yaw = 0, pitch = 1, distance = 2 };
pub const MaterialField = enum(u8) { metallic = 0, roughness = 1 };
pub const ModelField = enum(u8) { yaw = 0 };

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

// ── resolvePath ───────────────────────────────────────────────────────────────

/// Resolve a frozen path string to a target id.  Call once at setup.
/// Material names are looked up through the vmesh v3 name table.
/// Returns null for any unknown path, kind, field, or mesh name.
pub fn resolvePath(reader: *const vmesh.Reader, path: []const u8) ?u32 {
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

    // "material:<Name>.<field>"
    if (std.mem.startsWith(u8, path, "material:")) {
        const rest = path["material:".len..];
        // Find the last '.' to split Name from field.
        const dot = std.mem.lastIndexOfScalar(u8, rest, '.') orelse return null;
        const name_str = rest[0..dot];
        const field_str = rest[dot + 1 ..];

        // Resolve material field.
        const mat_field: u8 = blk: {
            if (std.mem.eql(u8, field_str, "metallic")) break :blk @intFromEnum(MaterialField.metallic);
            if (std.mem.eql(u8, field_str, "roughness")) break :blk @intFromEnum(MaterialField.roughness);
            return null;
        };

        // Look up name in the vmesh name table.
        const hash = vmesh.Reader.nameHash(name_str);
        const submesh_idx = reader.findName(hash) orelse return null;
        const submesh: u16 = @intCast(submesh_idx);
        return encode(.material, submesh, mat_field);
    }

    return null;
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

// ── (b) decode rejects invalid ids ───────────────────────────────────────────

test "(b) decode rejects kind 3" {
    // kind=3 is unknown
    const id: u32 = (3 << 24) | 0;
    try testing.expectEqual(@as(?Decoded, null), decode(id));
}

test "(b) decode rejects camera field 3" {
    const id = encode(.camera, 0, 3);
    try testing.expectEqual(@as(?Decoded, null), decode(id));
}

test "(b) decode rejects material field 2" {
    const id = encode(.material, 0, 2);
    try testing.expectEqual(@as(?Decoded, null), decode(id));
}

test "(b) decode rejects model field 1" {
    const id = encode(.model, 0, 1);
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

// ── (d) unknown paths → null ──────────────────────────────────────────────────

test "(d) unknown paths return null" {
    const fr = try makeFixtureReader(testing.allocator);
    defer testing.allocator.free(fr.bytes);
    const unknowns = [_][]const u8{
        "camera.zoom",
        "material:Nope.roughness",
        "material:Cube.shininess",
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
