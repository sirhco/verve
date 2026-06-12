// gl_assets_stub.zig — drop-in for builds that ship no 3D assets.
// Example / consumer builds map this file as the `gl_assets` module when
// they don't run the gl asset pipeline (gen_demo_glb → gl_asset_gen →
// gen_demo_hdr pipeline). The public surface is identical to the generated
// gl_assets.zig so src/server/main.zig compiles against either.

pub const GlAsset = struct { name: []const u8, bytes: []const u8 };

pub const gl_assets: []const GlAsset = &.{};

pub fn lookupGlAsset(name: []const u8) ?GlAsset {
    _ = name;
    return null;
}
