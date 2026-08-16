//! `verve.ai` — expose typed app functions to a language model as tools.
//!
//! Default-deny: a function is callable by a model only if it appears in an
//! explicit `[]const ToolDecl` allowlist. See `docs/25-ai.md`.

pub const Risk = @import("tool.zig").Risk;
pub const ArgDoc = @import("tool.zig").ArgDoc;
pub const ToolDecl = @import("tool.zig").ToolDecl;
pub const jsonSchema = @import("schema.zig").jsonSchema;
pub const Registry = @import("registry.zig").Registry;

test {
    _ = @import("tool.zig");
    _ = @import("schema.zig");
    _ = @import("registry.zig");
}
