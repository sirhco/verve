//! Build-time fixture generator. Writes the procedural PBR-cube GLB
//! produced by gl.fixture.pbrCubeGlb (no pre-baked tangents) to the path
//! supplied as argv[1].  Omitting tangents exercises the build-side
//! tangent-generation pass inside gl_asset_gen.
//!
//! Invoked by build.zig via addRunArtifact; the output LazyPath is fed as
//! the input file argument to gl_asset_gen.

const std = @import("std");
const gl = @import("verve_gl");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.log.err("gen_demo_glb: usage: gen_demo_glb <out.glb>", .{});
        return error.MissingOutPath;
    }
    const out_path = args[1];

    const alloc = init.gpa;

    const glb = try gl.fixture.pbrCubeGlb(alloc, .{ .with_tangents = false });
    defer alloc.free(glb);

    const cwd = std.Io.Dir.cwd();
    var file = try cwd.createFile(io, out_path, .{});
    defer file.close(io);
    try file.writePositionalAll(io, glb, 0);
}
