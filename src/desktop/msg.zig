//! `objc_msgSend` plumbing for the macOS backend.
//!
//! Zig cannot safely invoke C variadic functions on every supported
//! architecture — notably arm64-darwin's `objc_msgSend` ABI requires
//! arguments to match the selector's actual signature, not a generic
//! variadic stub. The safe pattern is to take the address of the symbol
//! once and cast it to a concrete non-variadic function pointer per
//! call site.
//!
//! This module is only ever imported from `macos.zig`, which is itself
//! only referenced when `builtin.os.tag == .macos`. The `extern`
//! declarations therefore only resolve when linking against the
//! Objective-C runtime, which the generated desktop project does via
//! `linkSystemLibrary("objc")` and `linkFramework("Cocoa")`.
//!
//! ABI audit (2026-05, Zig 0.16, macOS 14+ arm64 + x86_64):
//! - We never use `objc_msgSend_stret`. That entry point is required
//!   when a selector returns a struct larger than two registers; the
//!   current backend only returns `id`, `void`, `bool`, `isize`, or
//!   `[*:0]const u8`, all of which fit standard registers.
//! - NSRect (4 doubles = 32 B HFA) is passed by value to
//!   `initWithContentRect:...:` and `initWithFrame:configuration:`.
//!   It rides in `v0-v3` on arm64 and the standard SSE classifier on
//!   x86_64. The Zig extern struct (`NSRect`/`NSPoint`/`NSSize`) is
//!   `extern struct { f64 ... }` which lowers to the same layout.
//! - Apple's BOOL is `_Bool` on 64-bit since macOS 10.10. Zig's `bool`
//!   under `callconv(.c)` matches; we never run on 32-bit darwin.
//! - `class_addMethod` takes `IMP = *const fn () callconv(.c) void`.
//!   We cast trampolines with concrete signatures via `@ptrCast`,
//!   which Zig permits between function-pointer types as long as the
//!   calling convention matches. The runtime dispatches using the
//!   type-encoding string we also pass, so the static type loss is
//!   harmless.

const std = @import("std");

pub const id = *opaque {};
pub const SEL = *opaque {};
pub const Class = *opaque {};
pub const Protocol = *opaque {};
pub const IMP = *const fn () callconv(.c) void;

pub extern "objc" fn sel_registerName(name: [*:0]const u8) SEL;
pub extern "objc" fn objc_getClass(name: [*:0]const u8) ?Class;
pub extern "objc" fn objc_lookUpClass(name: [*:0]const u8) ?Class;
pub extern "objc" fn objc_allocateClassPair(super: Class, name: [*:0]const u8, extra: usize) ?Class;
pub extern "objc" fn objc_registerClassPair(cls: Class) void;
pub extern "objc" fn class_addMethod(cls: Class, name: SEL, imp: IMP, types: [*:0]const u8) bool;
pub extern "objc" fn class_addProtocol(cls: Class, proto: Protocol) bool;
pub extern "objc" fn objc_getProtocol(name: [*:0]const u8) ?Protocol;

/// The actual symbol. Never called directly — we always cast its
/// address through `@ptrCast` to the exact non-variadic signature for
/// each selector. Zig refuses to expose a typed variadic prototype, so
/// the placeholder zero-arg form here is just a name to take the
/// address of.
pub extern "objc" fn objc_msgSend() callconv(.c) void;

/// Cast helper: returns a typed function pointer that wraps
/// `objc_msgSend` for a specific selector signature. The two implicit
/// arguments `(receiver: id, _cmd: SEL)` must be the first two members
/// of the function type.
pub fn cast(comptime Fn: type) Fn {
    return @ptrCast(&objc_msgSend);
}

pub fn sel(name: [*:0]const u8) SEL {
    return sel_registerName(name);
}

pub fn getClass(name: [*:0]const u8) Class {
    return objc_getClass(name) orelse @panic("objc class missing");
}

pub fn allocateClass(super: Class, name: [*:0]const u8) Class {
    return objc_allocateClassPair(super, name, 0) orelse @panic("objc_allocateClassPair failed");
}

pub fn registerClass(cls: Class) void {
    objc_registerClassPair(cls);
}

pub fn addMethod(cls: Class, name: SEL, imp: IMP, types: [*:0]const u8) void {
    if (!class_addMethod(cls, name, imp, types)) @panic("class_addMethod failed");
}

pub fn addProtocol(cls: Class, name: [*:0]const u8) void {
    const proto = objc_getProtocol(name) orelse return;
    _ = class_addProtocol(cls, proto);
}
