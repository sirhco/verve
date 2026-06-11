//! Build-time GL asset converter. Reads a GLB file from argv[1] and writes
//! a packed .vmesh file to argv[2] via gl.gltf.parseGlb + gl.vmesh.pack.
//!
//! Invoked by build.zig via addRunArtifact after gen_demo_glb; the output
//! LazyPath is embedded into the server's gl_assets module.

const std = @import("std");
const gl = @import("verve_gl");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) {
        std.log.err("gl_asset_gen: usage: gl_asset_gen <in.glb> <out.vmesh>", .{});
        return error.MissingArgs;
    }
    const in_path = args[1];
    const out_path = args[2];

    const alloc = init.gpa;

    // Read the input GLB.
    const cwd = std.Io.Dir.cwd();
    const glb_bytes = blk: {
        var in_file = cwd.openFile(io, in_path, .{}) catch |err| {
            std.log.err("gl_asset_gen: {s}: cannot open: {s}", .{ in_path, @errorName(err) });
            return err;
        };
        defer in_file.close(io);
        const stat = try in_file.stat(io);
        const buf = try alloc.alloc(u8, @intCast(stat.size));
        _ = try in_file.readPositionalAll(io, buf, 0);
        break :blk buf;
    };
    defer alloc.free(glb_bytes);

    // Parse GLB → Model.
    var model = gl.gltf.parseGlb(alloc, glb_bytes) catch |err| {
        std.log.err("gl_asset_gen: {s}: unsupported or malformed glb: {s}", .{ in_path, @errorName(err) });
        return err;
    };
    defer model.deinit();

    // Pack Model → .vmesh bytes.
    const vmesh_bytes = try gl.vmesh.pack(
        alloc,
        model.vertices,
        model.indices,
        model.submeshes,
        model.textures,
    );
    defer alloc.free(vmesh_bytes);

    // Write output .vmesh.
    var out_file = try cwd.createFile(io, out_path, .{});
    defer out_file.close(io);
    try out_file.writePositionalAll(io, vmesh_bytes, 0);
}
