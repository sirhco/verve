//! Per-app island registry. The build discovers each `pub const <Name> =
//! struct { ... }` here and compiles the matching chunk. FarmScene resolves
//! to the local chunk at `src/client/islands/FarmScene.zig`.

/// Wind farm 3D scene: orbit camera, 4 turbines, continuous rotor spin.
/// Source: `src/client/islands/FarmScene.zig`.
/// No encoded props — the chunk hardcodes the vmesh URL and camera settings.
pub const FarmScene = struct {
    pub const props_schema: []const u8 = "{}";
};

/// Live telemetry dashboard: subscribes to SSE `/push?channel=metrics`,
/// renders a power history area chart + RPM gauge + wind readout for turbine 0.
/// Source: `src/client/islands/Dashboard.zig`.
pub const Dashboard = struct {
    pub const props_schema: []const u8 = "{}";
};
