//! Dashboard wasm client.
//!
//! Owns client-side state that doesn't belong on the server:
//!
//!   - Live freshness clocks (tick every second).
//!   - SSE connection lifecycle + event accounting.
//!   - Command palette state + fuzzy filter.
//!   - Theme cycle + persistence delegated to JS localStorage.
//!   - Disney carousel pagination cursor.
//!   - Drag-and-drop bookkeeping for the kanban.
//!   - WebSocket session for the /live chat page.
//!
//! Each export is one of: a hydrate entry point (`verve_hydrate`,
//! `verve_init_ages`), a click handler (`palette_open`, `theme_cycle`, …),
//! or a callback invoked by JS (`on_sse_event`, `on_ws_message`).

const std = @import("std");
const dom = @import("dom.zig");

var heap: [16 * 1024]u8 = undefined;
var fba: std.heap.FixedBufferAllocator = .init(&heap);

// ---- freshness clocks --------------------------------------------------

var freshness_seconds: i32 = 0;
var chuck_age: i32 = 0;
var carbon_age: i32 = 0;
var disney_age: i32 = 0;
var refresh_count: i32 = 0;

const FRESHNESS_BIND = "freshness";
const CHUCK_AGE_BIND = "chuck_age";
const CARBON_AGE_BIND = "carbon_age";
const DISNEY_AGE_BIND = "disney_age";
const REFRESH_BIND = "refresh_count";

// ---- SSE state --------------------------------------------------------

var sse_connected: bool = false;
var sse_events: i32 = 0;
var sse_last_seq: i32 = 0;
var sse_have_seq: bool = false;
var sse_mutations: i32 = 0;

const SSE_STATUS_BIND = "sse_status";
const SSE_EVENTS_BIND = "sse_events";
const SSE_LAST_BIND = "sse_last_seq";
const SSE_MUTATIONS_BIND = "sse_mutations";

// ---- theme ------------------------------------------------------------

const Theme = enum(u8) { dark = 0, light = 1, auto = 2 };
var theme: Theme = .dark;

const THEME_BIND = "theme_label";
const THEME_DARK: []const u8 = "dark";
const THEME_LIGHT: []const u8 = "light";
const THEME_AUTO: []const u8 = "auto";

fn themeSlug() []const u8 {
    return switch (theme) {
        .dark => THEME_DARK,
        .light => THEME_LIGHT,
        .auto => THEME_AUTO,
    };
}

fn applyTheme() void {
    const slug = themeSlug();
    dom.theme_apply(slug.ptr, slug.len);
    dom.theme_persist(slug.ptr, slug.len);
    emitStr(THEME_BIND, themeLabel());
}

fn themeLabel() []const u8 {
    return switch (theme) {
        .dark => "theme: dark",
        .light => "theme: light",
        .auto => "theme: auto",
    };
}

// ---- palette ----------------------------------------------------------

var palette_open_state: bool = false;
var palette_filter_buf: [128]u8 = undefined;
var palette_filter_len: usize = 0;
var palette_cursor: i32 = 0;

const PALETTE_COUNT_BIND = "palette_count";

// ---- carousel ---------------------------------------------------------

var disney_cursor: i32 = 0;
var disney_page: i32 = 0;
const DISNEY_PAGE_SIZE: i32 = 6;

// ---- ws --------------------------------------------------------------

var ws_connected: bool = false;
const WS_STATUS_BIND = "ws_status";

// ---- search ---------------------------------------------------------

const SEARCH_COUNT_BIND = "search_count";

// ---- emit helpers ----------------------------------------------------

fn emitAge(bind: []const u8, secs: i32) void {
    fba.reset();
    const alloc = fba.allocator();
    const text = renderAge(alloc, secs) catch "?";
    dom.set_text_by_bind(bind.ptr, bind.len, text.ptr, text.len);
}

fn emitInt(bind: []const u8, n: i32) void {
    fba.reset();
    const alloc = fba.allocator();
    const text = std.fmt.allocPrint(alloc, "{d}", .{n}) catch return;
    dom.set_text_by_bind(bind.ptr, bind.len, text.ptr, text.len);
}

fn emitStr(bind: []const u8, s: []const u8) void {
    dom.set_text_by_bind(bind.ptr, bind.len, s.ptr, s.len);
}

fn emitFmt(bind: []const u8, comptime fmt: []const u8, args: anytype) void {
    fba.reset();
    const alloc = fba.allocator();
    const text = std.fmt.allocPrint(alloc, fmt, args) catch return;
    dom.set_text_by_bind(bind.ptr, bind.len, text.ptr, text.len);
}

fn renderAge(alloc: std.mem.Allocator, secs: i32) ![]u8 {
    if (secs < 0) return std.fmt.allocPrint(alloc, "soon", .{});
    if (secs < 60) return std.fmt.allocPrint(alloc, "{d}s ago", .{secs});
    const m = @divTrunc(secs, 60);
    const r = @rem(secs, 60);
    if (m < 60) return std.fmt.allocPrint(alloc, "{d}m {d}s ago", .{ m, r });
    const h = @divTrunc(m, 60);
    const mm = @rem(m, 60);
    return std.fmt.allocPrint(alloc, "{d}h {d}m ago", .{ h, mm });
}

fn emitSseAll() void {
    emitStr(SSE_STATUS_BIND, if (sse_connected) "connected" else "disconnected");
    emitInt(SSE_EVENTS_BIND, sse_events);
    if (sse_have_seq) emitInt(SSE_LAST_BIND, sse_last_seq) else emitStr(SSE_LAST_BIND, "—");
    emitInt(SSE_MUTATIONS_BIND, sse_mutations);
}

// ---- hydrate ---------------------------------------------------------

export fn verve_hydrate() void {
    // Read persisted theme before painting any binds.
    var buf: [16]u8 = undefined;
    const n = dom.theme_load(&buf, buf.len);
    if (n > 0) {
        const slug = buf[0..n];
        if (std.mem.eql(u8, slug, "light")) theme = .light;
        if (std.mem.eql(u8, slug, "auto")) theme = .auto;
        if (std.mem.eql(u8, slug, "dark")) theme = .dark;
    }
    applyTheme();

    emitAge(FRESHNESS_BIND, freshness_seconds);
    emitAge(CHUCK_AGE_BIND, chuck_age);
    emitAge(CARBON_AGE_BIND, carbon_age);
    emitAge(DISNEY_AGE_BIND, disney_age);
    emitInt(REFRESH_BIND, refresh_count);
    emitSseAll();
    emitStr(SEARCH_COUNT_BIND, "");

    connect_sse();
}

export fn verve_init_ages(server_age: i32, chuck: i32, carbon: i32, disney: i32, refresh: i32) void {
    freshness_seconds = server_age;
    chuck_age = chuck;
    carbon_age = carbon;
    disney_age = disney;
    refresh_count = refresh;
}

export fn tick() void {
    freshness_seconds +%= 1;
    chuck_age +%= 1;
    carbon_age +%= 1;
    disney_age +%= 1;
    emitAge(FRESHNESS_BIND, freshness_seconds);
    emitAge(CHUCK_AGE_BIND, chuck_age);
    emitAge(CARBON_AGE_BIND, carbon_age);
    emitAge(DISNEY_AGE_BIND, disney_age);
}

fn reset_freshness_internal() void {
    freshness_seconds = 0;
    chuck_age = 0;
    carbon_age = 0;
    disney_age = 0;
    refresh_count +%= 1;
    emitAge(FRESHNESS_BIND, freshness_seconds);
    emitAge(CHUCK_AGE_BIND, chuck_age);
    emitAge(CARBON_AGE_BIND, carbon_age);
    emitAge(DISNEY_AGE_BIND, disney_age);
    emitInt(REFRESH_BIND, refresh_count);
}

export fn reload() void {
    dom.reload_page();
}

// ---- SSE handlers ---------------------------------------------------

export fn connect_sse() void {
    if (sse_connected) return;
    sse_connected = true;
    emitSseAll();
    dom.sse_open();
}

export fn disconnect_sse() void {
    if (!sse_connected) return;
    sse_connected = false;
    emitSseAll();
    dom.sse_close();
}

export fn on_sse_event(seq: i32) void {
    sse_events +%= 1;

    if (!sse_have_seq) {
        sse_have_seq = true;
        sse_last_seq = seq;
        emitSseAll();
        return;
    }

    if (seq != sse_last_seq) {
        sse_mutations +%= 1;
        sse_last_seq = seq;
        reset_freshness_internal();
        emitSseAll();
        dom.reload_page();
        return;
    }

    if (@rem(sse_events, 5) == 0) emitSseAll();
}

export fn on_sse_error() void {
    sse_connected = false;
    emitSseAll();
}

// ---- theme ----------------------------------------------------------

export fn theme_cycle() void {
    theme = switch (theme) {
        .dark => .light,
        .light => .auto,
        .auto => .dark,
    };
    applyTheme();
}

// ---- palette --------------------------------------------------------

export fn palette_open() void {
    palette_open_state = true;
    palette_filter_len = 0;
    palette_cursor = 0;
    dom.palette_show();
    dom.palette_apply_filter(palette_filter_buf[0..palette_filter_len].ptr, palette_filter_len);
    dom.palette_render_selection(palette_cursor);
    emitPaletteCount();
}

export fn palette_close() void {
    palette_open_state = false;
    dom.palette_hide();
}

export fn palette_toggle() void {
    if (palette_open_state) palette_close() else palette_open();
}

/// JS forwards the input value here whenever the user types.
export fn palette_input(ptr: [*]const u8, len: usize) void {
    const n = @min(len, palette_filter_buf.len);
    @memcpy(palette_filter_buf[0..n], ptr[0..n]);
    palette_filter_len = n;
    palette_cursor = 0;
    dom.palette_apply_filter(palette_filter_buf[0..palette_filter_len].ptr, palette_filter_len);
    dom.palette_render_selection(palette_cursor);
    emitPaletteCount();
}

export fn palette_move(delta: i32) void {
    const total = dom.palette_visible_count();
    if (total <= 0) return;
    var next = palette_cursor + delta;
    if (next < 0) next = total - 1;
    if (next >= total) next = 0;
    palette_cursor = next;
    dom.palette_render_selection(palette_cursor);
}

export fn palette_enter() void {
    dom.palette_activate(palette_cursor);
}

fn emitPaletteCount() void {
    const total = dom.palette_visible_count();
    emitFmt(PALETTE_COUNT_BIND, "{d} matches", .{total});
}

// ---- search ----------------------------------------------------------

export fn search_input(ptr: [*]const u8, len: usize) void {
    const matched = dom.search_apply(ptr, len);
    if (len == 0) {
        emitStr(SEARCH_COUNT_BIND, "");
    } else {
        emitFmt(SEARCH_COUNT_BIND, "{d} match", .{matched});
    }
}

export fn focus_global_search() void {
    dom.focus_search();
}

// ---- carousel pagination ---------------------------------------------

export fn current_cursor() i32 {
    return disney_cursor;
}

export fn current_page() i32 {
    return disney_page;
}

export fn next_char() void {
    disney_cursor +%= 1;
    syncCarouselPage();
    dom.carousel_render(disney_cursor, disney_page);
}

export fn prev_char() void {
    disney_cursor -%= 1;
    syncCarouselPage();
    dom.carousel_render(disney_cursor, disney_page);
}

export fn next_page() void {
    disney_page +%= 1;
    disney_cursor = disney_page * DISNEY_PAGE_SIZE;
    dom.carousel_render(disney_cursor, disney_page);
}

export fn prev_page() void {
    disney_page -%= 1;
    disney_cursor = disney_page * DISNEY_PAGE_SIZE;
    dom.carousel_render(disney_cursor, disney_page);
}

fn syncCarouselPage() void {
    if (disney_cursor < 0) disney_cursor = 0;
    disney_page = @divTrunc(disney_cursor, DISNEY_PAGE_SIZE);
}

// ---- ws (live chat) --------------------------------------------------

export fn ws_connect() void {
    if (ws_connected) return;
    ws_connected = true;
    emitStr(WS_STATUS_BIND, "connecting…");
    dom.ws_open();
}

export fn ws_disconnect() void {
    if (!ws_connected) return;
    ws_connected = false;
    emitStr(WS_STATUS_BIND, "disconnected");
    dom.ws_close();
}

export fn on_ws_open() void {
    ws_connected = true;
    emitStr(WS_STATUS_BIND, "connected");
}

export fn on_ws_close() void {
    ws_connected = false;
    emitStr(WS_STATUS_BIND, "disconnected");
}

export fn ws_send(ptr: [*]const u8, len: usize) void {
    if (!ws_connected) return;
    dom.ws_send(ptr, len);
}
