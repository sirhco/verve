//! GPU resource registry — records every CREATE_* a chunk issues so the full
//! resource set can be re-emitted after a WebGL context restore.
//!
//! Fixed capacity (comptime `cap`), freestanding-safe — no allocator.
//! Chunks embed one as a static field; pointers stored here must remain
//! valid for the page lifetime (asset-region bytes + chunk statics satisfy
//! this requirement).
//!
//! Capacity exhaustion: the excess record is *dropped* and `overflowed()`
//! returns true. Size `cap` generously — a dropped record means that GPU
//! resource silently won't survive a context restore.

const command = @import("command.zig");
const std = @import("std");

const Tag = enum(u4) {
    buffer,
    shader,
    texture,
    texture_ex,
};

/// Discriminated union payload for a single recorded CREATE_* call.
const Record = union(Tag) {
    buffer: struct {
        handle: u32,
        kind: command.BufferKind,
        ptr: u32,
        byte_len: u32,
    },
    shader: struct {
        handle: u32,
        variant: u32,
        vs_ptr: u32,
        vs_len: u32,
        fs_ptr: u32,
        fs_len: u32,
    },
    texture: struct {
        handle: u32,
        width: u32,
        height: u32,
        ptr: u32,
        byte_len: u32,
    },
    texture_ex: struct {
        handle: u32,
        target: command.TexTarget,
        format: command.TexFormat,
        width: u32,
        height: u32,
        mip_count: u32,
        ptr: u32,
        byte_len: u32,
    },
};

/// Fixed-capacity GPU resource registry.
///
/// `cap` — maximum number of CREATE_* calls to record. Size this
/// generously: a record that doesn't fit is silently dropped, and the
/// corresponding resource will not survive a WebGL context restore.
pub fn Registry(comptime cap: usize) type {
    return struct {
        const Self = @This();

        records: [cap]Record = undefined,
        _count: usize = 0,
        _overflowed: bool = false,

        /// Discard all recorded resources. After this call `count()==0`
        /// and `overflowed()==false`.
        pub fn reset(self: *Self) void {
            self._count = 0;
            self._overflowed = false;
        }

        /// Record a `Encoder.createBuffer` call.
        pub fn recordBuffer(
            self: *Self,
            handle: u32,
            kind: command.BufferKind,
            ptr: u32,
            byte_len: u32,
        ) void {
            if (self._count >= cap) {
                self._overflowed = true;
                return;
            }
            self.records[self._count] = .{ .buffer = .{
                .handle = handle,
                .kind = kind,
                .ptr = ptr,
                .byte_len = byte_len,
            } };
            self._count += 1;
        }

        /// Record a `Encoder.createShader` call.
        pub fn recordShader(
            self: *Self,
            handle: u32,
            variant: u32,
            vs_ptr: u32,
            vs_len: u32,
            fs_ptr: u32,
            fs_len: u32,
        ) void {
            if (self._count >= cap) {
                self._overflowed = true;
                return;
            }
            self.records[self._count] = .{ .shader = .{
                .handle = handle,
                .variant = variant,
                .vs_ptr = vs_ptr,
                .vs_len = vs_len,
                .fs_ptr = fs_ptr,
                .fs_len = fs_len,
            } };
            self._count += 1;
        }

        /// Record a `Encoder.createTexture` call.
        pub fn recordTexture(
            self: *Self,
            handle: u32,
            width: u32,
            height: u32,
            ptr: u32,
            byte_len: u32,
        ) void {
            if (self._count >= cap) {
                self._overflowed = true;
                return;
            }
            self.records[self._count] = .{ .texture = .{
                .handle = handle,
                .width = width,
                .height = height,
                .ptr = ptr,
                .byte_len = byte_len,
            } };
            self._count += 1;
        }

        /// Record a `Encoder.createTextureEx` call.
        pub fn recordTextureEx(
            self: *Self,
            handle: u32,
            target: command.TexTarget,
            format: command.TexFormat,
            width: u32,
            height: u32,
            mip_count: u32,
            ptr: u32,
            byte_len: u32,
        ) void {
            if (self._count >= cap) {
                self._overflowed = true;
                return;
            }
            self.records[self._count] = .{ .texture_ex = .{
                .handle = handle,
                .target = target,
                .format = format,
                .width = width,
                .height = height,
                .mip_count = mip_count,
                .ptr = ptr,
                .byte_len = byte_len,
            } };
            self._count += 1;
        }

        /// Re-emit every recorded CREATE_* into `enc` in record order.
        /// Call this on context restore before replaying frame commands.
        pub fn replay(self: *const Self, enc: *command.Encoder) void {
            for (self.records[0..self._count]) |rec| {
                switch (rec) {
                    .buffer => |b| enc.createBuffer(b.handle, b.kind, b.ptr, b.byte_len),
                    .shader => |s| enc.createShader(s.handle, s.variant, s.vs_ptr, s.vs_len, s.fs_ptr, s.fs_len),
                    .texture => |t| enc.createTexture(t.handle, t.width, t.height, t.ptr, t.byte_len),
                    .texture_ex => |x| enc.createTextureEx(x.handle, x.target, x.format, x.width, x.height, x.mip_count, x.ptr, x.byte_len),
                }
            }
        }

        /// Number of successfully recorded resources.
        pub fn count(self: *const Self) usize {
            return self._count;
        }

        /// True if at least one record was dropped due to capacity exhaustion.
        /// Log once on context restore so the chunk can warn the developer.
        pub fn overflowed(self: *const Self) bool {
            return self._overflowed;
        }
    };
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "replay matches direct encode — one of each resource type" {
    // Encoder A: populated via Registry.replay
    var reg = Registry(16){};
    reg.recordBuffer(1, .vertex, 0x1000, 192);
    reg.recordShader(2, 1, 0x4000, 256, 0x5000, 128);
    reg.recordTexture(3, 8, 8, 0x6000, 256);
    reg.recordTextureEx(4, .cube, .rgba16f, 128, 128, 6, 0x8000, 0x100000);

    var buf_a: [512]u8 = undefined;
    var enc_a = command.Encoder.init(&buf_a);
    reg.replay(&enc_a);
    const stream_a = enc_a.finish();

    // Encoder B: direct encode with identical args
    var buf_b: [512]u8 = undefined;
    var enc_b = command.Encoder.init(&buf_b);
    enc_b.createBuffer(1, .vertex, 0x1000, 192);
    enc_b.createShader(2, 1, 0x4000, 256, 0x5000, 128);
    enc_b.createTexture(3, 8, 8, 0x6000, 256);
    enc_b.createTextureEx(4, .cube, .rgba16f, 128, 128, 6, 0x8000, 0x100000);
    const stream_b = enc_b.finish();

    try testing.expectEqualSlices(u8, stream_b, stream_a);
}

test "replay preserves record order" {
    // Record texture first, then buffer — replay must emit in that order.
    var reg = Registry(8){};
    reg.recordTexture(10, 4, 4, 0xA000, 64);
    reg.recordBuffer(20, .index, 0xB000, 48);

    var buf_a: [256]u8 = undefined;
    var enc_a = command.Encoder.init(&buf_a);
    reg.replay(&enc_a);
    const stream_a = enc_a.finish();

    var buf_b: [256]u8 = undefined;
    var enc_b = command.Encoder.init(&buf_b);
    enc_b.createTexture(10, 4, 4, 0xA000, 64);
    enc_b.createBuffer(20, .index, 0xB000, 48);
    const stream_b = enc_b.finish();

    try testing.expectEqualSlices(u8, stream_b, stream_a);
}

test "capacity overflow: count==cap, overflowed==true, replay emits cap entries" {
    var reg = Registry(2){};
    reg.recordBuffer(1, .vertex, 0x1000, 64);
    reg.recordBuffer(2, .index, 0x2000, 32);
    // Third record must be dropped.
    reg.recordBuffer(3, .vertex, 0x3000, 16);

    try testing.expectEqual(@as(usize, 2), reg.count());
    try testing.expect(reg.overflowed());

    // Replay must emit exactly the 2 that fit.
    var buf_a: [256]u8 = undefined;
    var enc_a = command.Encoder.init(&buf_a);
    reg.replay(&enc_a);
    const stream_a = enc_a.finish();

    var buf_b: [256]u8 = undefined;
    var enc_b = command.Encoder.init(&buf_b);
    enc_b.createBuffer(1, .vertex, 0x1000, 64);
    enc_b.createBuffer(2, .index, 0x2000, 32);
    const stream_b = enc_b.finish();

    try testing.expectEqualSlices(u8, stream_b, stream_a);
}

test "reset clears count, overflow flag, and replay emits nothing" {
    var reg = Registry(4){};
    reg.recordBuffer(1, .vertex, 0x1000, 64);
    reg.recordShader(2, 1, 0x4000, 64, 0x5000, 64);
    reg.reset();

    try testing.expectEqual(@as(usize, 0), reg.count());
    try testing.expect(!reg.overflowed());

    // Replay into a fresh encoder → stream length == fresh encoder with no writes.
    var buf_a: [256]u8 = undefined;
    var enc_a = command.Encoder.init(&buf_a);
    reg.replay(&enc_a);
    const stream_a = enc_a.finish();

    var buf_b: [256]u8 = undefined;
    var enc_b = command.Encoder.init(&buf_b);
    const stream_b = enc_b.finish();

    try testing.expectEqualSlices(u8, stream_b, stream_a);
}

test "freestanding: Registry compiles with no allocator in scope" {
    // Compile-time proof: instantiate and use without any std.mem.Allocator.
    var reg = Registry(4){};
    reg.recordBuffer(1, .vertex, 0, 0);
    try testing.expectEqual(@as(usize, 1), reg.count());
    try testing.expect(!reg.overflowed());
    reg.reset();
    try testing.expectEqual(@as(usize, 0), reg.count());
}
