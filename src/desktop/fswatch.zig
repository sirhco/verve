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
//!   per coalescing latency (default 1s here). Callback fires on
//!   the main thread. Needs no extra framework link beyond
//!   CoreServices (pulled in by Cocoa).
//! - **Windows** — `ReadDirectoryChangesW` against the watched
//!   directory with `FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED`,
//!   pumped by a dedicated worker thread that blocks on
//!   `GetOverlappedResult`. v1 fires the callback **from the
//!   worker thread**, not the UI thread — apps that need main-
//!   thread delivery should marshal across themselves
//!   (PostMessage to the window or a thread-safe queue drained
//!   from the UI loop). Cancellation via `CancelIoEx` from
//!   `deinit`.
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
    macos_impl: ?*MacosWatcher = null,
    windows_impl: ?*WindowsWatcher = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Watcher) void {
        if (self.macos_impl) |p| {
            p.deinit();
            self.allocator.destroy(p);
            self.macos_impl = null;
        }
        if (self.windows_impl) |p| {
            p.deinit();
            self.allocator.destroy(p);
            self.windows_impl = null;
        }
    }
};

pub fn init(
    allocator: std.mem.Allocator,
    path: []const u8,
    cb: ChangeHandler,
    ctx: ?*anyopaque,
) Error!Watcher {
    switch (builtin.os.tag) {
        .macos => {
            const heap = allocator.create(MacosWatcher) catch return error.OutOfMemory;
            errdefer allocator.destroy(heap);
            heap.* = try MacosWatcher.start(allocator, path, cb, ctx);
            return .{ .macos_impl = heap, .allocator = allocator };
        },
        .windows => {
            const heap = allocator.create(WindowsWatcher) catch return error.OutOfMemory;
            errdefer allocator.destroy(heap);
            try WindowsWatcher.start(heap, allocator, path, cb, ctx);
            return .{ .windows_impl = heap, .allocator = allocator };
        },
        else => return error.Unsupported,
    }
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

// ---- Windows — ReadDirectoryChangesW ---------------------------------------

const HANDLE = ?*opaque {};
const BOOL = c_int;
const DWORD = u32;
const LPVOID = ?*anyopaque;

// OVERLAPPED layout matches Win32. Only `hEvent` is set here; the
// kernel populates Internal / InternalHigh / Offset on completion.
const OVERLAPPED = extern struct {
    Internal: usize = 0,
    InternalHigh: usize = 0,
    Offset: u32 = 0,
    OffsetHigh: u32 = 0,
    hEvent: HANDLE = null,
};

const FILE_NOTIFY_INFORMATION_HEADER = extern struct {
    NextEntryOffset: u32,
    Action: u32,
    FileNameLength: u32, // bytes (UTF-16), not chars
    // Followed by `FileName: [FileNameLength/2]u16` — variable-length.
};

const GENERIC_READ: u32 = 0x80000000;
const FILE_SHARE_READ: u32 = 0x00000001;
const FILE_SHARE_WRITE: u32 = 0x00000002;
const FILE_SHARE_DELETE: u32 = 0x00000004;
const OPEN_EXISTING: u32 = 3;
const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x02000000;
const FILE_FLAG_OVERLAPPED: u32 = 0x40000000;
const FILE_LIST_DIRECTORY: u32 = 0x0001;
const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(@as(usize, std.math.maxInt(usize)));

const FILE_NOTIFY_CHANGE_FILE_NAME: u32 = 0x001;
const FILE_NOTIFY_CHANGE_DIR_NAME: u32 = 0x002;
const FILE_NOTIFY_CHANGE_ATTRIBUTES: u32 = 0x004;
const FILE_NOTIFY_CHANGE_SIZE: u32 = 0x008;
const FILE_NOTIFY_CHANGE_LAST_WRITE: u32 = 0x010;
const FILE_NOTIFY_CHANGE_CREATION: u32 = 0x040;
const NOTIFY_FILTER_ALL: u32 = FILE_NOTIFY_CHANGE_FILE_NAME |
    FILE_NOTIFY_CHANGE_DIR_NAME |
    FILE_NOTIFY_CHANGE_ATTRIBUTES |
    FILE_NOTIFY_CHANGE_SIZE |
    FILE_NOTIFY_CHANGE_LAST_WRITE |
    FILE_NOTIFY_CHANGE_CREATION;

extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: u32,
    dwShareMode: u32,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: u32,
    dwFlagsAndAttributes: u32,
    hTemplateFile: HANDLE,
) callconv(.winapi) HANDLE;
extern "kernel32" fn CreateEventW(
    lpEventAttributes: ?*anyopaque,
    bManualReset: BOOL,
    bInitialState: BOOL,
    lpName: ?[*:0]const u16,
) callconv(.winapi) HANDLE;
extern "kernel32" fn ReadDirectoryChangesW(
    hDirectory: HANDLE,
    lpBuffer: LPVOID,
    nBufferLength: DWORD,
    bWatchSubtree: BOOL,
    dwNotifyFilter: DWORD,
    lpBytesReturned: ?*DWORD,
    lpOverlapped: *OVERLAPPED,
    lpCompletionRoutine: ?*anyopaque,
) callconv(.winapi) BOOL;
extern "kernel32" fn GetOverlappedResult(
    hFile: HANDLE,
    lpOverlapped: *OVERLAPPED,
    lpNumberOfBytesTransferred: *DWORD,
    bWait: BOOL,
) callconv(.winapi) BOOL;
extern "kernel32" fn CancelIoEx(hFile: HANDLE, lpOverlapped: ?*OVERLAPPED) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;

const WindowsWatcher = struct {
    // 16 KiB buffer; FILE_NOTIFY_INFORMATION entries average ~30-100
    // bytes so this carries ~150-500 events per ReadDirectoryChangesW
    // call. Larger reduces the chance of ERROR_NOTIFY_ENUM_DIR (buffer
    // overflowed, kernel collapsed events) on bursty FS activity.
    const BUFFER_BYTES: usize = 16 * 1024;

    allocator: std.mem.Allocator,
    cb: ChangeHandler,
    cb_ctx: ?*anyopaque,
    dir_handle: HANDLE = null,
    event_handle: HANDLE = null,
    thread: ?std.Thread = null,
    stop_flag: std.atomic.Value(bool) = .init(false),
    watch_root: []u8 = &.{},
    buffer: []u8 = &.{},

    fn start(
        self: *WindowsWatcher,
        allocator: std.mem.Allocator,
        path: []const u8,
        cb: ChangeHandler,
        ctx: ?*anyopaque,
    ) Error!void {
        if (builtin.os.tag != .windows) return error.Unsupported;
        self.* = .{
            .allocator = allocator,
            .cb = cb,
            .cb_ctx = ctx,
        };

        // Persist the watch root so the worker can prepend it to the
        // relative paths Windows reports back.
        self.watch_root = allocator.dupe(u8, path) catch return error.OutOfMemory;
        errdefer allocator.free(self.watch_root);

        self.buffer = allocator.alignedAlloc(u8, .of(u32), BUFFER_BYTES) catch return error.OutOfMemory;
        errdefer allocator.free(self.buffer);

        const path_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, path) catch return error.OutOfMemory;
        defer allocator.free(path_w);

        const dir = CreateFileW(
            path_w.ptr,
            FILE_LIST_DIRECTORY | GENERIC_READ,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            null,
            OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED,
            null,
        );
        if (dir == null or dir == INVALID_HANDLE_VALUE) return error.Backend;
        errdefer _ = CloseHandle(dir);
        self.dir_handle = dir;

        // Manual-reset event so the worker sees a single notification
        // per ReadDirectoryChangesW completion and resets it itself.
        const ev = CreateEventW(null, 1, 0, null);
        if (ev == null) return error.Backend;
        errdefer _ = CloseHandle(ev);
        self.event_handle = ev;

        self.thread = std.Thread.spawn(.{}, workerThreadEntry, .{self}) catch return error.Backend;
    }

    fn deinit(self: *WindowsWatcher) void {
        if (builtin.os.tag != .windows) return;
        self.stop_flag.store(true, .release);
        // Cancel the pending overlapped IO so GetOverlappedResult
        // returns and the worker checks stop_flag.
        if (self.dir_handle) |h| _ = CancelIoEx(h, null);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        if (self.event_handle) |h| _ = CloseHandle(h);
        if (self.dir_handle) |h| _ = CloseHandle(h);
        if (self.buffer.len > 0) self.allocator.free(self.buffer);
        if (self.watch_root.len > 0) self.allocator.free(self.watch_root);
    }

    fn workerThreadEntry(self: *WindowsWatcher) void {
        // Pre-allocate per-event UTF-8 scratch outside the loop. Capped
        // at MAX_PATH * 4 (worst-case UTF-16 → UTF-8 expansion).
        var path_scratch: [4096]u8 = undefined;

        while (!self.stop_flag.load(.acquire)) {
            var ovl: OVERLAPPED = .{ .hEvent = self.event_handle };
            var bytes_returned: DWORD = 0;
            const ok = ReadDirectoryChangesW(
                self.dir_handle,
                self.buffer.ptr,
                @intCast(self.buffer.len),
                1, // recursive
                NOTIFY_FILTER_ALL,
                &bytes_returned,
                &ovl,
                null,
            );
            if (ok == 0) return;

            // Block until the OVERLAPPED completes. CancelIoEx from
            // deinit unblocks this with ERROR_OPERATION_ABORTED.
            var transferred: DWORD = 0;
            const wait_ok = GetOverlappedResult(self.dir_handle, &ovl, &transferred, 1);
            if (wait_ok == 0 or self.stop_flag.load(.acquire)) return;
            if (transferred == 0) {
                // Buffer overflowed — kernel dropped events. Re-issue
                // the read and continue; callers tolerate coarseness.
                continue;
            }

            self.dispatchBatch(self.buffer[0..transferred], &path_scratch);
        }
    }

    fn dispatchBatch(self: *WindowsWatcher, buf: []const u8, scratch: *[4096]u8) void {
        var offset: usize = 0;
        while (offset < buf.len) {
            if (offset + @sizeOf(FILE_NOTIFY_INFORMATION_HEADER) > buf.len) return;
            const hdr_ptr: *const FILE_NOTIFY_INFORMATION_HEADER = @ptrCast(@alignCast(&buf[offset]));
            const name_bytes = hdr_ptr.FileNameLength;
            const name_start = offset + @sizeOf(FILE_NOTIFY_INFORMATION_HEADER);
            if (name_start + name_bytes > buf.len) return;

            const wname_ptr: [*]const u16 = @ptrCast(@alignCast(&buf[name_start]));
            const wname_len: usize = name_bytes / 2;
            const wname = wname_ptr[0..wname_len];

            // Compose `<watch_root>\<reported_name>` directly into the
            // scratch buffer. Skip the call if it would overflow —
            // callers don't expect a truncated path.
            const sep = "\\";
            const max_utf8 = wname.len * 3;
            const needed = self.watch_root.len + sep.len + max_utf8;
            if (needed <= scratch.len) {
                @memcpy(scratch[0..self.watch_root.len], self.watch_root);
                @memcpy(scratch[self.watch_root.len..][0..sep.len], sep);
                const written = std.unicode.utf16LeToUtf8(scratch[self.watch_root.len + sep.len ..], wname) catch 0;
                if (written > 0) {
                    const total = self.watch_root.len + sep.len + written;
                    self.cb(self.cb_ctx, scratch[0..total]);
                }
            }

            if (hdr_ptr.NextEntryOffset == 0) return;
            offset += hdr_ptr.NextEntryOffset;
        }
    }
};

const testing = std.testing;

test "Watcher Error set is stable" {
    const e: Error = error.Unsupported;
    try testing.expect(e == error.Unsupported);
    try testing.expect(@as(Error, error.Backend) == error.Backend);
    try testing.expect(@as(Error, error.OutOfMemory) == error.OutOfMemory);
}
