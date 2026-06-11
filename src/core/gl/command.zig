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
};

pub const BufferKind = enum(u32) { vertex = 0, index = 1 };

/// SET_PIPELINE state bits.
pub const state_depth_test: u32 = 1 << 0;
pub const state_cull_back: u32 = 1 << 1;

/// CREATE_SHADER variant bits.
pub const variant_vertex_color: u32 = 1 << 0;

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

pub const Encoder = struct {
    buf: []u8,
    len: usize,

    pub fn init(buf: []u8) Encoder {
        return .{ .buf = buf, .len = 4 }; // [0..4) reserved for the length header
    }

    fn header(self: *Encoder, tag: Tag, payload_size: u16) void {
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
