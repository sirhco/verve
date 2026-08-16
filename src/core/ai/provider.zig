//! Provider abstraction. Two implementations ship: the Anthropic Messages API
//! (`anthropic.zig`) and the Claude Code CLI (`../../desktop/ai_cli.zig`).
//! They differ in kind, not just transport — see `native_tools`.

const std = @import("std");
const message = @import("message.zig");

pub const Usage = struct { input_tokens: u32 = 0, output_tokens: u32 = 0 };

pub const Capabilities = struct {
    /// True when the provider accepts a tool list and returns `tool_use`
    /// blocks this framework is expected to execute. False for delegating
    /// providers that run their own tools in their own sandbox.
    native_tools: bool,
    streaming: bool = false,
};

pub const Request = struct {
    model: []const u8,
    system: []const u8 = "",
    messages: []const message.Message,
    /// Anthropic-format tool array, or "[]" for none.
    tools_json: []const u8 = "[]",
    max_tokens: u32 = 4096,
};

pub const Response = struct {
    stop_reason: message.StopReason,
    blocks: []const message.Block,
    usage: Usage = .{},
};

pub const Provider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        capabilities: *const fn (ptr: *anyopaque) Capabilities,
        complete: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, req: Request) anyerror!Response,
    };

    pub fn capabilities(self: Provider) Capabilities {
        return self.vtable.capabilities(self.ptr);
    }
    pub fn complete(self: Provider, arena: std.mem.Allocator, req: Request) anyerror!Response {
        return self.vtable.complete(self.ptr, arena, req);
    }
};
