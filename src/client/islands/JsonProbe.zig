//! Phase 17 — typed-IPC probe island.
//!
//! Demonstrates the full chunk-side request → typed-reply loop without a
//! hand-rolled JSON scanner:
//!
//!   * `serverFnPost(route, body)` fires the request.
//!   * a registered response handler receives the raw reply bytes.
//!   * `parseJson` + `JsonDoc` accessors read scalars with zero chunk
//!     allocation; `readStruct` materializes a typed `Reply` (its string
//!     field exercises the arena path).
//!
//! The parser itself lives once in the main client (`json_service.zig`)
//! — this chunk only carries the thin `verve_json_*` externs, so it
//! stays small.

const verve = @import("verve");

const COUNT_BIND: []const u8 = "json_probe_count";
const ROUTE: []const u8 = "json_probe";

/// Shape the server replies with. Scalars read directly; `title` is
/// allocated from the per-dispatch arena below.
const Reply = struct {
    count: i32,
    title: []const u8,
    pinned: bool,
};

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = props_ptr;
    _ = props_len;
    _ = root_id;
    verve.registerI32(COUNT_BIND, 0);
    verve.registerResponseHandler(ROUTE, onReply);
    // Slot id would be stamped onto the SSR'd element as
    // `z-on-keydown-id`; registering here wires the closure handler.
    _ = verve.registerEvent(&onKeydown);
    verve.registerDrop("json_probe_drop", &onDrop);
}

/// Drop handler — reads the dropped file out of the chunk arena.
fn onDrop() void {
    var name_buf: [256]u8 = undefined;
    const drop = verve.currentDrop(&name_buf);
    _ = drop;
}

/// Stamped via `[z-on-click="json_probe_refresh"]`.
export fn json_probe_refresh() void {
    verve.serverFnPost(ROUTE, "{}");
}

/// Closure keydown handler (registered in `hydrate`, stamped via
/// `z-on-keydown-id`). Reads the staged event: ⌘K / Ctrl+K refreshes;
/// the clicked row's `data-id` is read via the target dataset.
fn onKeydown() void {
    const mods = verve.eventMods();
    var key_buf: [16]u8 = undefined;
    const key = verve.eventKey(&key_buf);
    if ((mods.meta or mods.ctrl) and key.len == 1 and (key[0] == 'k' or key[0] == 'K')) {
        verve.eventPreventDefault();
        verve.serverFnPost(ROUTE, "{}");
    }
    var id_buf: [64]u8 = undefined;
    const id = verve.eventTargetAttr("id", &id_buf);
    _ = id;
}

fn tick() void {}

/// Exercises the Phase 21 JS-interop hatch (sync + async).
export fn json_probe_host() void {
    var out: [256]u8 = undefined;
    const res = verve.host("fmtDate", "{\"ms\":0}", &out);
    if (verve.parseJson(res)) |doc| doc.free();
    verve.hostAsync("renderMd", "{\"text\":\"# hi\"}", "json_probe_md");
}

/// Exercises the Phase 19 capability wrappers (timers / storage /
/// clipboard). Exported so the chunk build links the externs.
export fn json_probe_demo_caps() void {
    verve.storage.set("json_probe_seen", "1");
    var sbuf: [8]u8 = undefined;
    _ = verve.storage.get("json_probe_seen", &sbuf);
    _ = verve.storage.len("json_probe_seen");
    verve.storage.remove("json_probe_seen");
    verve.clipboardWrite("copied");
    const tid = verve.setTimeout(1000, &tick);
    verve.clearTimer(tid);
    _ = verve.setInterval(5000, &tick);
    _ = verve.requestAnimationFrame(&tick);
    verve.queueMicrotask(&tick);
}

/// Exercises the Phase 20 form + measurement wrappers.
export fn json_probe_form() void {
    const input_ref: []const u8 = "json_probe_input";
    const h = verve.queryRef(input_ref) orelse return;
    var vbuf: [64]u8 = undefined;
    _ = verve.refValueStr(h, &vbuf);
    verve.refSelect(h);
    verve.refBlur(h);
    verve.refScrollIntoView(h);
    verve.refRequestSubmit(h);
    _ = verve.refRect(h);
    _ = verve.viewport();
    _ = verve.matchMedia("(prefers-color-scheme: dark)");
    var fbuf: [256]u8 = undefined;
    const json = verve.formCollect("json_probe_form", &fbuf);
    if (verve.parseJson(json)) |doc| doc.free();
}

fn onReply(ptr: [*]const u8, len: u32) void {
    const doc = verve.parseJson(ptr[0..len]) orelse return;
    defer doc.free();

    // Accessor style — no chunk allocation.
    if (doc.get("count")) |c| {
        verve.signalSetI32(COUNT_BIND, @intCast(c.int()));
    }

    // Typed style — one struct read; `title` lands in the chunk arena,
    // recycled per dispatch (no worst-case static buffer).
    const arena_mark = verve.chunkArenaMark();
    defer verve.chunkArenaReset(arena_mark);
    const reply = verve.readStruct(Reply, doc, verve.chunkArena()) catch return;
    verve.signalSetI32(COUNT_BIND, reply.count);
}
