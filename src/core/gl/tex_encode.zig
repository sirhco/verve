//! PNG → BC7 → KTX2 pipeline helper.
//!
//! `pngToKtx2` is the single entry point: decode a compressed PNG to RGBA8,
//! encode the RGBA8 raster to a BC7 mode-6 mip chain, and pack into a KTX2
//! container.
//!
//! Lives in core gl so it is covered by `zig build test`.
//! Used by `tools/gl_asset_gen.zig` at build time to emit `.ktx2` siblings
//! next to every externalized `.tex{N}.png` (DORMANT — S3 wires the loader).
//!
//! No runtime or wasm references; build/test only.

const std = @import("std");
const png = @import("png.zig");
const bc1 = @import("bc1.zig");
const bc7 = @import("bc7.zig");
const ktx2 = @import("ktx2.zig");

/// Decode PNG bytes → RGBA8 → BC7 mode-6 mip chain → KTX2 container.
///
/// `srgb` selects vkFormat:
///   true  → bc7_srgb  (146) — base-color / emissive maps
///   false → bc7_unorm (145) — normal / metallic-roughness / occlusion maps
///
/// `png.decode` always outputs packed RGBA8 regardless of the source PNG
/// color type (RGB or RGBA), so no channel-expansion is needed here.
///
/// Returns owned KTX2 bytes. Caller must free.
pub fn pngToKtx2(alloc: std.mem.Allocator, png_bytes: []const u8, srgb: bool) ![]u8 {
    // Decode PNG → RGBA8 (Image.rgba is w*h*4 bytes, tightly packed).
    var img = try png.decode(alloc, png_bytes);
    defer img.deinit(alloc);

    // Encode RGBA8 → BC7 mip chain (levels[0] is largest).
    // Each level slice and the outer slice are separately allocated.
    const levels = try bc7.encodeImage(alloc, img.rgba, img.width, img.height);
    defer {
        for (levels) |lvl| alloc.free(lvl);
        alloc.free(levels);
    }

    // Pack mip chain → KTX2 container bytes.
    return ktx2.write(alloc, levels, img.width, img.height, if (srgb) .bc7_srgb else .bc7_unorm);
}

/// Decode PNG bytes → RGBA8 → BC1 or BC3 mip chain → KTX2 container.
///
/// Mode is chosen by an alpha scan: if any pixel has alpha < 255, BC3 (DXT5)
/// is used to preserve transparency; otherwise BC1 (DXT1) is used (half the
/// storage, RGB-only).
///
/// `srgb` selects the vkFormat variant:
///   BC1 opaque: true → bc1_rgb_srgb (132), false → bc1_rgb_unorm (131)
///   BC3 alpha:  true → bc3_srgb     (138), false → bc3_unorm     (137)
///
/// Returns owned KTX2 bytes. Caller must free.
pub fn pngToKtx2S3tc(alloc: std.mem.Allocator, png_bytes: []const u8, srgb: bool) ![]u8 {
    // Decode PNG → RGBA8 (Image.rgba is w*h*4 bytes, tightly packed).
    var img = try png.decode(alloc, png_bytes);
    defer img.deinit(alloc);

    // Alpha scan: any pixel alpha < 255 → BC3, else BC1.
    var has_alpha = false;
    var i: usize = 3;
    while (i < img.rgba.len) : (i += 4) {
        if (img.rgba[i] < 255) {
            has_alpha = true;
            break;
        }
    }
    const mode: bc1.Mode = if (has_alpha) .bc3 else .bc1;

    // Encode RGBA8 → BC1/BC3 mip chain (levels[0] is largest).
    const levels = try bc1.encodeImage(alloc, img.rgba, img.width, img.height, mode);
    defer {
        for (levels) |lvl| alloc.free(lvl);
        alloc.free(levels);
    }

    // Select vkFormat from mode + srgb flag.
    const vk: ktx2.VkFormat = switch (mode) {
        .bc3 => if (srgb) .bc3_srgb else .bc3_unorm,
        .bc1 => if (srgb) .bc1_rgb_srgb else .bc1_rgb_unorm,
    };

    // Pack mip chain → KTX2 container bytes.
    return ktx2.write(alloc, levels, img.width, img.height, vk);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

/// Build a minimal PNG from a flat RGBA8 buffer via png.encodeRgba.
fn makeTestPng(alloc: std.mem.Allocator, rgba: []const u8, w: u32, h: u32) ![]u8 {
    return png.encodeRgba(alloc, rgba, w, h);
}

// ── pngToKtx2S3tc tests ───────────────────────────────────────────────────────

test "pngToKtx2S3tc: opaque→bc1_rgb_unorm/bc1_rgb_srgb, alpha→bc3_unorm/bc3_srgb" {
    const alloc = std.testing.allocator;

    // Opaque 4×4 image (all alpha=255).
    const opaque_rgba = [_]u8{
        0xff, 0x80, 0x20, 0xff, 0x10, 0xff, 0x40, 0xff,
        0x00, 0x00, 0xff, 0xff, 0x40, 0x80, 0x10, 0xff,
        0x80, 0x80, 0x80, 0xff, 0xc0, 0x40, 0x80, 0xff,
        0x20, 0x60, 0xa0, 0xff, 0xff, 0xff, 0x00, 0xff,
        0x10, 0x30, 0x50, 0xff, 0x70, 0x90, 0xb0, 0xff,
        0xd0, 0xf0, 0x10, 0xff, 0x88, 0x44, 0x22, 0xff,
        0xaa, 0xbb, 0xcc, 0xff, 0x11, 0x22, 0x33, 0xff,
        0x55, 0x66, 0x77, 0xff, 0x99, 0xaa, 0xbb, 0xff,
    };
    const opaque_png = try makeTestPng(alloc, &opaque_rgba, 4, 4);
    defer alloc.free(opaque_png);

    // Alpha 4×4 image (one pixel has alpha<255).
    const alpha_rgba = [_]u8{
        0xff, 0x80, 0x20, 0x00, 0x10, 0xff, 0x40, 0xff, // first pixel alpha=0
        0x00, 0x00, 0xff, 0xff, 0x40, 0x80, 0x10, 0xff,
        0x80, 0x80, 0x80, 0xff, 0xc0, 0x40, 0x80, 0xff,
        0x20, 0x60, 0xa0, 0xff, 0xff, 0xff, 0x00, 0xff,
        0x10, 0x30, 0x50, 0xff, 0x70, 0x90, 0xb0, 0xff,
        0xd0, 0xf0, 0x10, 0xff, 0x88, 0x44, 0x22, 0xff,
        0xaa, 0xbb, 0xcc, 0xff, 0x11, 0x22, 0x33, 0xff,
        0x55, 0x66, 0x77, 0xff, 0x99, 0xaa, 0xbb, 0xff,
    };
    const alpha_png = try makeTestPng(alloc, &alpha_rgba, 4, 4);
    defer alloc.free(alpha_png);

    // Opaque + linear → bc1_rgb_unorm.
    {
        const ktx2_bytes = try pngToKtx2S3tc(alloc, opaque_png, false);
        defer alloc.free(ktx2_bytes);
        const info = try ktx2.read(alloc, ktx2_bytes);
        defer alloc.free(info.levels);
        try std.testing.expectEqual(ktx2.VkFormat.bc1_rgb_unorm, info.vk_format);
        try std.testing.expect(!info.srgb);
    }

    // Opaque + sRGB → bc1_rgb_srgb.
    {
        const ktx2_bytes = try pngToKtx2S3tc(alloc, opaque_png, true);
        defer alloc.free(ktx2_bytes);
        const info = try ktx2.read(alloc, ktx2_bytes);
        defer alloc.free(info.levels);
        try std.testing.expectEqual(ktx2.VkFormat.bc1_rgb_srgb, info.vk_format);
        try std.testing.expect(info.srgb);
    }

    // Alpha + linear → bc3_unorm.
    {
        const ktx2_bytes = try pngToKtx2S3tc(alloc, alpha_png, false);
        defer alloc.free(ktx2_bytes);
        const info = try ktx2.read(alloc, ktx2_bytes);
        defer alloc.free(info.levels);
        try std.testing.expectEqual(ktx2.VkFormat.bc3_unorm, info.vk_format);
        try std.testing.expect(!info.srgb);
    }

    // Alpha + sRGB → bc3_srgb.
    {
        const ktx2_bytes = try pngToKtx2S3tc(alloc, alpha_png, true);
        defer alloc.free(ktx2_bytes);
        const info = try ktx2.read(alloc, ktx2_bytes);
        defer alloc.free(info.levels);
        try std.testing.expectEqual(ktx2.VkFormat.bc3_srgb, info.vk_format);
        try std.testing.expect(info.srgb);
    }
}

test "pngToKtx2S3tc: round-trip w/h/level_count/non-empty levels + block-size spot check" {
    const alloc = std.testing.allocator;

    // 8×4 opaque (alpha=255 in all pixels) → BC1, log2(max(8,4))+1 = 4 levels.
    // Use per-pixel RGBA tuple (.R=80,.G=40,.B=20,.A=255) × 32 pixels to ensure
    // every alpha byte is 0xff so the alpha scan selects BC1, not BC3.
    const w: u32 = 8;
    const h: u32 = 4;
    const opaque_rgba = [_]u8{ 0x50, 0x28, 0x14, 0xff } ** (8 * 4);
    const opaque_png = try makeTestPng(alloc, &opaque_rgba, w, h);
    defer alloc.free(opaque_png);

    {
        const ktx2_bytes = try pngToKtx2S3tc(alloc, opaque_png, false);
        defer alloc.free(ktx2_bytes);
        const info = try ktx2.read(alloc, ktx2_bytes);
        defer alloc.free(info.levels);
        try std.testing.expectEqual(w, info.w);
        try std.testing.expectEqual(h, info.h);
        try std.testing.expectEqual(@as(u32, 4), info.level_count);
        try std.testing.expectEqual(@as(usize, 4), info.levels.len);
        for (info.levels) |ref| {
            try std.testing.expect(ref.len > 0);
        }
        // Level 0: 8×4 → 2×1 blocks of 4×4 → 2 BC1 blocks × 8 bytes = 16 bytes.
        try std.testing.expectEqual(@as(usize, 16), info.levels[0].len);
    }

    // 4×4 alpha image → BC3, log2(4)+1 = 3 levels, level 0 = 1 BC3 block = 16 bytes.
    // First pixel has alpha=0x7f (< 255), rest have alpha=0xff.
    const alpha_rgba = [_]u8{
        0x50, 0x28, 0x14, 0x7f, // pixel 0: semi-transparent → triggers BC3
        0x50, 0x28, 0x14, 0xff,
        0x50, 0x28, 0x14, 0xff,
        0x50, 0x28, 0x14, 0xff,
        0x50, 0x28, 0x14, 0xff,
        0x50, 0x28, 0x14, 0xff,
        0x50, 0x28, 0x14, 0xff,
        0x50, 0x28, 0x14, 0xff,
        0x50, 0x28, 0x14, 0xff,
        0x50, 0x28, 0x14, 0xff,
        0x50, 0x28, 0x14, 0xff,
        0x50, 0x28, 0x14, 0xff,
        0x50, 0x28, 0x14, 0xff,
        0x50, 0x28, 0x14, 0xff,
        0x50, 0x28, 0x14, 0xff,
        0x50, 0x28, 0x14, 0xff,
    };
    const alpha_png = try makeTestPng(alloc, &alpha_rgba, 4, 4);
    defer alloc.free(alpha_png);

    {
        const ktx2_bytes = try pngToKtx2S3tc(alloc, alpha_png, false);
        defer alloc.free(ktx2_bytes);
        const info = try ktx2.read(alloc, ktx2_bytes);
        defer alloc.free(info.levels);
        try std.testing.expectEqual(@as(u32, 4), info.w);
        try std.testing.expectEqual(@as(u32, 4), info.h);
        try std.testing.expectEqual(@as(u32, 3), info.level_count); // log2(4)+1 = 3
        // Level 0: 4×4 → 1×1 BC3 block × 16 bytes = 16 bytes.
        try std.testing.expectEqual(@as(usize, 16), info.levels[0].len);
    }
}

test "pngToKtx2S3tc: deterministic (same PNG in → identical S3TC bytes out)" {
    const alloc = std.testing.allocator;

    const rgba = [_]u8{
        0x12, 0x34, 0x56, 0x80, 0x78, 0x9a, 0xbc, 0xff, // first pixel semi-transparent
        0xde, 0xf0, 0x11, 0xff, 0x22, 0x33, 0x44, 0xff,
        0x55, 0x66, 0x77, 0xff, 0x88, 0x99, 0xaa, 0xff,
        0xbb, 0xcc, 0xdd, 0xff, 0xee, 0xff, 0x00, 0xff,
        0x01, 0x23, 0x45, 0xff, 0x67, 0x89, 0xab, 0xff,
        0xcd, 0xef, 0x10, 0xff, 0x32, 0x54, 0x76, 0xff,
        0x98, 0xba, 0xdc, 0xff, 0xfe, 0x10, 0x32, 0xff,
        0x54, 0x76, 0x98, 0xff, 0xba, 0xdc, 0xfe, 0xff,
    };
    const test_png = try makeTestPng(alloc, &rgba, 4, 4);
    defer alloc.free(test_png);

    const s3tc_a = try pngToKtx2S3tc(alloc, test_png, true);
    defer alloc.free(s3tc_a);
    const s3tc_b = try pngToKtx2S3tc(alloc, test_png, true);
    defer alloc.free(s3tc_b);

    try std.testing.expectEqualSlices(u8, s3tc_a, s3tc_b);
}

test "pngToKtx2: srgb=true → bc7_srgb (146), srgb=false → bc7_unorm (145)" {
    const alloc = std.testing.allocator;

    // 4×4 RGBA test image (non-trivial values to exercise the encoder).
    const rgba = [_]u8{
        0xff, 0x80, 0x20, 0xff, 0x10, 0xff, 0x40, 0xff,
        0x00, 0x00, 0xff, 0x80, 0x40, 0x80, 0x10, 0xff,
        0x80, 0x80, 0x80, 0xff, 0xc0, 0x40, 0x80, 0xff,
        0x20, 0x60, 0xa0, 0xff, 0xff, 0xff, 0x00, 0xff,
        0x10, 0x30, 0x50, 0xff, 0x70, 0x90, 0xb0, 0xff,
        0xd0, 0xf0, 0x10, 0xff, 0x88, 0x44, 0x22, 0xff,
        0xaa, 0xbb, 0xcc, 0xff, 0x11, 0x22, 0x33, 0xff,
        0x55, 0x66, 0x77, 0xff, 0x99, 0xaa, 0xbb, 0xff,
    }; // 4*4*4 = 64 bytes
    const test_png = try makeTestPng(alloc, &rgba, 4, 4);
    defer alloc.free(test_png);

    // sRGB → bc7_srgb.
    {
        const ktx2_bytes = try pngToKtx2(alloc, test_png, true);
        defer alloc.free(ktx2_bytes);
        const info = try ktx2.read(alloc, ktx2_bytes);
        defer alloc.free(info.levels);
        try std.testing.expectEqual(ktx2.VkFormat.bc7_srgb, info.vk_format);
        try std.testing.expectEqual(@as(u32, 4), info.w);
        try std.testing.expectEqual(@as(u32, 4), info.h);
        try std.testing.expect(info.srgb);
    }

    // Linear → bc7_unorm.
    {
        const ktx2_bytes = try pngToKtx2(alloc, test_png, false);
        defer alloc.free(ktx2_bytes);
        const info = try ktx2.read(alloc, ktx2_bytes);
        defer alloc.free(info.levels);
        try std.testing.expectEqual(ktx2.VkFormat.bc7_unorm, info.vk_format);
        try std.testing.expect(!info.srgb);
    }
}

test "pngToKtx2: round-trip w/h/level_count/non-empty levels" {
    const alloc = std.testing.allocator;

    // 8×4 → log2(max(8,4))+1 = 4 mip levels (8×4, 4×2, 2×1, 1×1).
    const w: u32 = 8;
    const h: u32 = 4;
    const rgba = [_]u8{128} ** (8 * 4 * 4); // 128 bytes
    const test_png = try makeTestPng(alloc, &rgba, w, h);
    defer alloc.free(test_png);

    const ktx2_bytes = try pngToKtx2(alloc, test_png, false);
    defer alloc.free(ktx2_bytes);

    const info = try ktx2.read(alloc, ktx2_bytes);
    defer alloc.free(info.levels);

    try std.testing.expectEqual(w, info.w);
    try std.testing.expectEqual(h, info.h);
    // bc7.encodeImage: levels = 1 + floor(log2(max(8,4))) = 1 + 3 = 4
    try std.testing.expectEqual(@as(u32, 4), info.level_count);
    try std.testing.expectEqual(@as(usize, 4), info.levels.len);
    for (info.levels) |ref| {
        try std.testing.expect(ref.len > 0);
    }
}

test "pngToKtx2: deterministic (same PNG in → identical KTX2 bytes out)" {
    const alloc = std.testing.allocator;

    const rgba = [_]u8{
        0x12, 0x34, 0x56, 0xff, 0x78, 0x9a, 0xbc, 0xff,
        0xde, 0xf0, 0x11, 0xff, 0x22, 0x33, 0x44, 0xff,
        0x55, 0x66, 0x77, 0xff, 0x88, 0x99, 0xaa, 0xff,
        0xbb, 0xcc, 0xdd, 0xff, 0xee, 0xff, 0x00, 0xff,
        0x01, 0x23, 0x45, 0xff, 0x67, 0x89, 0xab, 0xff,
        0xcd, 0xef, 0x10, 0xff, 0x32, 0x54, 0x76, 0xff,
        0x98, 0xba, 0xdc, 0xff, 0xfe, 0x10, 0x32, 0xff,
        0x54, 0x76, 0x98, 0xff, 0xba, 0xdc, 0xfe, 0xff,
    }; // 4*4*4 = 64 bytes
    const test_png = try makeTestPng(alloc, &rgba, 4, 4);
    defer alloc.free(test_png);

    const ktx2_a = try pngToKtx2(alloc, test_png, true);
    defer alloc.free(ktx2_a);
    const ktx2_b = try pngToKtx2(alloc, test_png, true);
    defer alloc.free(ktx2_b);

    try std.testing.expectEqualSlices(u8, ktx2_a, ktx2_b);
}
