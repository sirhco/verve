//! Build-time GL asset converter.
//!
//! Dispatches on the input file extension:
//!   .glb → gl.gltf.parseGlb + gl.vmesh.pack → writes <out.vmesh>
//!   .hdr → gl.hdr.decode + IBL prefilter chain + gl.venv.pack → writes <out.venv>
//!
//! Invoked by build.zig via addRunArtifact; the output LazyPath is embedded
//! into the server's gl_assets module.

const std = @import("std");
const gl = @import("verve_gl");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) {
        std.log.err("gl_asset_gen: usage: gl_asset_gen <in.glb|in.hdr> <out.vmesh|out.venv>", .{});
        return error.MissingArgs;
    }
    const in_path = args[1];
    const out_path = args[2];

    const alloc = init.gpa;
    const cwd = std.Io.Dir.cwd();

    // Read the input file.
    const in_bytes = blk: {
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
    defer alloc.free(in_bytes);

    // Dispatch on extension.
    const ext = std.fs.path.extension(in_path);
    const out_bytes = if (std.ascii.eqlIgnoreCase(ext, ".hdr"))
        try convertHdr(alloc, in_path, in_bytes)
    else
        try convertGlb(alloc, in_path, in_bytes);
    defer alloc.free(out_bytes);

    // Write output file.
    var out_file = cwd.createFile(io, out_path, .{}) catch |err| {
        std.log.err("gl_asset_gen: {s}: cannot create: {s}", .{ out_path, @errorName(err) });
        return err;
    };
    defer out_file.close(io);
    try out_file.writePositionalAll(io, out_bytes, 0);
}

// ── .glb → .vmesh ────────────────────────────────────────────────────────────

fn convertGlb(alloc: std.mem.Allocator, in_path: []const u8, glb_bytes: []const u8) ![]u8 {
    // Parse GLB → Model.
    var model = gl.gltf.parseGlb(alloc, glb_bytes) catch |err| {
        std.log.err("gl_asset_gen: {s}: unsupported or malformed glb: {s}", .{ in_path, @errorName(err) });
        return err;
    };
    defer model.deinit();

    // Build the per-mesh BVH over the interleaved vertex pool (stride 48 →
    // 12 f32/vertex, position xyz at offset 0).
    var bvh_result = gl.bvh.build(alloc, model.vertices, 12, model.indices) catch |err| {
        std.log.err("gl_asset_gen: {s}: BVH build failed: {s}", .{ in_path, @errorName(err) });
        return err;
    };
    defer bvh_result.deinit(alloc);

    // Pack Model + BVH + names → v3 .vmesh bytes.
    return gl.vmesh.pack(
        alloc,
        model.vertices,
        model.indices,
        model.submeshes,
        model.textures,
        bvh_result.nodes,
        bvh_result.tri_perm,
        model.names,
    );
}

// ── .hdr → .venv ─────────────────────────────────────────────────────────────

fn convertHdr(alloc: std.mem.Allocator, in_path: []const u8, hdr_bytes: []const u8) ![]u8 {
    // Decode .hdr → linear RGB image.
    var img = gl.hdr.decode(alloc, hdr_bytes) catch |err| {
        std.log.err("gl_asset_gen: {s}: failed to decode HDR: {s}", .{ in_path, @errorName(err) });
        return err;
    };
    defer img.deinit(alloc);

    // Equirectangular → environment cubemap (128² faces).
    var env = gl.ibl.equirectToCube(alloc, img.rgb, img.width, img.height, 128) catch |err| {
        std.log.err("gl_asset_gen: {s}: equirectToCube failed: {s}", .{ in_path, @errorName(err) });
        return err;
    };
    defer env.deinit(alloc);

    // Irradiance (diffuse) cube: 32² faces, 128 samples.
    var irr_cube = gl.ibl.irradiance(alloc, env, 32, 128) catch |err| {
        std.log.err("gl_asset_gen: {s}: irradiance failed: {s}", .{ in_path, @errorName(err) });
        return err;
    };
    defer irr_cube.deinit(alloc);

    // Irradiance → RGBA16F run.
    const irr_run = try gl.ibl.cubeToRgba16f(alloc, irr_cube);
    defer alloc.free(irr_run);

    // Specular prefilter: 6 mip levels, base 128², 64 samples.
    // mip m: face edge = 128 >> m, roughness = m / 5.0.
    // Concatenate mip-major: mip 0 first, each mip's 6-face run appended.
    const spec_mip_count: u32 = 6;
    var spec_runs: std.ArrayList(u16) = .empty;
    defer spec_runs.deinit(alloc);

    for (0..spec_mip_count) |m| {
        const mi: u32 = @intCast(m);
        const face_size: u32 = @as(u32, 128) >> @intCast(mi);
        const roughness: f32 = @as(f32, @floatFromInt(mi)) / 5.0;
        var mip_cube = gl.ibl.prefilter(alloc, env, face_size, roughness, 64) catch |err| {
            std.log.err("gl_asset_gen: {s}: prefilter mip {d} failed: {s}", .{ in_path, m, @errorName(err) });
            return err;
        };
        defer mip_cube.deinit(alloc);

        const mip_run = try gl.ibl.cubeToRgba16f(alloc, mip_cube);
        defer alloc.free(mip_run);
        try spec_runs.appendSlice(alloc, mip_run);
    }

    // BRDF integration LUT: 64 samples, 256² texels.
    const lut_f32 = try gl.ibl.brdfLut(alloc, 64, 256);
    defer alloc.free(lut_f32);

    const lut_run = try gl.ibl.lutToRgba16f(alloc, lut_f32, 64);
    defer alloc.free(lut_run);

    // Pack everything into a .venv binary.
    return gl.venv.pack(
        alloc,
        32, // irr_size
        irr_run,
        128, // spec_size
        spec_mip_count,
        spec_runs.items,
        64, // lut_size
        lut_run,
    );
}
