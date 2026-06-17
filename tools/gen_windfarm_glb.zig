//! Build-time fixture generator. Writes the procedural wind-farm GLB
//! produced by gl.fixture.windFarmGlb to the path supplied as argv[1].
//! The glb carries ground + 4 turbine meshes (turbine0..turbine3) + 4
//! mesh-less rotor hierarchy nodes (rotor0..rotor3), exercising the
//! multi-mesh + node-target path in gl_asset_gen → vmesh name table.
//!
//! Invoked by build.zig via addRunArtifact; the output LazyPath is fed as
//! the input file argument to gl_asset_gen.

const std = @import("std");
const gl = @import("verve_gl");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.log.err("gen_windfarm_glb: usage: gen_windfarm_glb <out.glb>", .{});
        return error.MissingOutPath;
    }
    const out_path = args[1];

    const alloc = init.gpa;

    const glb = try gl.fixture.windFarmGlb(alloc);
    defer alloc.free(glb);

    const cwd = std.Io.Dir.cwd();
    var file = try cwd.createFile(io, out_path, .{});
    defer file.close(io);
    try file.writePositionalAll(io, glb, 0);
}
