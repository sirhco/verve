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
