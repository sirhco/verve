//! Build-time GL asset converter.
//!
//! Dispatches on the input file extension:
//!   .glb → gl.gltf.parseGlb + gl.vmesh.pack → writes <out_dir>/<stem>.vmesh
//!          plus one sibling <out_dir>/<stem>.tex{index}.{ext} per externalized
//!          (large) texture kept as compressed bytes, and a matching
//!          <out_dir>/<stem>.tex{index}.ktx2 (BC7/KTX2, DORMANT until S3).
//!   .hdr → gl.hdr.decode + IBL prefilter chain + gl.venv.pack → writes
//!          <out_dir>/<stem>.venv
//!
//! Invoked by build.zig via addRunArtifact; the output directory LazyPath is
//! embedded (per-file) into the server's gl_assets module.

const std = @import("std");
const gl = @import("verve_gl");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 4) {
        std.log.err("gl_asset_gen: usage: gl_asset_gen <in.glb|in.hdr> <out_dir> <stem> [--fast]", .{});
        return error.MissingArgs;
    }
    const in_path = args[1];
    const out_dir = args[2];
    const stem = args[3];

    // `--fast` (any trailing arg): lower the IBL prefilter sample counts for a
    // faster build at reduced quality. Output sizes are unchanged, so the .venv
    // format is identical — only the prefiltered values are coarser.
    var fast = false;
    for (args[4..]) |a| {
        if (std.mem.eql(u8, a, "--fast")) fast = true;
    }

    const alloc = init.gpa;
    const cwd = std.Io.Dir.cwd();

    // The output directory is created by build.zig's addOutputDirectoryArg, but
    // make sure it exists when running the tool standalone.
    cwd.createDirPath(io, out_dir) catch {};

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
    if (std.ascii.eqlIgnoreCase(ext, ".hdr")) {
        const out_bytes = try convertHdr(alloc, in_path, in_bytes, quality(fast));
        defer alloc.free(out_bytes);
        const venv_name = try std.fmt.allocPrint(alloc, "{s}.venv", .{stem});
        defer alloc.free(venv_name);
        try writeAsset(io, cwd, alloc, out_dir, venv_name, out_bytes);
    } else {
        try convertGlb(io, cwd, alloc, out_dir, stem, in_path, in_bytes);
    }
}

/// Join `<dir>/<name>` and write `bytes` to it.
fn writeAsset(
    io: std.Io,
    cwd: std.Io.Dir,
    alloc: std.mem.Allocator,
    dir: []const u8,
    name: []const u8,
    bytes: []const u8,
) !void {
    const path = try std.fs.path.join(alloc, &.{ dir, name });
    defer alloc.free(path);
    var out_file = cwd.createFile(io, path, .{}) catch |err| {
        std.log.err("gl_asset_gen: {s}: cannot create: {s}", .{ path, @errorName(err) });
        return err;
    };
    defer out_file.close(io);
    try out_file.writePositionalAll(io, bytes, 0);
}

// ── .glb → .vmesh (+ external texture files) ──────────────────────────────────

fn convertGlb(
    io: std.Io,
    cwd: std.Io.Dir,
    alloc: std.mem.Allocator,
    out_dir: []const u8,
    stem: []const u8,
    in_path: []const u8,
    glb_bytes: []const u8,
) !void {
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
    const vmesh_bytes = try gl.vmesh.pack(
        alloc,
        model.vertices,
        model.indices,
        model.submeshes,
        model.textures,
        bvh_result.nodes,
        bvh_result.tri_perm,
        model.names,
        model.skinned,
        model.joints,
        model.weights,
        model.skel,
        if (model.anim_clips.len == 0) null else gl.vmesh.Anims{ .clips = model.anim_clips },
        model.instances, // EXT_mesh_gpu_instancing → vmesh instances section
        model.instance_count,
        model.morph, // v13 morph section; null when no morph targets present
        model.lod, // v15 LOD section; null when no _lodN meshes
    );
    defer alloc.free(vmesh_bytes);

    const vmesh_name = try std.fmt.allocPrint(alloc, "{s}.vmesh", .{stem});
    defer alloc.free(vmesh_name);
    try writeAsset(io, cwd, alloc, out_dir, vmesh_name, vmesh_bytes);

    // Build a vmesh Reader over the just-packed bytes for the sRGB role lookup
    // (texIsSrgb returns true for base-color/emissive maps, false for linear maps).
    const reader = try gl.vmesh.Reader.init(vmesh_bytes);

    // Write each externalized (large) texture as a sibling pair:
    //   <stem>.tex{index}.{ext}  — original compressed bytes (unchanged)
    //   <stem>.tex{index}.ktx2   — BC7/KTX2 sibling (DORMANT until S3 loader)
    for (model.external_textures) |tex| {
        const tex_name = try std.fmt.allocPrint(alloc, "{s}.tex{d}.{s}", .{ stem, tex.index, tex.ext });
        defer alloc.free(tex_name);
        try writeAsset(io, cwd, alloc, out_dir, tex_name, tex.bytes);

        const ktx2_name = try std.fmt.allocPrint(alloc, "{s}.tex{d}.ktx2", .{ stem, tex.index });
        defer alloc.free(ktx2_name);
        const srgb = reader.texIsSrgb(tex.index);
        const ktx2_bytes = try gl.tex_encode.pngToKtx2(alloc, tex.bytes, srgb);
        defer alloc.free(ktx2_bytes);
        try writeAsset(io, cwd, alloc, out_dir, ktx2_name, ktx2_bytes);
    }
}

// ── .hdr → .venv ─────────────────────────────────────────────────────────────

/// IBL prefilter sample counts. Output sizes are fixed (32²/128²/64²) — only the
/// Monte-Carlo sample counts vary, so the .venv format is identical either way.
const Quality = struct { irr_samples: u32, spec_samples: u32, lut_samples: u32 };

fn quality(fast: bool) Quality {
    return if (fast)
        .{ .irr_samples = 32, .spec_samples = 16, .lut_samples = 64 }
    else
        .{ .irr_samples = 128, .spec_samples = 64, .lut_samples = 256 };
}

fn convertHdr(alloc: std.mem.Allocator, in_path: []const u8, hdr_bytes: []const u8, q: Quality) ![]u8 {
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

    // Irradiance (diffuse) cube: 32² faces.
    var irr_cube = gl.ibl.irradiance(alloc, env, 32, q.irr_samples) catch |err| {
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
        var mip_cube = gl.ibl.prefilter(alloc, env, face_size, roughness, q.spec_samples) catch |err| {
            std.log.err("gl_asset_gen: {s}: prefilter mip {d} failed: {s}", .{ in_path, m, @errorName(err) });
            return err;
        };
        defer mip_cube.deinit(alloc);

        const mip_run = try gl.ibl.cubeToRgba16f(alloc, mip_cube);
        defer alloc.free(mip_run);
        try spec_runs.appendSlice(alloc, mip_run);
    }

    // BRDF integration LUT: 64² texels.
    const lut_f32 = try gl.ibl.brdfLut(alloc, 64, q.lut_samples);
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
