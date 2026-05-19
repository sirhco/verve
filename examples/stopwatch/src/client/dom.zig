//! Externs from the JS bridge.

pub extern "verve" fn set_text_by_bind(
    bind_ptr: [*]const u8,
    bind_len: usize,
    text_ptr: [*]const u8,
    text_len: usize,
) void;

pub extern "verve" fn console_log_i32(value: i32) void;
