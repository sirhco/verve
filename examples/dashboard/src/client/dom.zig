//! JS env imports the dashboard wasm relies on.

pub extern "verve" fn set_text_by_bind(
    bind_ptr: [*]const u8,
    bind_len: usize,
    text_ptr: [*]const u8,
    text_len: usize,
) void;

pub extern "verve" fn reload_page() void;

// ---- SSE ----------------------------------------------------------------

pub extern "verve" fn sse_open() void;
pub extern "verve" fn sse_close() void;

// ---- WebSocket ---------------------------------------------------------

pub extern "verve" fn ws_open() void;
pub extern "verve" fn ws_close() void;
pub extern "verve" fn ws_send(ptr: [*]const u8, len: usize) void;

// ---- Theme -------------------------------------------------------------

pub extern "verve" fn theme_apply(ptr: [*]const u8, len: usize) void;
pub extern "verve" fn theme_persist(ptr: [*]const u8, len: usize) void;
/// Reads the stored theme into the supplied buffer; returns the number of
/// bytes written (0 if no theme stored).
pub extern "verve" fn theme_load(buf_ptr: [*]u8, buf_cap: usize) usize;

// ---- Palette + modal --------------------------------------------------

pub extern "verve" fn palette_show() void;
pub extern "verve" fn palette_hide() void;
pub extern "verve" fn palette_apply_filter(ptr: [*]const u8, len: usize) void;
pub extern "verve" fn palette_render_selection(idx: i32) void;
pub extern "verve" fn palette_visible_count() i32;
pub extern "verve" fn palette_activate(idx: i32) void;
pub extern "verve" fn focus_search() void;

// ---- Search filter ----------------------------------------------------

pub extern "verve" fn search_apply(ptr: [*]const u8, len: usize) i32;

// ---- Carousel pagination ---------------------------------------------

pub extern "verve" fn carousel_render(idx: i32, page: i32) void;
