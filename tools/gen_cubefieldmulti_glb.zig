//! Build-time fixture generator. Writes the procedural 8×8 cube-field GLB
//! produced by gl.fixture.cubeFieldMultiGlb — a single mesh with TWO primitives
//! (two materials) and EXT_mesh_gpu_instancing encoding 64 instances over an
//! 8×8 grid.  Primitive 0 covers cube faces 0-2 (material 0, warm orange);
//! primitive 1 covers faces 3-5 (material 1, cool blue).
//! Feeds the /gl-instanced-multi multi-submesh instancing demo.
//!
//! Invoked by build.zig via addRunArtifact; the output LazyPath is fed as
//! the input file argument to gl_asset_gen.

const std = @import("std");
const gl = @import("verve_gl");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.log.err("gen_cubefieldmulti_glb: usage: gen_cubefieldmulti_glb <out.glb>", .{});
        return error.MissingOutPath;
    }
    const out_path = args[1];

    const alloc = init.gpa;

    const glb = try gl.fixture.cubeFieldMultiGlb(alloc);
    defer alloc.free(glb);

    const cwd = std.Io.Dir.cwd();
    var file = try cwd.createFile(io, out_path, .{});
    defer file.close(io);
    try file.writePositionalAll(io, glb, 0);
}
