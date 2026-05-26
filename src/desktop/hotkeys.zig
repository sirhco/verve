//! System-wide hotkey registration. Fires the callback even when
//! the app is blurred.
//!
//! Per-platform strategy:
//! - **macOS** — Carbon's `RegisterEventHotKey` +
//!   `InstallEventHandler` on the application event target.
//!   Carbon is deprecated but `RegisterEventHotKey` keeps shipping —
//!   it's the only public path for global hotkeys on macOS short
//!   of Accessibility API event taps. Needs `linkFramework("Carbon")`
//!   in the scaffold.
//! - **Windows** — stub. `RegisterHotKey` integration is a future
//!   bundle (needs WM_HOTKEY plumbing into the existing wndProc).
//! - **Linux** — stub. X11 `XGrabKey` / Wayland portal integration
//!   is a future bundle.

const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{
    Unsupported,
    Backend,
    OutOfMemory,
    AlreadyRegistered,
};

/// Modifier flags. OR them together for multi-modifier combos
/// (e.g. `.{ .cmd = true, .shift = true }`).
pub const Modifiers = packed struct {
    cmd: bool = false,
    ctrl: bool = false,
    option: bool = false,
    shift: bool = false,
    _pad: u4 = 0,
};

/// Fires when the registered combo is pressed. `id` is the same
/// id the caller passed to `register`, so a single callback can
/// dispatch multiple bindings.
pub const HotkeyHandler = *const fn (ctx: ?*anyopaque, id: u32) void;

pub const Manager = struct {
    impl: ?*MacosManager = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Manager) void {
        if (self.impl) |p| {
            p.deinit();
            self.allocator.destroy(p);
            self.impl = null;
        }
    }

    /// Register a global hotkey. `id` is opaque to the platform —
    /// pick a value that's unique per-binding within this Manager.
    /// `keycode` is a platform virtual key code (see references
    /// like macOS `HIToolbox/Events.h` `kVK_ANSI_*`).
    pub fn register(self: *Manager, id: u32, modifiers: Modifiers, keycode: u32) Error!void {
        const impl = self.impl orelse return error.Unsupported;
        return impl.register(id, modifiers, keycode);
    }

    /// Remove a previously-registered binding. No-op for unknown ids.
    pub fn unregister(self: *Manager, id: u32) void {
        if (self.impl) |p| p.unregister(id);
    }
};

pub fn init(
    allocator: std.mem.Allocator,
    cb: HotkeyHandler,
    ctx: ?*anyopaque,
) Error!Manager {
    if (builtin.os.tag != .macos) return error.Unsupported;
    const heap = allocator.create(MacosManager) catch return error.OutOfMemory;
    errdefer allocator.destroy(heap);
    heap.* = try MacosManager.start(allocator, cb, ctx);
    return .{ .impl = heap, .allocator = allocator };
}

// ---- macOS — Carbon RegisterEventHotKey ------------------------------------

const OSStatus = i32;
const EventHandlerRef = ?*anyopaque;
const EventTargetRef = ?*anyopaque;
const EventRef = ?*anyopaque;
const EventHotKeyRef = ?*anyopaque;

const EventTypeSpec = extern struct {
    eventClass: u32,
    eventKind: u32,
};

const EventHotKeyID = extern struct {
    signature: u32,
    id: u32,
};

// FourCharCode: 'htk1' = ('h' << 24) | ('t' << 16) | ('k' << 8) | '1'
const kEventClassKeyboard: u32 = 0x6B657962; // 'keyb'
const kEventHotKeyPressed: u32 = 5;
const kEventParamDirectObject: u32 = 0x2D2D2D2D; // '----'
const typeEventHotKeyID: u32 = 0x686B6964; // 'hkid'

// Carbon modifier mask bits (NSEventModifierFlags >> 16).
const cmdKey: u32 = 0x0100;
const shiftKey: u32 = 0x0200;
const optionKey: u32 = 0x0800;
const controlKey: u32 = 0x1000;

extern "Carbon" fn GetApplicationEventTarget() EventTargetRef;
extern "Carbon" fn InstallEventHandler(
    target: EventTargetRef,
    handler: *const fn (
        next: ?*anyopaque,
        event: EventRef,
        user: ?*anyopaque,
    ) callconv(.c) OSStatus,
    num_types: u32,
    types: [*]const EventTypeSpec,
    user: ?*anyopaque,
    out_ref: ?*EventHandlerRef,
) OSStatus;
extern "Carbon" fn RemoveEventHandler(ref: EventHandlerRef) OSStatus;
extern "Carbon" fn RegisterEventHotKey(
    keycode: u32,
    modifiers: u32,
    id: EventHotKeyID,
    target: EventTargetRef,
    options: u32,
    out_ref: *EventHotKeyRef,
) OSStatus;
extern "Carbon" fn UnregisterEventHotKey(ref: EventHotKeyRef) OSStatus;
extern "Carbon" fn GetEventParameter(
    event: EventRef,
    name: u32,
    desired_type: u32,
    actual_type: ?*u32,
    buffer_size: u32,
    actual_size: ?*u32,
    out_data: ?*anyopaque,
) OSStatus;

const Binding = struct {
    id: u32,
    ref: EventHotKeyRef,
};

const MacosManager = struct {
    allocator: std.mem.Allocator,
    cb: HotkeyHandler,
    cb_ctx: ?*anyopaque,
    handler_ref: EventHandlerRef = null,
    bindings: std.ArrayList(Binding) = .empty,

    fn start(
        allocator: std.mem.Allocator,
        cb: HotkeyHandler,
        ctx: ?*anyopaque,
    ) Error!MacosManager {
        if (builtin.os.tag != .macos) return error.Unsupported;
        var self: MacosManager = .{
            .allocator = allocator,
            .cb = cb,
            .cb_ctx = ctx,
        };

        const target = GetApplicationEventTarget() orelse return error.Backend;
        const types = [_]EventTypeSpec{.{
            .eventClass = kEventClassKeyboard,
            .eventKind = kEventHotKeyPressed,
        }};
        // Singleton — the handler trampoline routes to whichever
        // MacosManager pointer was last installed. Multi-manager
        // apps would need the user_data to point at a registry.
        var ref: EventHandlerRef = null;
        const status = InstallEventHandler(
            target,
            hotkeyTrampoline,
            1,
            &types,
            null, // user data unused — we route via g_singleton.
            &ref,
        );
        if (status != 0) return error.Backend;
        self.handler_ref = ref;
        g_singleton = &self;
        return self;
    }

    fn register(self: *MacosManager, id: u32, modifiers: Modifiers, keycode: u32) Error!void {
        // Reject duplicate ids — multiple bindings with the same id
        // make the callback ambiguous.
        for (self.bindings.items) |b| if (b.id == id) return error.AlreadyRegistered;

        var mask: u32 = 0;
        if (modifiers.cmd) mask |= cmdKey;
        if (modifiers.ctrl) mask |= controlKey;
        if (modifiers.option) mask |= optionKey;
        if (modifiers.shift) mask |= shiftKey;

        const hk_id = EventHotKeyID{
            .signature = 0x76657276, // 'verv'
            .id = id,
        };
        var hk_ref: EventHotKeyRef = null;
        const target = GetApplicationEventTarget();
        const status = RegisterEventHotKey(keycode, mask, hk_id, target, 0, &hk_ref);
        if (status != 0) return error.Backend;
        self.bindings.append(self.allocator, .{ .id = id, .ref = hk_ref }) catch {
            _ = UnregisterEventHotKey(hk_ref);
            return error.OutOfMemory;
        };
    }

    fn unregister(self: *MacosManager, id: u32) void {
        var i: usize = 0;
        while (i < self.bindings.items.len) : (i += 1) {
            if (self.bindings.items[i].id == id) {
                _ = UnregisterEventHotKey(self.bindings.items[i].ref);
                _ = self.bindings.orderedRemove(i);
                return;
            }
        }
    }

    pub fn deinit(self: *MacosManager) void {
        for (self.bindings.items) |b| {
            _ = UnregisterEventHotKey(b.ref);
        }
        self.bindings.deinit(self.allocator);
        if (self.handler_ref) |r| {
            _ = RemoveEventHandler(r);
            self.handler_ref = null;
        }
        if (g_singleton == self) g_singleton = null;
    }
};

var g_singleton: ?*MacosManager = null;

fn hotkeyTrampoline(
    _: ?*anyopaque,
    event: EventRef,
    _: ?*anyopaque,
) callconv(.c) OSStatus {
    const mgr = g_singleton orelse return 0;
    var hk_id: EventHotKeyID = .{ .signature = 0, .id = 0 };
    _ = GetEventParameter(
        event,
        kEventParamDirectObject,
        typeEventHotKeyID,
        null,
        @sizeOf(EventHotKeyID),
        null,
        @ptrCast(&hk_id),
    );
    mgr.cb(mgr.cb_ctx, hk_id.id);
    return 0;
}

const testing = std.testing;

test "Modifiers fits in a byte" {
    try testing.expectEqual(@as(usize, 1), @sizeOf(Modifiers));
}

test "Hotkeys Error set stable" {
    const e: Error = error.Unsupported;
    try testing.expect(e == error.Unsupported);
    try testing.expect(@as(Error, error.AlreadyRegistered) == error.AlreadyRegistered);
}
