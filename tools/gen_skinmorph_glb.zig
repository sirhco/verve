//! Build-time fixture generator. Writes the procedural skinned+morphed bar GLB
//! produced by gl.fixture.skinmorphBarGlb to the path supplied as argv[1].
//! The glb carries a skin (3-joint chain) + JOINTS_0/WEIGHTS_0 AND a morph
//! target (Bulge), exercising the combined skin+morph parse path in
//! gl_asset_gen → vmesh output with both skin and morph sections.
//!
//! Invoked by build.zig via addRunArtifact; the output LazyPath is fed as
//! the input file argument to gl_asset_gen.

const std = @import("std");
const gl = @import("verve_gl");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.log.err("gen_skinmorph_glb: usage: gen_skinmorph_glb <out.glb>", .{});
        return error.MissingOutPath;
    }
    const out_path = args[1];

    const alloc = init.gpa;

    const glb = try gl.fixture.skinmorphBarGlb(alloc);
    defer alloc.free(glb);

    const cwd = std.Io.Dir.cwd();
    var file = try cwd.createFile(io, out_path, .{});
    defer file.close(io);
    try file.writePositionalAll(io, glb, 0);
}
