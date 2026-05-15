//! Externs supplied by the JS bridge (`src/bridge/verve.js`).
//! Strings are passed as (ptr, len) pairs since wasm32 lacks native strings.

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
