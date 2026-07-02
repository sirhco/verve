// viz_assets_stub.zig — drop-in for builds that ship no viz assets.
// External package consumers that don't run the viz asset pipeline map this
// file as the `viz_assets` module. The public surface is identical to the
// generated viz_assets.zig so src/server/main.zig compiles against either.

pub const VizAsset = struct { name: []const u8, bytes: []const u8 };

pub const viz_assets: []const VizAsset = &.{};

pub fn lookupVizAsset(name: []const u8) ?VizAsset {
    _ = name;
    return null;
}
