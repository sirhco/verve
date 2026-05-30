//! Interactive client-runtime probe island.
//!
//! Exercises every v0.1.30 wasm primitive with *visible* feedback: each
//! button is a closure handler registered in `hydrate` (the only dispatch
//! path that reaches an island chunk — the bridge's string-action click
//! delegate only sees the main client's exports, so chunk handlers must go
//! through `registerEvent` → `z-on-click-id` → `verve_event_dispatch` over
//! the shared indirect function table).
//!
//! Registration order below is the contract: the SSR stamps
//! `z-on-click-id="0..3"` / `z-on-keydown-id="4"` to match. Two reactive
//! binds drive the UI — `json_probe_count` (i32) and `json_probe_status`
//! (str) — so every action produces something you can watch change.

const verve = @import("verve");

const COUNT: []const u8 = "json_probe_count";
const STATUS: []const u8 = "json_probe_status";
const ROUTE: []const u8 = "json_probe";

const Reply = struct { count: i32, title: []const u8, pinned: bool };

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = props_ptr;
    _ = props_len;
    _ = root_id;
    verve.registerI32(COUNT, 0);
    verve.registerStr(STATUS, "ready — click a button");
    verve.registerResponseHandler(ROUTE, onReply);
    // Order defines the z-on-click-id / z-on-keydown-id stamps in the SSR.
    _ = verve.registerEvent(&onRefresh); // 0 — Phase 17 typed IPC
    _ = verve.registerEvent(&onCaps); //    1 — Phase 19 timers/storage/clipboard
    _ = verve.registerEvent(&onHost); //    2 — Phase 21 JS interop
    _ = verve.registerEvent(&onForm); //    3 — Phase 20 forms/measurement
    _ = verve.registerEvent(&onKeydown); // 4 — Phase 18 events-with-data
    verve.registerDrop("json_probe_drop", &onDrop); // Phase 22 chunk arena
}

/// Phase 17 — fire the typed-IPC request; the reply updates the count bind.
fn onRefresh() void {
    verve.signalSetStr(STATUS, "POST /api/json_probe …");
    verve.serverFnPost(ROUTE, "{}");
}

fn onReply(ptr: [*]const u8, len: u32) void {
    const doc = verve.parseJson(ptr[0..len]) orelse {
        verve.signalSetStr(STATUS, "reply: parse failed");
        return;
    };
    defer doc.free();
    // Server-fn replies are enveloped as `{"value": <return>}`.
    const body = doc.get("value") orelse doc;
    if (body.get("count")) |c| verve.signalSetI32(COUNT, @intCast(c.int()));

    const mark = verve.chunkArenaMark();
    defer verve.chunkArenaReset(mark);
    const reply = verve.readStruct(Reply, body, verve.chunkArena()) catch {
        verve.signalSetStr(STATUS, "reply read via accessor");
        return;
    };
    if (reply.pinned) {
        verve.signalSetStr(STATUS, "typed reply ok (readStruct)");
    } else {
        verve.signalSetStr(STATUS, "typed reply ok");
    }
}

/// Phase 19 — timers / storage / clipboard.
fn onCaps() void {
    verve.storage.set("json_probe_seen", "1");
    var sbuf: [8]u8 = undefined;
    const seen = verve.storage.get("json_probe_seen", &sbuf);
    verve.clipboardWrite("copied from verve wasm");
    _ = verve.setTimeout(0, &tick);
    if (seen.len > 0) {
        verve.signalSetStr(STATUS, "localStorage set + clipboard written (paste to confirm)");
    } else {
        verve.signalSetStr(STATUS, "caps ran");
    }
}

/// Phase 21 — JS interop hatch (sync + async).
fn onHost() void {
    var out: [256]u8 = undefined;
    _ = verve.host("fmtDate", "{\"ms\":0}", &out);
    verve.hostAsync("renderMd", "{\"text\":\"# hi\"}", "json_probe_md");
    verve.signalSetStr(STATUS, "called window.verveHost.fmtDate / renderMd (register them in console)");
}

/// Phase 20 — forms + DOM measurement. Shows the collected form JSON.
fn onForm() void {
    _ = verve.viewport();
    _ = verve.matchMedia("(prefers-color-scheme: dark)");
    var fbuf: [256]u8 = undefined;
    const json = verve.formCollect("json_probe_form", &fbuf);
    verve.signalSetStr(STATUS, json);
}

/// Phase 18 — events with data. ⌘K / Ctrl+K refires the typed-IPC request.
fn onKeydown() void {
    const mods = verve.eventMods();
    var kb: [16]u8 = undefined;
    const key = verve.eventKey(&kb);
    if ((mods.meta or mods.ctrl) and key.len == 1 and (key[0] == 'k' or key[0] == 'K')) {
        verve.eventPreventDefault();
        onRefresh();
    } else {
        verve.signalSetStr(STATUS, "keydown captured (press Cmd/Ctrl+K to refresh)");
    }
}

/// Phase 22 — chunk arena + drag-drop.
fn onDrop() void {
    var name_buf: [256]u8 = undefined;
    const drop = verve.currentDrop(&name_buf);
    if (drop.name.len > 0) {
        verve.signalSetStr(STATUS, drop.name);
    } else {
        verve.signalSetStr(STATUS, "file dropped");
    }
}

fn tick() void {}
