//! Filesystem change watcher.
//!
//! `Watcher.init(allocator, path, callback, ctx)` watches `path`
//! recursively. The callback fires with one entry per changed file,
//! coalesced within the platform's natural batching window.
//!
//! Per-platform strategy:
//! - **macOS** — FSEvents. `FSEventStreamCreate` with a callback,
//!   `FSEventStreamScheduleWithRunLoop` on the main run loop,
//!   `FSEventStreamStart`. Batches changes into a single callback
//!   per coalescing latency (default 1s here). Needs no extra
//!   framework link beyond CoreServices (pulled in by Cocoa).
//! - **Windows** — stub. `ReadDirectoryChangesW` integration is a
//!   future bundle (needs IOCP / overlapped IO threading).
//! - **Linux** — stub. inotify integration is a future bundle
//!   (needs GIOChannel watch wiring into the GTK main loop).

const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{
    Unsupported,
    Backend,
    OutOfMemory,
};

/// Fires when one or more files under the watched path changes.
/// `path` is a UTF-8 absolute filesystem path. The slice is owned
/// by the callback's caller (the watcher) and must not be retained
/// past the callback — copy if you need to outlive it.
pub const ChangeHandler = *const fn (ctx: ?*anyopaque, path: []const u8) void;

pub const Watcher = struct {
    impl: ?*MacosWatcher = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Watcher) void {
        if (self.impl) |p| {
            p.deinit();
            self.allocator.destroy(p);
            self.impl = null;
        }
    }
};

pub fn init(
    allocator: std.mem.Allocator,
    path: []const u8,
    cb: ChangeHandler,
    ctx: ?*anyopaque,
) Error!Watcher {
    if (builtin.os.tag != .macos) {
        // Win + Linux impls are future bundles
        // (ReadDirectoryChangesW / inotify).
        return error.Unsupported;
    }
    const heap = allocator.create(MacosWatcher) catch return error.OutOfMemory;
    errdefer allocator.destroy(heap);
    heap.* = try MacosWatcher.start(allocator, path, cb, ctx);
    return .{ .impl = heap, .allocator = allocator };
}

// ---- macOS — FSEvents ------------------------------------------------------

const CFArrayRef = *anyopaque;
const CFRunLoopRef = *anyopaque;
const CFStringRef = *anyopaque;
const FSEventStreamRef = *anyopaque;
const CFAllocatorRef = ?*anyopaque;

const kCFRunLoopDefaultMode_name = "kCFRunLoopDefaultMode";
const kCFStringEncodingUTF8: u32 = 0x08000100;

const kFSEventStreamCreateFlagNone: u32 = 0;
const kFSEventStreamCreateFlagFileEvents: u32 = 0x10;
const kFSEventStreamEventIdSinceNow: u64 = 0xFFFFFFFFFFFFFFFF;

extern "CoreFoundation" fn CFRunLoopGetMain() CFRunLoopRef;
extern "CoreFoundation" fn CFStringCreateWithCString(
    allocator: CFAllocatorRef,
    cstr: [*:0]const u8,
    encoding: u32,
) ?CFStringRef;
extern "CoreFoundation" fn CFArrayCreate(
    allocator: CFAllocatorRef,
    values: [*]const ?*const anyopaque,
    count: isize,
    callbacks: ?*const anyopaque,
) ?CFArrayRef;
extern "CoreFoundation" fn CFRelease(cf: *anyopaque) void;

const FSEventStreamContext = extern struct {
    version: isize = 0,
    info: ?*anyopaque,
    retain: ?*const anyopaque = null,
    release: ?*const anyopaque = null,
    copyDescription: ?*const anyopaque = null,
};

const FSEventStreamCallback = *const fn (
    stream: FSEventStreamRef,
    info: ?*anyopaque,
    num_events: usize,
    event_paths: [*]const [*:0]const u8,
    event_flags: [*]const u32,
    event_ids: [*]const u64,
) callconv(.c) void;

extern "CoreServices" fn FSEventStreamCreate(
    allocator: CFAllocatorRef,
    callback: FSEventStreamCallback,
    ctx: *const FSEventStreamContext,
    paths_to_watch: CFArrayRef,
    since_when: u64,
    latency: f64,
    flags: u32,
) ?FSEventStreamRef;
extern "CoreServices" fn FSEventStreamScheduleWithRunLoop(
    stream: FSEventStreamRef,
    run_loop: CFRunLoopRef,
    run_loop_mode: CFStringRef,
) void;
extern "CoreServices" fn FSEventStreamStart(stream: FSEventStreamRef) bool;
extern "CoreServices" fn FSEventStreamStop(stream: FSEventStreamRef) void;
extern "CoreServices" fn FSEventStreamInvalidate(stream: FSEventStreamRef) void;
extern "CoreServices" fn FSEventStreamRelease(stream: FSEventStreamRef) void;

const MacosWatcher = struct {
    stream: ?FSEventStreamRef = null,
    cb: ChangeHandler,
    cb_ctx: ?*anyopaque,

    fn start(
        _: std.mem.Allocator,
        path: []const u8,
        cb: ChangeHandler,
        ctx: ?*anyopaque,
    ) Error!MacosWatcher {
        if (builtin.os.tag != .macos) return error.Unsupported;
        var self: MacosWatcher = .{ .cb = cb, .cb_ctx = ctx };

        // FSEvents wants a NUL-terminated path inside a CFString
        // inside a CFArray. Stack-allocate the NUL-terminated copy.
        if (path.len >= 1024) return error.Backend;
        var path_buf: [1024]u8 = undefined;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;

        const cf_path = CFStringCreateWithCString(null, @ptrCast(&path_buf), kCFStringEncodingUTF8) orelse return error.Backend;
        defer CFRelease(cf_path);
        const paths_arr_storage = [_]?*const anyopaque{cf_path};
        const cf_array = CFArrayCreate(null, &paths_arr_storage, 1, null) orelse return error.Backend;
        defer CFRelease(cf_array);

        // `info` carries our MacosWatcher* across the C trampoline.
        // We capture-by-address; the heap-allocated wrapper outlives
        // this call by the `Watcher.init` contract.
        var stream_ctx: FSEventStreamContext = .{ .info = @ptrCast(&self) };
        const stream = FSEventStreamCreate(
            null,
            fsEventTrampoline,
            &stream_ctx,
            cf_array,
            kFSEventStreamEventIdSinceNow,
            1.0, // 1-second coalescing latency.
            kFSEventStreamCreateFlagFileEvents,
        ) orelse return error.Backend;

        const main_loop = CFRunLoopGetMain();
        const default_mode_str = CFStringCreateWithCString(null, kCFRunLoopDefaultMode_name, kCFStringEncodingUTF8) orelse {
            FSEventStreamRelease(stream);
            return error.Backend;
        };
        defer CFRelease(default_mode_str);
        FSEventStreamScheduleWithRunLoop(stream, main_loop, default_mode_str);

        if (!FSEventStreamStart(stream)) {
            FSEventStreamInvalidate(stream);
            FSEventStreamRelease(stream);
            return error.Backend;
        }

        self.stream = stream;
        return self;
    }

    pub fn deinit(self: *MacosWatcher) void {
        if (self.stream) |s| {
            FSEventStreamStop(s);
            FSEventStreamInvalidate(s);
            FSEventStreamRelease(s);
            self.stream = null;
        }
    }
};

fn fsEventTrampoline(
    _: FSEventStreamRef,
    info: ?*anyopaque,
    num_events: usize,
    event_paths: [*]const [*:0]const u8,
    _: [*]const u32,
    _: [*]const u64,
) callconv(.c) void {
    const self_ptr: *MacosWatcher = @ptrCast(@alignCast(info orelse return));
    var i: usize = 0;
    while (i < num_events) : (i += 1) {
        const cstr = event_paths[i];
        const slice = std.mem.span(cstr);
        self_ptr.cb(self_ptr.cb_ctx, slice);
    }
}

const testing = std.testing;

test "Watcher Error set is stable" {
    const e: Error = error.Unsupported;
    try testing.expect(e == error.Unsupported);
    try testing.expect(@as(Error, error.Backend) == error.Backend);
    try testing.expect(@as(Error, error.OutOfMemory) == error.OutOfMemory);
}
