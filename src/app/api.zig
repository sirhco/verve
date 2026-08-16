//! "Zerver" actions — functions that run on the server and are callable from
//! the client. Server's api_handler walks `Actions` at comptime to generate
//! `/api/<fn_name>` routes.

const std = @import("std");
const verve = @import("verve");

pub const components = @import("components.zig");
pub const islands = @import("islands.zig");
pub const routes_mod = @import("routes.zig");
pub const Route = routes_mod.Route;
pub const routes = routes_mod.routes;
pub const ai = @import("ai.zig");

const log = std.log.scoped(.verve);

/// Shared server-side counter. Atomic — the server may run actions on
/// multiple worker threads.
pub var last_count: std.atomic.Value(i32) = .init(0);

pub fn currentCount() i32 {
    return last_count.load(.monotonic);
}

const TODO_MAX = 32;
const TODO_TEXT_MAX = 200;

// Fixed pool of slots — each holds up to TODO_TEXT_MAX bytes plus the active
// length. Avoids needing a heap allocator inside Action functions while still
// supporting append + remove for the demo.
var todo_slots: [TODO_MAX][TODO_TEXT_MAX]u8 = undefined;
var todo_lens: [TODO_MAX]usize = .{0} ** TODO_MAX;
var todo_count: usize = 0;
var todo_mu: std.atomic.Mutex = .unlocked;

fn lockTodos() void {
    while (!todo_mu.tryLock()) std.atomic.spinLoopHint();
}

/// Caller-owned snapshot of the current todo list into `arena`. Strings are
/// duped so the snapshot stays valid after the mutex is released.
pub fn copyTodosInto(arena: std.mem.Allocator) ![]const []const u8 {
    lockTodos();
    defer todo_mu.unlock();

    const out = try arena.alloc([]const u8, todo_count);
    for (0..todo_count) |i| {
        out[i] = try arena.dupe(u8, todo_slots[i][0..todo_lens[i]]);
    }
    return out;
}

pub const VizNode = struct { id: []const u8, label: []const u8 };
pub const VizEdge = struct { from: []const u8, to: []const u8 };
/// Pull snapshot, now seq-stamped so push deltas and pull resyncs share one
/// ordering domain: a client applies a delta only when `seq` is exactly one
/// past its last-seen snapshot/delta.
pub const VizSnapshot = struct { seq: u64, nodes: []const VizNode, edges: []const VizEdge };

/// The live-graph demo model: 3 stable base nodes plus 0..3 ephemeral ones.
/// `viz_extra` is the whole state; the server-side publisher loop advances it
/// (cycling extra 0→3) and broadcasts the diff as a wire delta, bumping
/// `viz_seq` in lockstep. `vizGraph` only snapshots — it never mutates.
var viz_mu: std.atomic.Mutex = .unlocked;
var viz_seq: u64 = 0;
var viz_extra: u32 = 0;

fn lockViz() void {
    while (!viz_mu.tryLock()) std.atomic.spinLoopHint();
}

/// Reset the evolving model (tests).
pub fn resetVizModel() void {
    lockViz();
    defer viz_mu.unlock();
    viz_seq = 0;
    viz_extra = 0;
}

const VIZ_EPH_IDS = [_][]const u8{ "e0", "e1", "e2" };

/// Fill `nodes`/`edges` with the graph for `extra` ephemeral nodes. All
/// strings are literals, so the filled slices are stable forever.
fn vizBuild(extra: u32, nodes: *[8]verve.viz.GraphNode, edges: *[8]verve.viz.GraphEdge) struct { n: usize, e: usize } {
    nodes[0] = .{ .id = "core", .label = "core" };
    nodes[1] = .{ .id = "io", .label = "io" };
    nodes[2] = .{ .id = "ui", .label = "ui" };
    edges[0] = .{ .from = "core", .to = "io" };
    edges[1] = .{ .from = "core", .to = "ui" };
    var nc: usize = 3;
    var ec: usize = 2;
    var i: usize = 0;
    while (i < extra) : (i += 1) {
        nodes[nc] = .{ .id = VIZ_EPH_IDS[i], .label = VIZ_EPH_IDS[i] };
        edges[ec] = .{ .from = "core", .to = VIZ_EPH_IDS[i] };
        nc += 1;
        ec += 1;
    }
    return .{ .n = nc, .e = ec };
}

/// Advance the demo model one step and serialize the resulting wire delta
/// (`{"seq":N,"ops":[...]}`) into `buf`. The server's publisher loop calls
/// this once per second while the `viz` push channel has subscribers, then
/// publishes the frame. Null when serialization fails (frame > buf).
pub fn vizAdvanceTick(buf: []u8) ?[]const u8 {
    lockViz();
    defer viz_mu.unlock();

    var old_nodes: [8]verve.viz.GraphNode = undefined;
    var old_edges: [8]verve.viz.GraphEdge = undefined;
    const old = vizBuild(viz_extra, &old_nodes, &old_edges);

    const next_extra = (viz_extra + 1) % 4;
    var new_nodes: [8]verve.viz.GraphNode = undefined;
    var new_edges: [8]verve.viz.GraphEdge = undefined;
    const new = vizBuild(next_extra, &new_nodes, &new_edges);

    var ops_buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&ops_buf);
    const ops = verve.viz.diffGraphs(
        fba.allocator(),
        old_nodes[0..old.n],
        old_edges[0..old.e],
        new_nodes[0..new.n],
        new_edges[0..new.e],
    ) catch return null;

    const frame = verve.viz.writeDeltaJson(buf, viz_seq + 1, ops) catch return null;
    viz_extra = next_extra;
    viz_seq += 1;
    return frame;
}

// Per-thread snapshot storage: `vizGraph` returns slices into these, serialized
// on the same thread by the api_handler → no cross-thread race, no allocator.
threadlocal var tl_nodes: [8]VizNode = undefined;
threadlocal var tl_edges: [8]VizEdge = undefined;

// ---- AI chat demo (Task 8) -------------------------------------------

/// System prompt for the `/ai-chat` demo's agent turns.
const ai_system =
    \\You help the user manage a todo list and a counter in this demo app.
    \\Use the provided tools rather than guessing at state. Keep replies short.
;

/// Sourced from `anthropic.Client`'s own default field, not restated as a
/// second literal — Task 6's fix round made `Client.model` the one place
/// this app's default model name lives (`provider.Request.model` is `null`
/// by default precisely so callers don't have to repeat it). Used for both
/// the live and the mock provider, so a script that doesn't care what model
/// string it's handed (`MockProvider.complete` ignores `req.model`) still
/// reads as "whatever this app's default model is," not a hardcoded guess.
const default_ai_model: []const u8 = (verve.ai.anthropic.Client{}).model;

/// Scripted turns for the CI integration test and any offline run of the
/// demo: one tool call, then a summary. Selected by `ai.mockEnabled()`
/// (`VERVE_AI_MOCK` in the captured environment) instead of a live
/// Anthropic call — no API key, no network, deterministic reply.
const mock_turns = [_]verve.ai.message.Response{
    .{
        .stop_reason = .tool_use,
        .blocks = &.{.{ .tool_use = .{ .id = "toolu_mock1", .name = "getCount", .input_json = "{}" } }},
    },
    .{
        .stop_reason = .end_turn,
        .blocks = &.{.{ .text = "The counter is available via getCount." }},
    },
};

/// Threadlocal scratch for `aiChat`'s reply text. The api_handler
/// serializes the return value on this same request thread immediately
/// after `Actions.aiChat` returns (see `tl_nodes`/`tl_edges` above for the
/// identical pattern) — no allocator, no cross-thread race, and nothing to
/// free. A `page_allocator.dupe` here would leak: nothing on this path ever
/// frees a server-action return value.
const AI_REPLY_MAX = 4096;
threadlocal var tl_ai_reply: [AI_REPLY_MAX]u8 = undefined;

/// Largest prefix of `text` no longer than `max` that doesn't split a
/// multi-byte UTF-8 codepoint. Mirrors `core/ai/registry.zig`'s internal
/// `utf8SafeCut` (not exported, and small enough not to be worth exporting
/// just for this one call site).
fn utf8SafeCut(text: []const u8, max: usize) usize {
    var cut = @min(text.len, max);
    while (cut > 0 and !std.unicode.utf8ValidateSlice(text[0..cut])) cut -= 1;
    return cut;
}

pub const Actions = struct {
    /// Current graph snapshot for the live-data demo, seq-stamped. Pure read:
    /// the model only changes when the publisher loop ticks it (which it does
    /// only while the `viz` push channel has subscribers), so pull-only
    /// clients see a stable graph and push clients resync coherently.
    pub fn vizGraph(_: struct {}) VizSnapshot {
        lockViz();
        const extra = viz_extra;
        const seq = viz_seq;
        viz_mu.unlock();

        var nodes: [8]verve.viz.GraphNode = undefined;
        var edges: [8]verve.viz.GraphEdge = undefined;
        const counts = vizBuild(extra, &nodes, &edges);
        for (nodes[0..counts.n], 0..) |nd, i| tl_nodes[i] = .{ .id = nd.id, .label = nd.label };
        for (edges[0..counts.e], 0..) |e, i| tl_edges[i] = .{ .from = e.from, .to = e.to };
        return .{ .seq = seq, .nodes = tl_nodes[0..counts.n], .edges = tl_edges[0..counts.e] };
    }

    pub fn updateDatabase(args: struct { new_count: i32 }) !void {
        last_count.store(args.new_count, .monotonic);
        log.info("updateDatabase: new_count={d}", .{args.new_count});
    }

    pub fn logMessage(args: struct { text: []const u8 }) !void {
        log.info("logMessage: {s}", .{args.text});
    }

    pub fn getCount(_: struct {}) !i32 {
        return last_count.load(.monotonic);
    }

    /// Value-returning string action — backs the `fetchSignal([]const u8, ...)`
    /// demo in `src/client/islands/JsonProbe.zig`.
    pub fn appName(_: struct {}) []const u8 {
        return "verve";
    }

    pub fn incrementCount(_: struct {}) i32 {
        return last_count.fetchAdd(1, .monotonic) + 1;
    }

    pub fn decrementCount(_: struct {}) i32 {
        return last_count.fetchSub(1, .monotonic) - 1;
    }

    pub fn addTodo(args: struct { text: []const u8 }) !void {
        const trimmed = std.mem.trim(u8, args.text, &std.ascii.whitespace);
        if (trimmed.len == 0) return error.EmptyTodo;

        lockTodos();
        defer todo_mu.unlock();

        if (todo_count >= TODO_MAX) return error.TodoListFull;
        const len = @min(trimmed.len, TODO_TEXT_MAX);
        @memcpy(todo_slots[todo_count][0..len], trimmed[0..len]);
        todo_lens[todo_count] = len;
        todo_count += 1;
        log.info("addTodo: idx={d} text={s}", .{ todo_count - 1, trimmed[0..len] });
    }

    pub fn removeTodo(args: struct { index: usize }) !void {
        lockTodos();
        defer todo_mu.unlock();

        if (args.index >= todo_count) return error.OutOfRange;
        var i = args.index;
        while (i + 1 < todo_count) : (i += 1) {
            const next_len = todo_lens[i + 1];
            @memcpy(todo_slots[i][0..next_len], todo_slots[i + 1][0..next_len]);
            todo_lens[i] = next_len;
        }
        todo_count -= 1;
        todo_lens[todo_count] = 0;
        log.info("removeTodo: idx={d}", .{args.index});
    }

    /// Run one agent turn over this app's tool allowlist (`ai.tools`).
    ///
    /// Synchronous on the request thread — non-streaming, bounded by
    /// `Policy.max_steps`. Streaming turns need the push hub and belong to a
    /// later cluster.
    ///
    /// Security: no API key and no confirmation token ever appear in the
    /// return value. `verve.ai.run` never lets a confirmation token reach
    /// the provider (see `core/ai/agent.zig`'s module doc comment), and
    /// this demo's allowlist declares nothing `.dangerous`, so no token is
    /// ever minted on this path in the first place. `anthropic.Client`
    /// never logs or echoes the API key (see `resolveApiKey`); on failure
    /// this function only ever returns/propagates an error *name*.
    pub fn aiChat(args: struct { prompt: []const u8 }) ![]const u8 {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const Reg = verve.ai.Registry(Actions, ai.tools);
        const p: verve.ai.Policy = .{ .max_steps = 6 };

        var convo: std.ArrayList(verve.ai.Message) = .empty;
        try convo.append(a, .{
            .role = .user,
            .blocks = &.{.{ .text = args.prompt }},
        });

        // VERVE_AI_MOCK selects the scripted MockProvider instead of a live
        // Anthropic call — the whole point is letting the integration suite
        // exercise this route with no API key and no network. See
        // ai.mockEnabled and src/server/main.zig's initEnviron call.
        const outcome = if (ai.mockEnabled()) blk: {
            var mock: verve.ai.MockProvider = .{ .turns = &mock_turns };
            break :blk try verve.ai.run(a, mock.provider(), Reg, p, &convo, ai_system, default_ai_model);
        } else blk: {
            var client: verve.ai.anthropic.Client = .{};
            break :blk try verve.ai.run(a, client.provider(), Reg, p, &convo, ai_system, default_ai_model);
        };

        if (outcome.stopped == .refusal) return "The model declined this request.";

        const text = outcome.text;
        if (text.len <= tl_ai_reply.len) {
            @memcpy(tl_ai_reply[0..text.len], text);
            return tl_ai_reply[0..text.len];
        }

        // Reply exceeds the fixed scratch buffer: truncate explicitly with
        // a visible marker rather than silently (see tl_ai_reply's doc
        // comment for why this isn't a page_allocator.dupe instead).
        const marker = " [truncated]";
        const room = utf8SafeCut(text, tl_ai_reply.len - marker.len);
        @memcpy(tl_ai_reply[0..room], text[0..room]);
        @memcpy(tl_ai_reply[room .. room + marker.len], marker);
        return tl_ai_reply[0 .. room + marker.len];
    }
};

test "vizGraph snapshots are stable and edge endpoints resolve" {
    resetVizModel();
    const a = Actions.vizGraph(.{});
    try std.testing.expectEqual(@as(u64, 0), a.seq);
    try std.testing.expect(a.nodes.len >= 3);
    var has_core = false;
    for (a.nodes) |nd| {
        if (std.mem.eql(u8, nd.id, "core")) has_core = true;
    }
    try std.testing.expect(has_core);
    for (a.edges) |e| {
        var ff = false;
        var tt = false;
        for (a.nodes) |nd| {
            if (std.mem.eql(u8, nd.id, e.from)) ff = true;
            if (std.mem.eql(u8, nd.id, e.to)) tt = true;
        }
        try std.testing.expect(ff and tt);
    }
    // Pull is a pure read: repeated snapshots don't change the graph.
    const b = Actions.vizGraph(.{});
    try std.testing.expectEqual(a.nodes.len, b.nodes.len);
    try std.testing.expectEqual(a.seq, b.seq);
}

test "vizAdvanceTick emits seq-ordered deltas that transform the snapshot" {
    resetVizModel();
    const before = Actions.vizGraph(.{});
    const before_n = before.nodes.len;

    var buf: [4096]u8 = undefined;
    const f1 = vizAdvanceTick(&buf) orelse return error.TestExpectedEqual;
    try std.testing.expect(std.mem.startsWith(u8, f1, "{\"seq\":1,\"ops\":["));
    // extra 0→1 adds one node + one edge
    try std.testing.expect(std.mem.indexOf(u8, f1, "\"op\":\"+n\",\"id\":\"e0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, f1, "\"op\":\"+e\"") != null);

    const after = Actions.vizGraph(.{});
    try std.testing.expectEqual(@as(u64, 1), after.seq);
    try std.testing.expectEqual(before_n + 1, after.nodes.len);

    var buf2: [4096]u8 = undefined;
    const f2 = vizAdvanceTick(&buf2) orelse return error.TestExpectedEqual;
    try std.testing.expect(std.mem.startsWith(u8, f2, "{\"seq\":2,\"ops\":["));

    // Cycle wraps: two more ticks reach extra=3, the next removes all three.
    _ = vizAdvanceTick(&buf).?;
    const wrap = vizAdvanceTick(&buf).?;
    try std.testing.expect(std.mem.indexOf(u8, wrap, "\"op\":\"-n\",\"id\":\"e0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, wrap, "\"op\":\"-n\",\"id\":\"e2\"") != null);
    const wrapped = Actions.vizGraph(.{});
    try std.testing.expectEqual(before_n, wrapped.nodes.len);
}

// Pull viz_data, viz_live, and ai tests into the app test suite.
test {
    _ = @import("viz_data.zig");
    _ = @import("viz_live.zig");
    _ = @import("ai.zig");
}

// ---------------------------------------------------------------------------
// Live canvas graph — re-exported from viz_live.zig so the app module surface
// presents `vizCanvasAdvanceTick` and `packLiveGraph` to main.zig.
// ---------------------------------------------------------------------------
const viz_live = @import("viz_live.zig");
pub const vizCanvasAdvanceTick = viz_live.vizCanvasAdvanceTick;
pub const packLiveGraph = viz_live.packLiveGraph;
