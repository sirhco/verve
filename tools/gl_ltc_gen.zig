//! Build-time LTC LUT packer.
//!
//! Packs the two rect-area-light LTC lookup tables from
//! `src/core/gl/ltc_data.zig` into a single served binary `ltc.bin`:
//!
//!   ltc.bin = ltc_mat (rgba16f) ++ ltc_mag (rgba16f)
//!
//!   - ltc_mat: 64x64 texels, RGBA, row-major → 16384 halfs = 32768 bytes
//!   - ltc_mag: 64x64 texels, RGBA, row-major → 16384 halfs = 32768 bytes
//!   - total: 65536 bytes, mat first then mag, little-endian f16.
//!
//! f32→f16 conversion uses `gl.ibl.f16Bits` — the same path the BRDF LUT takes
//! in `gl.ibl.lutToRgba16f`. The source arrays are already laid out as RGBA
//! (4 floats per texel), so we convert straight through with no reshuffle.
//!
//! Native-only tool: it imports the pure-data `ltc_data` module via `verve_gl`.
//! The gl island chunk never references it, so the LUT bytes never bloat the
//! chunk wasm (the chunk-data-window gotcha) — they reach the browser as a
//! fetched `/gl/ltc.bin` asset instead.
//!
//! Invoked by build.zig via addRunArtifact; the output path is captured into the
//! server's gl_assets embed table.

const std = @import("std");
const gl = @import("verve_gl");

// 64*64*4 = 16384 halfs per LUT.
const LUT_HALFS = gl.ltc_data.ltc_mat.len; // 16384
const LUT_BYTES = LUT_HALFS * 2; // 32768
const TOTAL_BYTES = LUT_BYTES * 2; // 65536

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.log.err("gl_ltc_gen: usage: gl_ltc_gen <out.bin>", .{});
        return error.MissingArgs;
    }
    const out_path = args[1];

    const alloc = init.gpa;

    // Pack mat then mag, each f32→f16 via the shared ibl.f16Bits.
    var out = try alloc.alloc(u8, TOTAL_BYTES);
    defer alloc.free(out);

    packLut(&gl.ltc_data.ltc_mat, out[0..LUT_BYTES]);
    packLut(&gl.ltc_data.ltc_mag, out[LUT_BYTES..TOTAL_BYTES]);

    const cwd = std.Io.Dir.cwd();
    var out_file = cwd.createFile(io, out_path, .{}) catch |err| {
        std.log.err("gl_ltc_gen: {s}: cannot create: {s}", .{ out_path, @errorName(err) });
        return err;
    };
    defer out_file.close(io);
    try out_file.writePositionalAll(io, out, 0);
}

/// Convert a [16384]f32 RGBA LUT to little-endian rgba16f bytes in `dst`.
fn packLut(src: *const [LUT_HALFS]f32, dst: []u8) void {
    std.debug.assert(dst.len == LUT_BYTES);
    var i: usize = 0;
    while (i < LUT_HALFS) : (i += 1) {
        const bits = gl.ibl.f16Bits(src[i]);
        std.mem.writeInt(u16, dst[i * 2 ..][0..2], bits, .little);
    }
}
