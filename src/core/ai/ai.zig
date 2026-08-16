//! `verve.ai` — expose typed app functions to a language model as tools.
//!
//! Default-deny: a function is callable by a model only if it appears in an
//! explicit `[]const ToolDecl` allowlist. See `docs/25-ai.md`.

pub const Risk = @import("tool.zig").Risk;
pub const ArgDoc = @import("tool.zig").ArgDoc;
pub const ToolDecl = @import("tool.zig").ToolDecl;
pub const jsonSchema = @import("schema.zig").jsonSchema;
pub const Registry = @import("registry.zig").Registry;
pub const Policy = @import("policy.zig").Policy;
pub const ToolOutcome = @import("registry.zig").ToolOutcome;
pub const audit = @import("audit.zig");
/// Exposes `policy.initRandom(io)` — call once at host startup (server or
/// desktop) to seed the confirmation-token key, next to the CSRF key init.
/// Without it, dangerous tools stay unconfirmable (`IssueError.Unseeded`)
/// rather than falling back to a predictable token source.
pub const policy = @import("policy.zig");

pub const Message = @import("message.zig").Message;
pub const Provider = @import("provider.zig").Provider;
pub const MockProvider = @import("mock_provider.zig").MockProvider;
pub const run = @import("agent.zig").run;

test {
    _ = @import("tool.zig");
    _ = @import("schema.zig");
    _ = @import("registry.zig");
    _ = @import("policy.zig");
    _ = @import("audit.zig");
    _ = @import("message.zig");
    _ = @import("provider.zig");
    _ = @import("mock_provider.zig");
    _ = @import("agent.zig");
}
