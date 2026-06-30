//! Build-time fixture generator. Writes the instanced-shadow demo GLB produced by
//! gl.fixture.cubeShadowFieldGlb — a single cube mesh with EXT_mesh_gpu_instancing
//! encoding 9 hand-placed instances: one wide flat floor slab (receiver) and eight
//! tall pillars (casters) that cast clearly-visible directional shadows onto the slab.
//! Each instance has TRANSLATION/ROTATION/SCALE/_COLOR_0 accessors.
//! Feeds the /gl-instanced-shadow instanced cast + receive demo.
//!
//! Invoked by build.zig via addRunArtifact; the output LazyPath is fed as
//! the input file argument to gl_asset_gen.

const std = @import("std");
const gl = @import("verve_gl");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.log.err("gen_cubeshadow_glb: usage: gen_cubeshadow_glb <out.glb>", .{});
        return error.MissingOutPath;
    }
    const out_path = args[1];

    const alloc = init.gpa;

    const glb = try gl.fixture.cubeShadowFieldGlb(alloc);
    defer alloc.free(glb);

    const cwd = std.Io.Dir.cwd();
    var file = try cwd.createFile(io, out_path, .{});
    defer file.close(io);
    try file.writePositionalAll(io, glb, 0);
}
