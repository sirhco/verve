//! DOM primitives — externs supplied by `src/bridge/verve.js` on the
//! wasm32-freestanding target, no-op stubs on native (so the same
//! source can run inside `zig build test`).
//!
//! Strings cross the WASM/JS boundary as `(ptr, len)` pairs because
//! wasm32 lacks native string types. New primitives added in Phase 12
//! mirror the same convention.

const builtin = @import("builtin");

const is_wasm = builtin.target.cpu.arch.isWasm();

const Bridge = if (is_wasm) WasmBridge else NativeStub;

const WasmBridge = struct {
    pub extern "verve" fn set_text_by_bind(
        bind_ptr: [*]const u8,
        bind_len: usize,
        text_ptr: [*]const u8,
        text_len: usize,
    ) void;

    pub extern "verve" fn set_text_by_bind_i32(
        bind_ptr: [*]const u8,
        bind_len: usize,
        value: i32,
    ) void;

    pub extern "verve" fn post_json_i32(
        path_ptr: [*]const u8,
        path_len: usize,
        field_ptr: [*]const u8,
        field_len: usize,
        value: i32,
    ) void;

    pub extern "verve" fn console_log_i32(value: i32) void;

    // ---- Phase 12 primitives ------------------------------------------------

    /// Set an attribute on every `[z-bind="<name>"]` element.
    pub extern "verve" fn set_attr_by_bind(
        bind_ptr: [*]const u8,
        bind_len: usize,
        attr_ptr: [*]const u8,
        attr_len: usize,
        value_ptr: [*]const u8,
        value_len: usize,
    ) void;

    /// Toggle a class on every `[z-bind="<name>"]` element. `on` is 1
    /// for add, 0 for remove.
    pub extern "verve" fn set_class_by_bind(
        bind_ptr: [*]const u8,
        bind_len: usize,
        class_ptr: [*]const u8,
        class_len: usize,
        on: u32,
    ) void;

    /// Replace `textContent` (string form) on every `[z-bind="<name>"]`
    /// element. Complements `set_text_by_bind_i32` for non-numeric T.
    pub extern "verve" fn set_text_by_bind_str(
        bind_ptr: [*]const u8,
        bind_len: usize,
        text_ptr: [*]const u8,
        text_len: usize,
    ) void;

    /// Set the `.value` property (form inputs / textareas) on every
    /// `[z-bind="<name>"]` element.
    pub extern "verve" fn set_value_by_bind(
        bind_ptr: [*]const u8,
        bind_len: usize,
        value_ptr: [*]const u8,
        value_len: usize,
    ) void;

    /// Remove every `[z-bind="<name>"]` element from the document.
    pub extern "verve" fn remove_by_bind(
        bind_ptr: [*]const u8,
        bind_len: usize,
    ) void;

    // ---- Phase 12C: keyed-list reconciler primitives ------------------------
    // Parent element is identified by its `z-bind` (or `data-vh`) name.
    // Children carry `data-vkey="<key>"`. `anchor_len == 0` means "append
    // to the end of the parent" (no insertBefore reference node).

    pub extern "verve" fn create_keyed_child(
        parent_ptr: [*]const u8,
        parent_len: usize,
        key_ptr: [*]const u8,
        key_len: usize,
        html_ptr: [*]const u8,
        html_len: usize,
        anchor_ptr: [*]const u8,
        anchor_len: usize,
    ) void;

    pub extern "verve" fn move_keyed_child(
        parent_ptr: [*]const u8,
        parent_len: usize,
        key_ptr: [*]const u8,
        key_len: usize,
        anchor_ptr: [*]const u8,
        anchor_len: usize,
    ) void;

    pub extern "verve" fn remove_keyed_child(
        parent_ptr: [*]const u8,
        parent_len: usize,
        key_ptr: [*]const u8,
        key_len: usize,
    ) void;

    // ---- Phase 12G: bool + f32 primitives ----------------------------------
    // bool drives a single CSS class toggle keyed by bind-name; f32 lands
    // as formatted text content. Both follow the same `(ptr, len, value)`
    // shape as their i32 counterparts.

    pub extern "verve" fn set_class_present_by_bind(
        bind_ptr: [*]const u8,
        bind_len: usize,
        class_ptr: [*]const u8,
        class_len: usize,
        on: u32,
    ) void;

    pub extern "verve" fn set_text_by_bind_f32(
        bind_ptr: [*]const u8,
        bind_len: usize,
        value: f32,
    ) void;

    // ---- Phase 11B: typed server-fn JSON POST -------------------------------
    // Fire-and-forget. `name` is the Action's bare identifier; the JS
    // bridge prepends `/api/`. Value returns are intentionally not
    // plumbed back yet — async response delivery lands with the
    // streaming runtime in a later phase.

    pub extern "verve" fn server_fn_post(
        name_ptr: [*]const u8,
        name_len: usize,
        body_ptr: [*]const u8,
        body_len: usize,
    ) void;

    // ---- NodeRef resolution -------------------------------------------------
    // `query_ref(id)` looks up the live `Element` server-rendered with
    // `data-ref="<id>"` and returns a JS-owned handle (>=1) the caller
    // can pass back to future per-handle mutation externs. A 0 return
    // means "no element matched" — caller decides whether that's a soft
    // miss (timing race against hydration) or a fatal bug.

    pub extern "verve" fn query_ref(
        id_ptr: [*]const u8,
        id_len: usize,
    ) i32;
};

const NativeStub = struct {
    pub fn set_text_by_bind(_: [*]const u8, _: usize, _: [*]const u8, _: usize) void {}
    pub fn set_text_by_bind_i32(_: [*]const u8, _: usize, _: i32) void {}
    pub fn post_json_i32(_: [*]const u8, _: usize, _: [*]const u8, _: usize, _: i32) void {}
    pub fn console_log_i32(_: i32) void {}
    pub fn set_attr_by_bind(_: [*]const u8, _: usize, _: [*]const u8, _: usize, _: [*]const u8, _: usize) void {}
    pub fn set_class_by_bind(_: [*]const u8, _: usize, _: [*]const u8, _: usize, _: u32) void {}
    pub fn set_text_by_bind_str(_: [*]const u8, _: usize, _: [*]const u8, _: usize) void {}
    pub fn set_value_by_bind(_: [*]const u8, _: usize, _: [*]const u8, _: usize) void {}
    pub fn remove_by_bind(_: [*]const u8, _: usize) void {}
    pub fn create_keyed_child(_: [*]const u8, _: usize, _: [*]const u8, _: usize, _: [*]const u8, _: usize, _: [*]const u8, _: usize) void {}
    pub fn move_keyed_child(_: [*]const u8, _: usize, _: [*]const u8, _: usize, _: [*]const u8, _: usize) void {}
    pub fn remove_keyed_child(_: [*]const u8, _: usize, _: [*]const u8, _: usize) void {}
    pub fn set_class_present_by_bind(_: [*]const u8, _: usize, _: [*]const u8, _: usize, _: u32) void {}
    pub fn set_text_by_bind_f32(_: [*]const u8, _: usize, _: f32) void {}
    pub fn server_fn_post(_: [*]const u8, _: usize, _: [*]const u8, _: usize) void {}
    pub fn query_ref(_: [*]const u8, _: usize) i32 {
        return 0;
    }
};

pub const set_text_by_bind = Bridge.set_text_by_bind;
pub const set_text_by_bind_i32 = Bridge.set_text_by_bind_i32;
pub const post_json_i32 = Bridge.post_json_i32;
pub const console_log_i32 = Bridge.console_log_i32;
pub const set_attr_by_bind = Bridge.set_attr_by_bind;
pub const set_class_by_bind = Bridge.set_class_by_bind;
pub const set_text_by_bind_str = Bridge.set_text_by_bind_str;
pub const set_value_by_bind = Bridge.set_value_by_bind;
pub const remove_by_bind = Bridge.remove_by_bind;
pub const create_keyed_child = Bridge.create_keyed_child;
pub const move_keyed_child = Bridge.move_keyed_child;
pub const remove_keyed_child = Bridge.remove_keyed_child;
pub const set_class_present_by_bind = Bridge.set_class_present_by_bind;
pub const set_text_by_bind_f32 = Bridge.set_text_by_bind_f32;
pub const server_fn_post = Bridge.server_fn_post;
pub const query_ref = Bridge.query_ref;
