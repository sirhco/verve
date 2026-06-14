//! Build-time fixture generator. Writes the procedural mixed-material GLB
//! produced by gl.fixture.pbrCubeMixedMaterialGlb (two named meshes:
//! "MixedFull" full-PBR + "MixedBase" base-color only) to the path supplied
//! as argv[1]. The two distinct materials exercise the per-submesh shader-
//! variant fan-out (GlScene builds two shaders and switches setPipeline).
//!
//! Invoked by build.zig via addRunArtifact; the output LazyPath is fed as
//! the input file argument to gl_asset_gen.

const std = @import("std");
const gl = @import("verve_gl");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.log.err("gen_mixed_glb: usage: gen_mixed_glb <out.glb>", .{});
        return error.MissingOutPath;
    }
    const out_path = args[1];

    const alloc = init.gpa;

    const glb = try gl.fixture.pbrCubeMixedMaterialGlb(alloc);
    defer alloc.free(glb);

    const cwd = std.Io.Dir.cwd();
    var file = try cwd.createFile(io, out_path, .{});
    defer file.close(io);
    try file.writePositionalAll(io, glb, 0);
}
