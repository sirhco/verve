//! Island registry. Each `pub const <Name> = struct { ... };` becomes a
//! build-time entry in `client_manifest.zig` and a per-island WASM chunk
//! served at `/islands/<Name>.wasm`.

pub const Counter = struct {
    pub const Props = struct { initial: i32, label: []const u8 };
    pub const props_schema: []const u8 = "{\"initial\":\"i32\",\"label\":\"string\"}";
};
