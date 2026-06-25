//! Build-time fixture generator. Writes the procedural 16-target morph-demo GLB
//! produced by gl.fixture.morphDemo16Glb to the path supplied as argv[1].
//! The GLB carries a 5×5 subdivided plane with 16 morph targets, each deforming
//! a DISTINCT single vertex upward, and a LINEAR clip that sets ALL 16 to weight
//! 0.5 simultaneously at t=1s.  Used to validate the cap-32 active-set path:
//! with the old cap-8 only 8 vertices lift; with cap-32 all 16 lift at once.
//!
//! Invoked by build.zig via addRunArtifact; output LazyPath fed to gl_asset_gen.

const std = @import("std");
const gl = @import("verve_gl");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.log.err("gen_morph16_glb: usage: gen_morph16_glb <out.glb>", .{});
        return error.MissingOutPath;
    }
    const out_path = args[1];

    const alloc = init.gpa;

    const glb = try gl.fixture.morphDemo16Glb(alloc);
    defer alloc.free(glb);

    const cwd = std.Io.Dir.cwd();
    var file = try cwd.createFile(io, out_path, .{});
    defer file.close(io);
    try file.writePositionalAll(io, glb, 0);
}
