//! Cross-platform tray / status-bar icon with click handlers + submenus.
//!
//! Public surface: create an icon, set tooltip, attach a menu (with
//! optional submenus), register a click + menu-item handler. The menu
//! is a flat-or-nested slice of `TrayMenuItem`; the backend deep-copies
//! it so the caller's slice can die immediately after `init` / `setMenu`.
//!
//! Per-platform strategy:
//!
//! - **macOS** — `NSStatusItem` + `NSMenu`. Menu items target a
//!   process-wide `VerveTrayTarget` NSObject (one class registered
//!   lazily via `objc_allocateClassPair`) that reads each item's
//!   `[NSMenuItem tag]` and dispatches to the singleton tray's
//!   `on_menu_item`. Cocoa attaches the menu via `setMenu:` and shows
//!   it on any click of the status item; the `on_click` callback only
//!   fires when no menu is attached.
//! - **Windows** — `Shell_NotifyIconW` with `uCallbackMessage =
//!   WM_VERVE_TRAY` (= `WM_USER + 100`). The window's `wndProc`
//!   forwards `WM_VERVE_TRAY` here, where `lParam` carries the mouse
//!   event ID — left click fires `on_click` (or shows the menu if
//!   none); right click / WM_CONTEXTMENU always shows the menu via
//!   `TrackPopupMenu`. Menu IDs occupy the `0xC000` block so they
//!   don't collide with the default `0x8000` File/Edit IDs.
//! Linux notes: libayatana-appindicator3 is loaded at runtime via
//! `dlopen("libayatana-appindicator3.so.1")` so scaffolds on distros
//! that don't ship it still build; `Tray.init` returns
//! `error.Unsupported` when the library isn't present at runtime.
//!
//! - **Linux** — `app_indicator_set_menu` with a GtkMenu built from
//!   the items. Each leaf item gets a `g_signal_connect("activate")`
//!   to a trampoline that reads the per-item `ItemBox { tray, id }`
//!   from `user_data` and dispatches to `on_menu_item`. AppIndicator
//!   doesn't expose icon-click signals — `on_click` is a no-op on
//!   Linux when a menu is set (which it usually is, since AppIndicator
//!   wants one).
//!
//! The impl struct is heap-allocated by `init` so callbacks fired
//! later (after `init` returns by value) still see a stable address.
//!
//! Single-tray-per-process is a hard v1 assumption — `g_macos_tray` /
//! `g_windows_tray` are unguarded singletons set on the most-recent
//! `init`. Multi-tray would need per-target ivars / a registry keyed on
//! something more specific than the HWND, deferred until a use case
//! shows up.
//!
//! Notifications are a separate concern — see `notifications.zig`.

const std = @import("std");
const builtin = @import("builtin");
const window_mod = @import("window.zig");

pub const Error = error{
    Unsupported,
    OutOfMemory,
    Backend,
};

/// One row in a tray menu. `label = null` is a separator. Non-empty
/// `children` turns the row into a submenu parent (its own `id` is
/// ignored on every platform since clicking the row only expands).
pub const TrayMenuItem = struct {
    label: ?[]const u8 = null,
    /// Surfaces in `on_menu_item(ctx, id)`. Caller-defined; the only
    /// reserved value is `0` for separators. Cap is `0x0FFF` (Windows
    /// uses the high bits for ID range gating).
    id: u32 = 0,
    enabled: bool = true,
    children: []const TrayMenuItem = &.{},
};

pub const TrayClickHandler = *const fn (ctx: ?*anyopaque) void;
pub const TrayMenuItemHandler = *const fn (ctx: ?*anyopaque, id: u32) void;

pub const TrayOptions = struct {
    /// Tooltip shown on hover. Empty string disables the tooltip.
    tooltip: []const u8 = "",
    /// Status-bar label. macOS renders this text next to the icon
    /// in the menubar; Win + Linux ignore it (Win shows the tooltip,
    /// Linux uses the indicator's `id` / theme icon name).
    label: []const u8 = "Verve",
    /// Path to a platform-appropriate icon file. `null` = stock
    /// per-platform default (NSStatusItem's label-only button on
    /// macOS, `IDI_APPLICATION` on Windows, the
    /// `application-x-executable` theme icon on Linux). Format per
    /// platform:
    /// - macOS: anything `NSImage` reads (PNG, JPEG, ICNS, TIFF, …).
    ///   Use a template (black/transparent) PNG for menu-bar tinting.
    /// - Windows: an `.ico` file. Other formats won't load.
    /// - Linux: an absolute path to a PNG (Ayatana accepts), OR a
    ///   theme icon name (e.g. "applications-system") — both go
    ///   straight through `app_indicator_set_icon_full`.
    icon_path: ?[]const u8 = null,
    /// macOS-only: name of an SF Symbol (e.g. "bolt.fill",
    /// "circle.dashed", "doc.text") rendered as the status-bar
    /// icon. macOS 11+ via `+[NSImage
    /// imageWithSystemSymbolName:accessibilityDescription:]`. Useful
    /// for "demo / dev tools" trays that don't want to ship a binary
    /// asset. Ignored on Windows + Linux (those use the bytes-based
    /// formats via `icon_path`). `icon_path` takes precedence when
    /// both are set.
    icon_symbol: ?[]const u8 = null,
    /// Optional menu. Empty slice means no menu attached — `on_click`
    /// then becomes the only interaction surface (and Linux loses any
    /// way to interact since AppIndicator has no click signal).
    menu: []const TrayMenuItem = &.{},
    on_click: ?TrayClickHandler = null,
    on_click_ctx: ?*anyopaque = null,
    on_menu_item: ?TrayMenuItemHandler = null,
    on_menu_item_ctx: ?*anyopaque = null,
};

pub const Tray = struct {
    impl: switch (builtin.os.tag) {
        .macos => *MacosTray,
        .windows => *WindowsTray,
        .linux => *LinuxTray,
        else => @compileError("verve.desktop.tray: unsupported OS"),
    },
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Tray) void {
        self.impl.deinit();
        self.allocator.destroy(self.impl);
    }

    pub fn setTooltip(self: *Tray, tooltip: []const u8) void {
        self.impl.setTooltip(tooltip);
    }

    /// Swap the tray icon to one loaded from `path`. See `icon_path`
    /// on `TrayOptions` for the per-platform format expectations.
    /// Returns `error.Backend` when the OS rejects the file (missing,
    /// wrong format, no menu-bar context, …).
    pub fn setIcon(self: *Tray, path: []const u8) Error!void {
        try self.impl.setIcon(path);
    }

    /// Replace the attached menu. Pass an empty slice to detach. Deep-
    /// copies the items so the caller's slice can die immediately.
    pub fn setMenu(self: *Tray, items: []const TrayMenuItem) Error!void {
        try self.impl.setMenu(items);
    }

    pub fn setClickHandler(self: *Tray, cb: ?TrayClickHandler, ctx: ?*anyopaque) void {
        self.impl.on_click = cb;
        self.impl.on_click_ctx = ctx;
    }

    pub fn setMenuItemHandler(self: *Tray, cb: ?TrayMenuItemHandler, ctx: ?*anyopaque) void {
        self.impl.on_menu_item = cb;
        self.impl.on_menu_item_ctx = ctx;
    }
};

pub fn init(
    allocator: std.mem.Allocator,
    window: *window_mod.Window,
    opts: TrayOptions,
) Error!Tray {
    switch (builtin.os.tag) {
        .macos => {
            const heap = allocator.create(MacosTray) catch return error.OutOfMemory;
            errdefer allocator.destroy(heap);
            heap.* = try MacosTray.bareInit(allocator, window, opts);
            errdefer heap.deinit();
            // Singleton wires here so callbacks read from the heap
            // address, not the about-to-be-copied stack-return.
            g_macos_tray = heap;
            if (opts.icon_path) |p| try heap.setIcon(p) else if (opts.icon_symbol) |s| try heap.setIconSymbol(s);
            if (opts.menu.len > 0) {
                try heap.setMenu(opts.menu);
            } else if (opts.on_click != null) {
                heap.wireButtonClick();
            }
            return .{ .impl = heap, .allocator = allocator };
        },
        .windows => {
            const heap = allocator.create(WindowsTray) catch return error.OutOfMemory;
            errdefer allocator.destroy(heap);
            heap.* = try WindowsTray.bareInit(allocator, window, opts);
            errdefer heap.deinit();
            g_windows_tray = heap;
            installWindowsDispatchHooks();
            if (opts.icon_path) |p| try heap.setIcon(p);
            if (opts.menu.len > 0) try heap.setMenu(opts.menu);
            return .{ .impl = heap, .allocator = allocator };
        },
        .linux => {
            const heap = allocator.create(LinuxTray) catch return error.OutOfMemory;
            errdefer allocator.destroy(heap);
            heap.* = try LinuxTray.bareInit(allocator, window, opts);
            errdefer heap.deinit();
            if (opts.icon_path) |p| try heap.setIcon(p);
            try heap.setMenu(opts.menu);
            return .{ .impl = heap, .allocator = allocator };
        },
        else => return error.Unsupported,
    }
}

// ---- Shared helpers ---------------------------------------------------------

/// Recursively dupe a menu spec onto `allocator`. Frees previously
/// duped storage on partial failure via `freeMenu`.
fn deepCopyMenu(allocator: std.mem.Allocator, items: []const TrayMenuItem) Error![]TrayMenuItem {
    var out = allocator.alloc(TrayMenuItem, items.len) catch return error.OutOfMemory;
    var i: usize = 0;
    errdefer {
        freeMenu(allocator, out[0..i]);
        allocator.free(out);
    }
    while (i < items.len) : (i += 1) {
        const src = items[i];
        const label_copy: ?[]const u8 = if (src.label) |l|
            (allocator.dupe(u8, l) catch return error.OutOfMemory)
        else
            null;
        const children_copy: []const TrayMenuItem = if (src.children.len > 0)
            try deepCopyMenu(allocator, src.children)
        else
            &.{};
        out[i] = .{
            .label = label_copy,
            .id = src.id,
            .enabled = src.enabled,
            .children = children_copy,
        };
    }
    return out;
}

fn freeMenu(allocator: std.mem.Allocator, items: []const TrayMenuItem) void {
    for (items) |it| {
        if (it.label) |l| allocator.free(l);
        if (it.children.len > 0) freeMenu(allocator, it.children);
    }
    if (items.len > 0) allocator.free(items);
}

// ---- macOS — NSStatusItem + NSMenu -----------------------------------------

const MacosTray = struct {
    status_item: ?*anyopaque = null,
    menu_obj: ?*anyopaque = null,
    allocator: std.mem.Allocator = undefined,
    items_storage: []const TrayMenuItem = &.{},
    on_click: ?TrayClickHandler = null,
    on_click_ctx: ?*anyopaque = null,
    on_menu_item: ?TrayMenuItemHandler = null,
    on_menu_item_ctx: ?*anyopaque = null,

    const m = if (builtin.os.tag == .macos) @import("msg.zig") else struct {};
    const id = ?*anyopaque;
    const SEL = ?*anyopaque;

    /// Create the NSStatusItem + button title/tooltip. Menu / handlers
    /// stay un-wired — the wrapper `init` does that after heap-pinning
    /// the impl so callbacks see a stable address.
    fn bareInit(allocator: std.mem.Allocator, _: *window_mod.Window, opts: TrayOptions) Error!MacosTray {
        if (builtin.os.tag != .macos) return error.Unsupported;

        const NSStatusBar = m.getClass("NSStatusBar");
        const systemStatusBar = m.cast(*const fn (id, SEL) callconv(.c) id);
        const bar = systemStatusBar(@as(id, @ptrCast(NSStatusBar)), m.sel("systemStatusBar"));

        // NSVariableStatusItemLength = -1.0 (CGFloat).
        const variable_length: f64 = -1.0;
        const statusItemWithLength = m.cast(*const fn (id, SEL, f64) callconv(.c) id);
        const item = statusItemWithLength(bar, m.sel("statusItemWithLength:"), variable_length);
        if (@intFromPtr(item) == 0) return error.Backend;

        // Retain so the bar holds a strong ref past this stack frame.
        const retain = m.cast(*const fn (id, SEL) callconv(.c) id);
        _ = retain(item, m.sel("retain"));

        const button_sel = m.cast(*const fn (id, SEL) callconv(.c) id);
        const button = button_sel(item, m.sel("button"));
        if (@intFromPtr(button) != 0 and opts.label.len > 0) {
            const setTitle = m.cast(*const fn (id, SEL, id) callconv(.c) void);
            setTitle(button, m.sel("setTitle:"), nsString(opts.label));
        }
        if (@intFromPtr(button) != 0 and opts.tooltip.len > 0) {
            const setToolTip = m.cast(*const fn (id, SEL, id) callconv(.c) void);
            setToolTip(button, m.sel("setToolTip:"), nsString(opts.tooltip));
        }

        return .{
            .status_item = item,
            .allocator = allocator,
            .on_click = opts.on_click,
            .on_click_ctx = opts.on_click_ctx,
            .on_menu_item = opts.on_menu_item,
            .on_menu_item_ctx = opts.on_menu_item_ctx,
        };
    }

    fn deinit(self: *MacosTray) void {
        if (builtin.os.tag != .macos) return;
        if (self.items_storage.len > 0) {
            freeMenu(self.allocator, self.items_storage);
            self.items_storage = &.{};
        }
        if (self.menu_obj) |menu_ptr| {
            const release = m.cast(*const fn (id, SEL) callconv(.c) void);
            release(menu_ptr, m.sel("release"));
            self.menu_obj = null;
        }
        if (g_macos_tray == self) g_macos_tray = null;
        const item = self.status_item orelse return;

        const NSStatusBar = m.getClass("NSStatusBar");
        const systemStatusBar = m.cast(*const fn (id, SEL) callconv(.c) id);
        const bar = systemStatusBar(@as(id, @ptrCast(NSStatusBar)), m.sel("systemStatusBar"));
        const removeStatusItem = m.cast(*const fn (id, SEL, id) callconv(.c) void);
        removeStatusItem(bar, m.sel("removeStatusItem:"), item);

        const release = m.cast(*const fn (id, SEL) callconv(.c) void);
        release(item, m.sel("release"));
        self.status_item = null;
    }

    fn setTooltip(self: *MacosTray, tooltip: []const u8) void {
        if (builtin.os.tag != .macos) return;
        const item = self.status_item orelse return;
        const button_sel = m.cast(*const fn (id, SEL) callconv(.c) id);
        const button = button_sel(item, m.sel("button"));
        if (@intFromPtr(button) == 0) return;
        const setToolTip = m.cast(*const fn (id, SEL, id) callconv(.c) void);
        setToolTip(button, m.sel("setToolTip:"), nsString(tooltip));
    }

    /// Load `path` via `[[NSImage alloc] initWithContentsOfFile:]`
    /// and assign to the status item's button. Sets the image as
    /// `template` so the menu bar applies its standard light/dark
    /// tint — works best with monochrome PNGs (transparent + black).
    /// Color icons still render but won't tint with the bar.
    fn setIcon(self: *MacosTray, path: []const u8) Error!void {
        if (builtin.os.tag != .macos) return error.Unsupported;
        const item = self.status_item orelse return error.Backend;
        const button_sel = m.cast(*const fn (id, SEL) callconv(.c) id);
        const button = button_sel(item, m.sel("button"));
        if (@intFromPtr(button) == 0) return error.Backend;

        const NSImage = m.getClass("NSImage");
        const alloc_id = m.cast(*const fn (id, SEL) callconv(.c) id);
        const init_with_file = m.cast(*const fn (id, SEL, id) callconv(.c) id);
        const img_raw = alloc_id(@as(id, @ptrCast(NSImage)), m.sel("alloc"));
        const img = init_with_file(img_raw, m.sel("initWithContentsOfFile:"), nsString(path));
        if (@intFromPtr(img) == 0) {
            // Release the alloc'd shell so we don't leak.
            const release = m.cast(*const fn (id, SEL) callconv(.c) void);
            release(img_raw, m.sel("release"));
            return error.Backend;
        }

        // Template = tint follows menu bar style. Safe default; if a
        // future caller wants color-preserved icons it can layer a
        // `setTemplate:` toggle on top.
        const set_template = m.cast(*const fn (id, SEL, bool) callconv(.c) void);
        set_template(img, m.sel("setTemplate:"), true);

        const set_image = m.cast(*const fn (id, SEL, id) callconv(.c) void);
        set_image(button, m.sel("setImage:"), img);

        // Clear the label when an icon is set — having both reads
        // poorly in the menu bar. Callers can still re-`setTitle:`
        // through their own NSStatusItem if they want both.
        const setTitle = m.cast(*const fn (id, SEL, id) callconv(.c) void);
        setTitle(button, m.sel("setTitle:"), nsString(""));

        // Release our retain — the button holds its own ref now.
        const release = m.cast(*const fn (id, SEL) callconv(.c) void);
        release(img, m.sel("release"));
    }

    /// Set the tray icon to an SF Symbol by name. macOS 11+ only —
    /// older OSes return `error.Unsupported`. Pairs with
    /// `TrayOptions.icon_symbol`; the rendered image is implicitly a
    /// template so the menu bar tints it light/dark.
    fn setIconSymbol(self: *MacosTray, symbol_name: []const u8) Error!void {
        if (builtin.os.tag != .macos) return error.Unsupported;
        const item = self.status_item orelse return error.Backend;
        const button_sel = m.cast(*const fn (id, SEL) callconv(.c) id);
        const button = button_sel(item, m.sel("button"));
        if (@intFromPtr(button) == 0) return error.Backend;

        const NSImage = m.getClass("NSImage");
        const make = m.cast(*const fn (id, SEL, id, id) callconv(.c) id);
        const img = make(
            @as(id, @ptrCast(NSImage)),
            m.sel("imageWithSystemSymbolName:accessibilityDescription:"),
            nsString(symbol_name),
            nsString("verve tray"),
        );
        // Returns nil if the symbol name isn't known to the running
        // SF Symbols catalog — surface as Backend so the caller can
        // fall back to a label.
        if (@intFromPtr(img) == 0) return error.Backend;

        const set_image = m.cast(*const fn (id, SEL, id) callconv(.c) void);
        set_image(button, m.sel("setImage:"), img);

        // Clear the label when an icon is set (same rationale as setIcon).
        const setTitle = m.cast(*const fn (id, SEL, id) callconv(.c) void);
        setTitle(button, m.sel("setTitle:"), nsString(""));
    }

    fn setMenu(self: *MacosTray, items: []const TrayMenuItem) Error!void {
        if (builtin.os.tag != .macos) return error.Unsupported;

        if (self.items_storage.len > 0) {
            freeMenu(self.allocator, self.items_storage);
            self.items_storage = &.{};
        }
        if (self.menu_obj) |menu_ptr| {
            const release = m.cast(*const fn (id, SEL) callconv(.c) void);
            release(menu_ptr, m.sel("release"));
            self.menu_obj = null;
        }

        if (items.len == 0) {
            if (self.status_item) |item| {
                const setMenuSel = m.cast(*const fn (id, SEL, id) callconv(.c) void);
                setMenuSel(item, m.sel("setMenu:"), null);
            }
            return;
        }

        g_macos_tray = self;
        self.items_storage = try deepCopyMenu(self.allocator, items);

        const target = ensureTrayTarget();
        const menu = buildMacMenu(self.items_storage, target);

        // Retain so we can release on tear-down without relying on
        // the autorelease pool living past run loop turn.
        const retain = m.cast(*const fn (id, SEL) callconv(.c) id);
        _ = retain(menu, m.sel("retain"));
        self.menu_obj = menu;

        if (self.status_item) |item| {
            const setMenuSel = m.cast(*const fn (id, SEL, id) callconv(.c) void);
            setMenuSel(item, m.sel("setMenu:"), menu);
        }
    }

    fn wireButtonClick(self: *MacosTray) void {
        if (builtin.os.tag != .macos) return;
        const item = self.status_item orelse return;
        const button_sel = m.cast(*const fn (id, SEL) callconv(.c) id);
        const button = button_sel(item, m.sel("button"));
        if (@intFromPtr(button) == 0) return;
        const target = ensureTrayTarget();
        const set_target = m.cast(*const fn (id, SEL, id) callconv(.c) void);
        set_target(button, m.sel("setTarget:"), target);
        const set_action = m.cast(*const fn (id, SEL, SEL) callconv(.c) void);
        set_action(button, m.sel("setAction:"), m.sel("verveTrayClick:"));
    }

    fn buildMacMenu(items: []const TrayMenuItem, target: id) id {
        const NSMenu = m.getClass("NSMenu");
        const NSMenuItem = m.getClass("NSMenuItem");
        const alloc_id = m.cast(*const fn (id, SEL) callconv(.c) id);
        const init_id = m.cast(*const fn (id, SEL) callconv(.c) id);
        const add_item = m.cast(*const fn (id, SEL, id) callconv(.c) void);
        const separator_item = m.cast(*const fn (id, SEL) callconv(.c) id);
        const init_action = m.cast(*const fn (id, SEL, id, SEL, id) callconv(.c) id);
        const set_target = m.cast(*const fn (id, SEL, id) callconv(.c) void);
        const set_tag = m.cast(*const fn (id, SEL, isize) callconv(.c) void);
        const set_enabled = m.cast(*const fn (id, SEL, bool) callconv(.c) void);
        const set_submenu = m.cast(*const fn (id, SEL, id) callconv(.c) void);

        const menu = init_id(alloc_id(@as(id, @ptrCast(NSMenu)), m.sel("alloc")), m.sel("init"));

        for (items) |it| {
            if (it.label == null) {
                const sep = separator_item(@as(id, @ptrCast(NSMenuItem)), m.sel("separatorItem"));
                add_item(menu, m.sel("addItem:"), sep);
                continue;
            }
            // Leaf items get the trampoline action; submenu parents get
            // a null action so clicking the row only expands.
            const is_leaf = it.children.len == 0;
            const action_sel: SEL = if (is_leaf) m.sel("verveTrayItem:") else null;
            const item_obj = init_action(
                alloc_id(@as(id, @ptrCast(NSMenuItem)), m.sel("alloc")),
                m.sel("initWithTitle:action:keyEquivalent:"),
                nsString(it.label.?),
                action_sel,
                nsString(""),
            );
            set_tag(item_obj, m.sel("setTag:"), @as(isize, @intCast(it.id)));
            if (is_leaf) set_target(item_obj, m.sel("setTarget:"), target);
            if (!it.enabled) set_enabled(item_obj, m.sel("setEnabled:"), false);
            if (!is_leaf) {
                const sub = buildMacMenu(it.children, target);
                set_submenu(item_obj, m.sel("setSubmenu:"), sub);
            }
            add_item(menu, m.sel("addItem:"), item_obj);
        }
        return menu;
    }

    fn nsString(s: []const u8) id {
        if (builtin.os.tag != .macos) return null;
        const NSString = m.getClass("NSString");
        const stringWithUTF8 = m.cast(*const fn (id, SEL, [*]const u8) callconv(.c) id);
        var buf: [512]u8 = undefined;
        const len = @min(s.len, buf.len - 1);
        @memcpy(buf[0..len], s[0..len]);
        buf[len] = 0;
        return stringWithUTF8(@as(id, @ptrCast(NSString)), m.sel("stringWithUTF8String:"), &buf);
    }
};

// v1 single-tray-per-process. The target NSObject reads this when the
// runtime dispatches `verveTrayItem:` / `verveTrayClick:`. Set in init
// after the impl is heap-pinned so the pointer outlives the by-value
// stack-return from `bareInit`.
var g_macos_tray: ?*MacosTray = null;
var g_macos_tray_target: ?MacosTray.id = null;
var g_macos_tray_class_registered: bool = false;

fn ensureTrayTarget() MacosTray.id {
    if (builtin.os.tag != .macos) return null;
    if (g_macos_tray_target) |t| return t;

    const msg = @import("msg.zig");
    const NSObject = msg.getClass("NSObject");
    const cls = blk: {
        if (g_macos_tray_class_registered) {
            const looked = msg.objc_lookUpClass("VerveTrayTarget") orelse @panic("VerveTrayTarget vanished");
            break :blk looked;
        }
        const c = msg.allocateClass(NSObject, "VerveTrayTarget");
        msg.addMethod(c, msg.sel("verveTrayItem:"), @ptrCast(&trayItemAction), "v@:@");
        msg.addMethod(c, msg.sel("verveTrayClick:"), @ptrCast(&trayClickAction), "v@:@");
        msg.registerClass(c);
        g_macos_tray_class_registered = true;
        break :blk c;
    };

    const alloc_id = msg.cast(*const fn (MacosTray.id, MacosTray.SEL) callconv(.c) MacosTray.id);
    const init_id = msg.cast(*const fn (MacosTray.id, MacosTray.SEL) callconv(.c) MacosTray.id);
    const target = init_id(alloc_id(@as(MacosTray.id, @ptrCast(cls)), msg.sel("alloc")), msg.sel("init"));
    g_macos_tray_target = target;
    return target;
}

fn trayItemAction(_self: MacosTray.id, _cmd: MacosTray.SEL, sender: MacosTray.id) callconv(.c) void {
    _ = _self;
    _ = _cmd;
    if (builtin.os.tag != .macos) return;
    const tray = g_macos_tray orelse return;
    const cb = tray.on_menu_item orelse return;
    const msg = @import("msg.zig");
    const getTag = msg.cast(*const fn (MacosTray.id, MacosTray.SEL) callconv(.c) isize);
    const tag = getTag(sender, msg.sel("tag"));
    cb(tray.on_menu_item_ctx, @as(u32, @intCast(tag)));
}

fn trayClickAction(_self: MacosTray.id, _cmd: MacosTray.SEL, _sender: MacosTray.id) callconv(.c) void {
    _ = _self;
    _ = _cmd;
    _ = _sender;
    if (builtin.os.tag != .macos) return;
    const tray = g_macos_tray orelse return;
    const cb = tray.on_click orelse return;
    cb(tray.on_click_ctx);
}

// ---- Windows — Shell_NotifyIconW + NOTIFYICONDATAW + popup menu ------------

const WindowsTray = struct {
    hwnd: ?*anyopaque = null,
    uid: u32 = 1,
    /// Hidden — only flipped to true once `NIM_ADD` succeeded. `deinit`
    /// then issues the matching `NIM_DELETE`.
    added: bool = false,
    menu: ?*anyopaque = null,
    /// Currently displayed icon. Owned by us — `DestroyIcon` on
    /// teardown / replacement when this came from `LoadImageW` (the
    /// stock `IDI_APPLICATION` HICON from `LoadIconW` is shared and
    /// must NOT be destroyed). `owns_icon` tracks the distinction.
    icon: ?*anyopaque = null,
    owns_icon: bool = false,
    allocator: std.mem.Allocator = undefined,
    items_storage: []const TrayMenuItem = &.{},
    on_click: ?TrayClickHandler = null,
    on_click_ctx: ?*anyopaque = null,
    on_menu_item: ?TrayMenuItemHandler = null,
    on_menu_item_ctx: ?*anyopaque = null,

    const HWND = ?*opaque {};
    const HMENU = ?*opaque {};
    const HICON = ?*opaque {};
    const HINSTANCE = ?*opaque {};
    const DWORD = c_ulong;
    const UINT = c_uint;
    const BOOL = c_int;
    const LPCWSTR = ?[*:0]const u16;
    const GUID = extern struct {
        Data1: u32,
        Data2: u16,
        Data3: u16,
        Data4: [8]u8,
    };
    const POINT = extern struct { x: c_long, y: c_long };

    // `NOTIFYICONDATAW` from `<shellapi.h>`. The full struct grows with
    // shell versions; we use the V3 layout (cbSize covers fields up
    // through `hBalloonIcon`) which has been ABI-stable since XP SP2.
    const NOTIFYICONDATAW = extern struct {
        cbSize: DWORD = 0,
        hWnd: HWND = null,
        uID: UINT = 0,
        uFlags: UINT = 0,
        uCallbackMessage: UINT = 0,
        hIcon: HICON = null,
        szTip: [128]u16 = std.mem.zeroes([128]u16),
        dwState: DWORD = 0,
        dwStateMask: DWORD = 0,
        szInfo: [256]u16 = std.mem.zeroes([256]u16),
        uTimeoutOrVersion: UINT = 0,
        szInfoTitle: [64]u16 = std.mem.zeroes([64]u16),
        dwInfoFlags: DWORD = 0,
        guidItem: GUID = .{ .Data1 = 0, .Data2 = 0, .Data3 = 0, .Data4 = .{ 0, 0, 0, 0, 0, 0, 0, 0 } },
        hBalloonIcon: HICON = null,
    };

    const NIF_MESSAGE: UINT = 0x1;
    const NIF_ICON: UINT = 0x2;
    const NIF_TIP: UINT = 0x4;
    const NIM_ADD: DWORD = 0x0;
    const NIM_MODIFY: DWORD = 0x1;
    const NIM_DELETE: DWORD = 0x2;

    const MF_STRING: UINT = 0x0000;
    const MF_POPUP: UINT = 0x0010;
    const MF_SEPARATOR: UINT = 0x0800;
    const MF_GRAYED: UINT = 0x0001;

    const TPM_LEFTALIGN: UINT = 0x0000;
    const TPM_RIGHTBUTTON: UINT = 0x0002;
    const TPM_BOTTOMALIGN: UINT = 0x0020;

    /// Mouse message IDs that arrive in `lParam` for `WM_VERVE_TRAY`.
    const WM_LBUTTONUP: u32 = 0x0202;
    const WM_RBUTTONUP: u32 = 0x0205;
    const WM_CONTEXTMENU: u32 = 0x007B;
    const WM_NULL: UINT = 0x0000;

    /// Tray menu IDs occupy `0xC000–0xCFFF` to avoid clashing with the
    /// default File/Edit IDs (`0x8000` block in `windows.zig`).
    pub const TRAY_ID_RANGE: u16 = 0xC000;
    pub const TRAY_ID_USER_MASK: u16 = 0x0FFF;

    // `IDI_APPLICATION` is the stock icon resource; `LoadIconW(NULL, IDI_APPLICATION)`
    // returns a shared HICON we never need to free.
    const IDI_APPLICATION: LPCWSTR = @ptrFromInt(32512);

    extern "shell32" fn Shell_NotifyIconW(message: DWORD, data: *NOTIFYICONDATAW) callconv(.winapi) BOOL;
    extern "user32" fn LoadIconW(hinst: HINSTANCE, name: LPCWSTR) callconv(.winapi) HICON;
    extern "user32" fn LoadImageW(hinst: HINSTANCE, name: LPCWSTR, ty: UINT, cx_size: c_int, cy_size: c_int, fuLoad: UINT) callconv(.winapi) ?*anyopaque;
    extern "user32" fn DestroyIcon(icon: HICON) callconv(.winapi) BOOL;
    extern "user32" fn CreatePopupMenu() callconv(.winapi) HMENU;
    extern "user32" fn AppendMenuW(menu: HMENU, flags: UINT, id: usize, name: LPCWSTR) callconv(.winapi) BOOL;
    extern "user32" fn DestroyMenu(menu: HMENU) callconv(.winapi) BOOL;
    extern "user32" fn TrackPopupMenu(
        menu: HMENU,
        flags: UINT,
        x: c_int,
        y: c_int,
        reserved: c_int,
        hwnd: HWND,
        rect: ?*anyopaque,
    ) callconv(.winapi) BOOL;
    extern "user32" fn GetCursorPos(p: *POINT) callconv(.winapi) BOOL;
    extern "user32" fn SetForegroundWindow(hwnd: HWND) callconv(.winapi) BOOL;
    extern "user32" fn PostMessageW(hwnd: HWND, msg: UINT, w: usize, l: isize) callconv(.winapi) BOOL;

    fn bareInit(allocator: std.mem.Allocator, window: *window_mod.Window, opts: TrayOptions) Error!WindowsTray {
        if (builtin.os.tag != .windows) return error.Unsupported;

        const hwnd: HWND = @ptrCast(@alignCast(getHwnd(window) orelse return error.Backend));
        const icon = LoadIconW(null, IDI_APPLICATION);

        var nid: NOTIFYICONDATAW = .{};
        nid.cbSize = @sizeOf(NOTIFYICONDATAW);
        nid.hWnd = hwnd;
        nid.uID = 1;
        nid.uFlags = NIF_ICON | NIF_TIP | NIF_MESSAGE;
        nid.uCallbackMessage = windowsTrayMessage();
        nid.hIcon = icon;

        // Tooltip is UTF-16, capped at 127 chars + NUL.
        if (opts.tooltip.len > 0) {
            const written = std.unicode.utf8ToUtf16Le(&nid.szTip, opts.tooltip) catch 0;
            nid.szTip[@min(nid.szTip.len - 1, written)] = 0;
        }

        if (Shell_NotifyIconW(NIM_ADD, &nid) == 0) return error.Backend;

        return .{
            .hwnd = @ptrCast(hwnd),
            .uid = 1,
            .added = true,
            .icon = @ptrCast(icon),
            .owns_icon = false,
            .allocator = allocator,
            .on_click = opts.on_click,
            .on_click_ctx = opts.on_click_ctx,
            .on_menu_item = opts.on_menu_item,
            .on_menu_item_ctx = opts.on_menu_item_ctx,
        };
    }

    /// Load `path` (expected `.ico`) via `LoadImageW(LR_LOADFROMFILE
    /// | LR_DEFAULTSIZE)` and ship to the tray via
    /// `Shell_NotifyIconW(NIM_MODIFY, NIF_ICON)`. Previous icon is
    /// destroyed when we owned it (loaded ourselves); the initial
    /// stock `IDI_APPLICATION` HICON is shared and never destroyed.
    fn setIcon(self: *WindowsTray, path: []const u8) Error!void {
        if (builtin.os.tag != .windows) return error.Unsupported;
        if (!self.added) return error.Backend;

        const IMAGE_ICON: UINT = 1;
        const LR_LOADFROMFILE: UINT = 0x10;
        const LR_DEFAULTSIZE: UINT = 0x40;

        // Convert path → UTF-16 NUL-terminated.
        var wbuf: [1024]u16 = std.mem.zeroes([1024]u16);
        const written = std.unicode.utf8ToUtf16Le(&wbuf, path) catch return error.Backend;
        if (written >= wbuf.len) return error.Backend;
        wbuf[written] = 0;

        const new_icon = LoadImageW(
            null,
            @ptrCast(&wbuf),
            IMAGE_ICON,
            0,
            0,
            LR_LOADFROMFILE | LR_DEFAULTSIZE,
        ) orelse return error.Backend;

        var nid: NOTIFYICONDATAW = .{};
        nid.cbSize = @sizeOf(NOTIFYICONDATAW);
        nid.hWnd = @ptrCast(@alignCast(self.hwnd));
        nid.uID = self.uid;
        nid.uFlags = NIF_ICON;
        nid.hIcon = @ptrCast(@alignCast(new_icon));
        if (Shell_NotifyIconW(NIM_MODIFY, &nid) == 0) {
            _ = DestroyIcon(@ptrCast(@alignCast(new_icon)));
            return error.Backend;
        }

        // Drop the previous icon if we owned it (LoadImageW loads
        // are caller-owned). The stock IDI_APPLICATION HICON from
        // LoadIconW is process-shared — never destroy it.
        if (self.owns_icon) {
            if (self.icon) |old| _ = DestroyIcon(@ptrCast(@alignCast(old)));
        }
        self.icon = @ptrCast(new_icon);
        self.owns_icon = true;
    }

    fn deinit(self: *WindowsTray) void {
        if (builtin.os.tag != .windows) return;
        if (self.added) {
            var nid: NOTIFYICONDATAW = .{};
            nid.cbSize = @sizeOf(NOTIFYICONDATAW);
            nid.hWnd = @ptrCast(@alignCast(self.hwnd));
            nid.uID = self.uid;
            _ = Shell_NotifyIconW(NIM_DELETE, &nid);
            self.added = false;
        }
        if (self.owns_icon) {
            if (self.icon) |old| _ = DestroyIcon(@ptrCast(@alignCast(old)));
        }
        self.icon = null;
        self.owns_icon = false;
        if (self.menu) |m_ptr| {
            _ = DestroyMenu(@as(HMENU, @ptrCast(@alignCast(m_ptr))));
            self.menu = null;
        }
        if (self.items_storage.len > 0) {
            freeMenu(self.allocator, self.items_storage);
            self.items_storage = &.{};
        }
        if (g_windows_tray == self) g_windows_tray = null;
    }

    fn setTooltip(self: *WindowsTray, tooltip: []const u8) void {
        if (builtin.os.tag != .windows) return;
        if (!self.added) return;
        var nid: NOTIFYICONDATAW = .{};
        nid.cbSize = @sizeOf(NOTIFYICONDATAW);
        nid.hWnd = @ptrCast(@alignCast(self.hwnd));
        nid.uID = self.uid;
        nid.uFlags = NIF_TIP;
        const written = std.unicode.utf8ToUtf16Le(&nid.szTip, tooltip) catch 0;
        nid.szTip[@min(nid.szTip.len - 1, written)] = 0;
        _ = Shell_NotifyIconW(NIM_MODIFY, &nid);
    }

    fn setMenu(self: *WindowsTray, items: []const TrayMenuItem) Error!void {
        if (builtin.os.tag != .windows) return error.Unsupported;

        if (self.menu) |m_ptr| {
            _ = DestroyMenu(@as(HMENU, @ptrCast(@alignCast(m_ptr))));
            self.menu = null;
        }
        if (self.items_storage.len > 0) {
            freeMenu(self.allocator, self.items_storage);
            self.items_storage = &.{};
        }

        if (items.len == 0) return;
        self.items_storage = try deepCopyMenu(self.allocator, items);

        const new_menu = try buildMenu(self.items_storage);
        self.menu = @ptrCast(new_menu);
    }

    fn buildMenu(items: []const TrayMenuItem) Error!HMENU {
        const menu = CreatePopupMenu() orelse return error.Backend;
        errdefer _ = DestroyMenu(menu);

        for (items) |it| {
            if (it.label == null) {
                _ = AppendMenuW(menu, MF_SEPARATOR, 0, null);
                continue;
            }
            var lbuf: [256]u16 = std.mem.zeroes([256]u16);
            const written = std.unicode.utf8ToUtf16Le(&lbuf, it.label.?) catch 0;
            lbuf[@min(lbuf.len - 1, written)] = 0;

            if (it.children.len > 0) {
                const sub = try buildMenu(it.children);
                const flags: UINT = MF_POPUP | (if (it.enabled) @as(UINT, 0) else MF_GRAYED);
                _ = AppendMenuW(menu, flags, @intFromPtr(sub), @ptrCast(&lbuf));
            } else {
                const flags: UINT = MF_STRING | (if (it.enabled) @as(UINT, 0) else MF_GRAYED);
                const user_id: u32 = it.id & @as(u32, TRAY_ID_USER_MASK);
                const tray_cmd_id: usize = @as(usize, TRAY_ID_RANGE) | @as(usize, user_id);
                _ = AppendMenuW(menu, flags, tray_cmd_id, @ptrCast(&lbuf));
            }
        }
        return menu;
    }

    /// Pop up `self.menu` near the cursor. Must run on the wndProc
    /// thread (the forwarder always invokes us synchronously from
    /// `WM_VERVE_TRAY`). The MSDN-recommended foreground +
    /// `PostMessage(WM_NULL)` dance keeps the dismiss-on-outside-click
    /// semantics working.
    fn showPopup(self: *WindowsTray) void {
        if (builtin.os.tag != .windows) return;
        const menu_handle = self.menu orelse return;
        var pt: POINT = .{ .x = 0, .y = 0 };
        _ = GetCursorPos(&pt);
        const hwnd: HWND = @ptrCast(@alignCast(self.hwnd));
        _ = SetForegroundWindow(hwnd);
        const flags: UINT = TPM_RIGHTBUTTON | TPM_BOTTOMALIGN | TPM_LEFTALIGN;
        _ = TrackPopupMenu(@as(HMENU, @ptrCast(@alignCast(menu_handle))), flags, pt.x, pt.y, 0, hwnd, null);
        _ = PostMessageW(hwnd, WM_NULL, 0, 0);
    }

    fn getHwnd(window: *window_mod.Window) ?*anyopaque {
        if (builtin.os.tag != .windows) return null;
        const w_backend = if (builtin.os.tag == .windows) @import("backend.zig").impl else struct {};
        return w_backend.hwndOf(window);
    }

    fn windowsTrayMessage() UINT {
        if (builtin.os.tag != .windows) return 0;
        const w_backend = @import("backend.zig").impl;
        return w_backend.WM_VERVE_TRAY;
    }
};

// v1 single-tray-per-process. wndProc forwarders read this on
// WM_COMMAND (tray ID range) / WM_VERVE_TRAY.
var g_windows_tray: ?*WindowsTray = null;
var windows_hooks_installed: bool = false;

/// Trigger a Windows balloon-tip / Action-Center entry through the
/// existing tray icon. Used by `notifications.show` on Windows in
/// lieu of the WinRT `ToastNotificationManager` stack (deferred until
/// the COM + AUMID + Start-menu plumbing lands). Returns
/// `error.Backend` if no tray has been initialized in this process —
/// Win notifications require an attached tray icon.
pub fn showWindowsBalloon(title: []const u8, body: []const u8) Error!void {
    if (builtin.os.tag != .windows) return error.Unsupported;
    const tray = g_windows_tray orelse return error.Backend;
    if (!tray.added) return error.Backend;

    const NIIF_INFO: WindowsTray.UINT = 0x1;
    const NIF_INFO: WindowsTray.UINT = 0x10;

    var nid: WindowsTray.NOTIFYICONDATAW = .{};
    nid.cbSize = @sizeOf(WindowsTray.NOTIFYICONDATAW);
    nid.hWnd = @ptrCast(@alignCast(tray.hwnd));
    nid.uID = tray.uid;
    nid.uFlags = NIF_INFO;
    nid.dwInfoFlags = NIIF_INFO;

    // szInfoTitle is u16[64], szInfo is u16[256] — both NUL-terminated.
    const t_written = std.unicode.utf8ToUtf16Le(&nid.szInfoTitle, title) catch 0;
    nid.szInfoTitle[@min(nid.szInfoTitle.len - 1, t_written)] = 0;
    const b_written = std.unicode.utf8ToUtf16Le(&nid.szInfo, body) catch 0;
    nid.szInfo[@min(nid.szInfo.len - 1, b_written)] = 0;

    if (WindowsTray.Shell_NotifyIconW(WindowsTray.NIM_MODIFY, &nid) == 0) return error.Backend;
}

fn installWindowsDispatchHooks() void {
    if (builtin.os.tag != .windows) return;
    if (windows_hooks_installed) return;
    const w_backend = @import("backend.zig").impl;
    w_backend.tray_dispatch_command = &handleWindowsTrayCommand;
    w_backend.tray_dispatch_message = &handleWindowsTrayMessage;
    windows_hooks_installed = true;
}

/// Called from `windows.zig` wndProc on `WM_COMMAND` for IDs whose top
/// nibble is `0xC` (tray range). Returns true once consumed so the
/// caller doesn't also route the ID through the default-menu path.
pub fn handleWindowsTrayCommand(_hwnd: ?*anyopaque, cmd_id: u16) bool {
    if (builtin.os.tag != .windows) return false;
    _ = _hwnd;
    const tray = g_windows_tray orelse return false;
    const user_id: u32 = @as(u32, cmd_id) & @as(u32, WindowsTray.TRAY_ID_USER_MASK);
    if (tray.on_menu_item) |cb| cb(tray.on_menu_item_ctx, user_id);
    return true;
}

/// Called from `windows.zig` wndProc on `WM_VERVE_TRAY`. lParam's low
/// word carries the mouse-event ID — left click fires `on_click` (or
/// shows the menu if none), right click / context always shows the
/// menu.
pub fn handleWindowsTrayMessage(_hwnd: ?*anyopaque, _wparam: usize, lparam: isize) void {
    if (builtin.os.tag != .windows) return;
    _ = _hwnd;
    _ = _wparam;
    const tray = g_windows_tray orelse return;
    const event: u32 = @as(u32, @intCast(@as(usize, @bitCast(lparam)) & 0xFFFF));
    switch (event) {
        WindowsTray.WM_LBUTTONUP => {
            if (tray.on_click) |cb| cb(tray.on_click_ctx) else tray.showPopup();
        },
        WindowsTray.WM_RBUTTONUP, WindowsTray.WM_CONTEXTMENU => tray.showPopup(),
        else => {},
    }
}

// ---- Linux — libayatana-appindicator3 + GtkMenu ----------------------------

const LinuxTray = struct {
    // Comptime: is GTK4 the active backend? On non-Linux hosts always false so
    // @import("desktop_options") is never evaluated (only the .linux switch arm
    // in backend.zig compiles this struct's methods).
    const use_gtk4: bool = blk: {
        if (builtin.os.tag != .linux) break :blk false;
        break :blk @import("desktop_options").gtk4;
    };

    indicator: ?*anyopaque = null,
    menu: ?*anyopaque = null,
    allocator: std.mem.Allocator = undefined,
    items_storage: []const TrayMenuItem = &.{},
    item_boxes: std.ArrayListUnmanaged(*ItemBox) = .empty,
    on_click: ?TrayClickHandler = null,
    on_click_ctx: ?*anyopaque = null,
    on_menu_item: ?TrayMenuItemHandler = null,
    on_menu_item_ctx: ?*anyopaque = null,

    const AppIndicator = opaque {};
    const GtkWidget = opaque {};
    const GtkMenuShell = opaque {};
    const GtkMenuItem = opaque {};
    const AppIndicatorCategory = c_uint;
    const AppIndicatorStatus = c_uint;
    const GCallback = *const fn () callconv(.c) void;
    const GConnectFlags = c_uint;
    const gboolean = c_int;

    const APP_INDICATOR_CATEGORY_APPLICATION_STATUS: AppIndicatorCategory = 0;
    const APP_INDICATOR_STATUS_ACTIVE: AppIndicatorStatus = 1;

    const ItemBox = struct {
        tray: *LinuxTray,
        id: u32,
    };

    // libayatana-appindicator3 is loaded at runtime via dlopen so
    // Verve apps that never call `Tray.init` build and run on distros
    // without it (Alpine, slim containers, headless servers). Apps
    // that DO call init get `error.Unsupported` if the lib is missing
    // instead of a link-time failure that affects every Linux scaffold.
    const NewFn = *const fn ([*:0]const u8, [*:0]const u8, AppIndicatorCategory) callconv(.c) *AppIndicator;
    const SetStatusFn = *const fn (*AppIndicator, AppIndicatorStatus) callconv(.c) void;
    const SetTextFn = *const fn (*AppIndicator, [*:0]const u8) callconv(.c) void;
    const SetLabelFn = *const fn (*AppIndicator, [*:0]const u8, [*:0]const u8) callconv(.c) void;
    const SetIconFullFn = *const fn (*AppIndicator, [*:0]const u8, [*:0]const u8) callconv(.c) void;
    const SetMenuFn = *const fn (*AppIndicator, *GtkWidget) callconv(.c) void;

    const LibAyatana = struct {
        new: NewFn,
        set_status: SetStatusFn,
        set_title: SetTextFn,
        set_label: SetLabelFn,
        set_icon_full: SetIconFullFn,
        set_menu: SetMenuFn,
    };

    var g_ayatana: ?LibAyatana = null;
    var g_ayatana_tried: bool = false;

    fn loadAyatana() ?*const LibAyatana {
        if (g_ayatana_tried) {
            return if (g_ayatana) |*v| v else null;
        }
        g_ayatana_tried = true;

        // Try the modern soname first, fall back to the unversioned
        // dev-package name. Both link to the same .so on every distro
        // shipping libayatana.
        const candidates = [_][:0]const u8{
            "libayatana-appindicator3.so.1",
            "libayatana-appindicator3.so",
        };
        var handle: ?*anyopaque = null;
        for (candidates) |name| {
            handle = std.c.dlopen(name.ptr, .{ .LAZY = true });
            if (handle != null) break;
        }
        if (handle == null) return null;

        const new_p = std.c.dlsym(handle, "app_indicator_new") orelse return null;
        const set_status_p = std.c.dlsym(handle, "app_indicator_set_status") orelse return null;
        const set_title_p = std.c.dlsym(handle, "app_indicator_set_title") orelse return null;
        const set_label_p = std.c.dlsym(handle, "app_indicator_set_label") orelse return null;
        const set_icon_full_p = std.c.dlsym(handle, "app_indicator_set_icon_full") orelse return null;
        const set_menu_p = std.c.dlsym(handle, "app_indicator_set_menu") orelse return null;

        g_ayatana = .{
            .new = @ptrCast(@alignCast(new_p)),
            .set_status = @ptrCast(@alignCast(set_status_p)),
            .set_title = @ptrCast(@alignCast(set_title_p)),
            .set_label = @ptrCast(@alignCast(set_label_p)),
            .set_icon_full = @ptrCast(@alignCast(set_icon_full_p)),
            .set_menu = @ptrCast(@alignCast(set_menu_p)),
        };
        return &g_ayatana.?;
    }

    extern fn g_object_unref(o: ?*anyopaque) void;

    extern fn gtk_menu_new() *GtkWidget;
    extern fn gtk_menu_item_new_with_label(label: [*:0]const u8) *GtkWidget;
    extern fn gtk_separator_menu_item_new() *GtkWidget;
    extern fn gtk_menu_item_set_submenu(item: *GtkMenuItem, submenu: *GtkWidget) void;
    extern fn gtk_menu_shell_append(shell: *GtkMenuShell, child: *GtkWidget) void;
    extern fn gtk_widget_show(w: *GtkWidget) void;
    extern fn gtk_widget_show_all(w: *GtkWidget) void;
    extern fn gtk_widget_set_sensitive(w: *GtkWidget, sensitive: gboolean) void;
    extern fn g_signal_connect_data(
        instance: *anyopaque,
        signal: [*:0]const u8,
        handler: GCallback,
        data: ?*anyopaque,
        destroy: ?*anyopaque,
        flags: GConnectFlags,
    ) c_ulong;

    fn bareInit(allocator: std.mem.Allocator, _: *window_mod.Window, opts: TrayOptions) Error!LinuxTray {
        if (builtin.os.tag != .linux) return error.Unsupported;
        if (comptime use_gtk4) return error.Unsupported; // ayatana-appindicator3 links GTK3, conflicts with GTK4 process

        const ay = loadAyatana() orelse return error.Unsupported;

        const id_z = allocator.dupeZ(u8, "verve-desktop") catch return error.OutOfMemory;
        defer allocator.free(id_z);
        const icon_z = allocator.dupeZ(u8, "application-x-executable") catch return error.OutOfMemory;
        defer allocator.free(icon_z);

        const ind = ay.new(id_z.ptr, icon_z.ptr, APP_INDICATOR_CATEGORY_APPLICATION_STATUS);
        ay.set_status(ind, APP_INDICATOR_STATUS_ACTIVE);

        if (opts.tooltip.len > 0) {
            const t = allocator.dupeZ(u8, opts.tooltip) catch return error.OutOfMemory;
            defer allocator.free(t);
            ay.set_title(ind, t.ptr);
        }
        if (opts.label.len > 0) {
            const l = allocator.dupeZ(u8, opts.label) catch return error.OutOfMemory;
            defer allocator.free(l);
            ay.set_label(ind, l.ptr, l.ptr);
        }

        return .{
            .indicator = @ptrCast(ind),
            .allocator = allocator,
            .on_click = opts.on_click,
            .on_click_ctx = opts.on_click_ctx,
            .on_menu_item = opts.on_menu_item,
            .on_menu_item_ctx = opts.on_menu_item_ctx,
        };
    }

    fn deinit(self: *LinuxTray) void {
        if (builtin.os.tag != .linux) return;
        self.freeItemBoxes();
        if (self.items_storage.len > 0) {
            freeMenu(self.allocator, self.items_storage);
            self.items_storage = &.{};
        }
        if (self.indicator) |ind| {
            g_object_unref(ind);
            self.indicator = null;
        }
        // GtkMenu refs are owned by AppIndicator after set_menu — the
        // indicator's unref above tears them down transitively.
        self.menu = null;
    }

    fn setTooltip(self: *LinuxTray, tooltip: []const u8) void {
        if (builtin.os.tag != .linux) return;
        const ay = loadAyatana() orelse return;
        const ind_raw = self.indicator orelse return;
        const ind: *AppIndicator = @ptrCast(@alignCast(ind_raw));
        const z = self.allocator.dupeZ(u8, tooltip) catch return;
        defer self.allocator.free(z);
        ay.set_title(ind, z.ptr);
    }

    /// Forward to `app_indicator_set_icon_full`. Path may be an
    /// absolute filename (PNG — Ayatana accepts) or a theme icon
    /// name; both signatures route through the same API call.
    fn setIcon(self: *LinuxTray, path: []const u8) Error!void {
        if (builtin.os.tag != .linux) return error.Unsupported;
        const ay = loadAyatana() orelse return error.Unsupported;
        const ind_raw = self.indicator orelse return error.Backend;
        const ind: *AppIndicator = @ptrCast(@alignCast(ind_raw));
        const z = self.allocator.dupeZ(u8, path) catch return error.OutOfMemory;
        defer self.allocator.free(z);
        const desc = self.allocator.dupeZ(u8, "verve tray") catch return error.OutOfMemory;
        defer self.allocator.free(desc);
        ay.set_icon_full(ind, z.ptr, desc.ptr);
    }

    fn setMenu(self: *LinuxTray, items: []const TrayMenuItem) Error!void {
        if (builtin.os.tag != .linux) return error.Unsupported;
        if (comptime use_gtk4) return; // GtkMenu removed in GTK4; tray menu unsupported
        self.freeItemBoxes();
        if (self.items_storage.len > 0) {
            freeMenu(self.allocator, self.items_storage);
            self.items_storage = &.{};
        }
        if (items.len > 0) {
            self.items_storage = try deepCopyMenu(self.allocator, items);
        }

        // Some Ayatana versions refuse to draw the icon without a menu
        // attached, so we always set one — empty input still produces
        // an empty GtkMenu so the icon shows up.
        const built = try self.buildLinuxMenu(self.items_storage);
        gtk_widget_show_all(built);
        self.menu = @ptrCast(built);
        if (self.indicator) |ind_raw| {
            if (loadAyatana()) |ay| {
                const ind: *AppIndicator = @ptrCast(@alignCast(ind_raw));
                ay.set_menu(ind, built);
            }
        }
    }

    fn buildLinuxMenu(self: *LinuxTray, items: []const TrayMenuItem) Error!*GtkWidget {
        if (comptime use_gtk4) return error.Unsupported;
        const menu = gtk_menu_new();
        for (items) |it| {
            const child = blk: {
                if (it.label == null) break :blk gtk_separator_menu_item_new();
                const lz = self.allocator.dupeZ(u8, it.label.?) catch return error.OutOfMemory;
                defer self.allocator.free(lz);
                const item_widget = gtk_menu_item_new_with_label(lz.ptr);
                if (!it.enabled) gtk_widget_set_sensitive(item_widget, 0);
                if (it.children.len > 0) {
                    const sub = try self.buildLinuxMenu(it.children);
                    gtk_menu_item_set_submenu(@ptrCast(item_widget), sub);
                } else {
                    const box = self.allocator.create(ItemBox) catch return error.OutOfMemory;
                    box.* = .{ .tray = self, .id = it.id };
                    self.item_boxes.append(self.allocator, box) catch {
                        self.allocator.destroy(box);
                        return error.OutOfMemory;
                    };
                    _ = g_signal_connect_data(
                        @ptrCast(item_widget),
                        "activate",
                        @as(GCallback, @ptrCast(&onTrayItemActivate)),
                        @ptrCast(box),
                        null,
                        0,
                    );
                }
                break :blk item_widget;
            };
            gtk_menu_shell_append(@ptrCast(menu), child);
            gtk_widget_show(child);
        }
        return menu;
    }

    fn freeItemBoxes(self: *LinuxTray) void {
        for (self.item_boxes.items) |box| self.allocator.destroy(box);
        self.item_boxes.deinit(self.allocator);
        self.item_boxes = .empty;
    }
};

fn onTrayItemActivate(_: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    if (builtin.os.tag != .linux) return;
    const box: *LinuxTray.ItemBox = @ptrCast(@alignCast(user_data orelse return));
    const tray = box.tray;
    if (tray.on_menu_item) |cb| cb(tray.on_menu_item_ctx, box.id);
}
