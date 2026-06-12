//! Build-time fixture generator. Writes the procedural studio HDR environment
//! produced by gl.fixture.studioHdr to the path supplied as argv[1].
//!
//! Invoked by build.zig via addRunArtifact; the output LazyPath is fed as
//! the input file argument to gl_asset_gen for HDR → .venv conversion.

const std = @import("std");
const gl = @import("verve_gl");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.log.err("gen_demo_hdr: usage: gen_demo_hdr <out.hdr>", .{});
        return error.MissingOutPath;
    }
    const out_path = args[1];

    const alloc = init.gpa;

    const hdr_bytes = try gl.fixture.studioHdr(alloc, 256, 128);
    defer alloc.free(hdr_bytes);

    const cwd = std.Io.Dir.cwd();
    var file = try cwd.createFile(io, out_path, .{});
    defer file.close(io);
    try file.writePositionalAll(io, hdr_bytes, 0);
}
