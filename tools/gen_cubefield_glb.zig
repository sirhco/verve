//! Build-time fixture generator. Writes the procedural 16×16 cube-field GLB
//! produced by gl.fixture.cubeFieldGlb — a single cube mesh with
//! EXT_mesh_gpu_instancing encoding 256 instances over a 16×16 grid.
//! Each instance has TRANSLATION/ROTATION/SCALE/_COLOR_0 accessors.
//! Feeds the /gl-instanced GPU-instancing demo.
//!
//! Invoked by build.zig via addRunArtifact; the output LazyPath is fed as
//! the input file argument to gl_asset_gen.

const std = @import("std");
const gl = @import("verve_gl");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.log.err("gen_cubefield_glb: usage: gen_cubefield_glb <out.glb>", .{});
        return error.MissingOutPath;
    }
    const out_path = args[1];

    const alloc = init.gpa;

    const glb = try gl.fixture.cubeFieldGlb(alloc);
    defer alloc.free(glb);

    const cwd = std.Io.Dir.cwd();
    var file = try cwd.createFile(io, out_path, .{});
    defer file.close(io);
    try file.writePositionalAll(io, glb, 0);
}
