//! Build-time fixture generator. Writes the procedural skinned-bar GLB
//! produced by gl.fixture.skinnedBarGlb to the path supplied as argv[1].
//! The glb carries a skin (3-joint chain) + JOINTS_0/WEIGHTS_0, exercising
//! the skin-parse path in gl_asset_gen → vmesh v5 skinned output.
//!
//! Invoked by build.zig via addRunArtifact; the output LazyPath is fed as
//! the input file argument to gl_asset_gen.

const std = @import("std");
const gl = @import("verve_gl");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.log.err("gen_skin_glb: usage: gen_skin_glb <out.glb>", .{});
        return error.MissingOutPath;
    }
    const out_path = args[1];

    const alloc = init.gpa;

    const glb = try gl.fixture.skinnedBarGlb(alloc);
    defer alloc.free(glb);

    const cwd = std.Io.Dir.cwd();
    var file = try cwd.createFile(io, out_path, .{});
    defer file.close(io);
    try file.writePositionalAll(io, glb, 0);
}
