//! `verve-cli` — scaffolds a self-contained starter project.
//!
//! Usage:
//!   verve-cli new <target-dir> [--name=<pkg-name>] [--web | --desktop]
//!
//! The Verve source tree, build wiring, and tests fixture are embedded
//! into this binary at build time (see build.zig:buildCliSkeleton and
//! build.zig:buildCliSkeletonDesktop). The `new` subcommand writes them
//! all into the target directory and emits a fresh build.zig.zon with
//! the user's chosen package name (defaults to the target directory's
//! basename).
//!
//! Two skeleton variants ship inside the binary:
//!   • `--web`     — default, produces the standard HTTP server app.
//!   • `--desktop` — produces a native desktop app embedding WKWebView
//!                   / WebView2 / WebKitGTK via the platform layer at
//!                   `src/desktop/`.

const std = @import("std");
const builtin = @import("builtin");
const skeleton = @import("skeleton");
const skeleton_desktop = @import("skeleton_desktop");
const skeleton_desktop_minimal = @import("skeleton_desktop_minimal");
const build_options = @import("build_options");

const Kind = enum { web, desktop };

/// Desktop scaffold variants. `full` is the demo-rich template
/// (cookies, multi-window, WASM hydration, tray, notifications, deep
/// links, print, smoke harness). `minimal` is a single-window app with
/// one IPC route and a static HTML page — useful as a clean starting
/// point. Only applies when `--desktop` is set.
const DesktopTemplate = enum { full, minimal };

/// When the user passes `--release <tag>`, the desktop scaffold's
/// `build.zig.zon` swaps the path-dep for a `.url + .hash` GitHub
/// archive dep. `hash` is optional — when null, the scaffold emits a
/// placeholder + a top-of-file comment instructing the user to run
/// `zig fetch --save <url>` once to fill it in.
const ReleaseSpec = struct {
    tag: []const u8,
    hash: ?[]const u8,
};

const RELEASE_REPO_OWNER = "sirhco";
const RELEASE_REPO_NAME = "verve";
const RELEASE_HASH_PLACEHOLDER = "REPLACE_ME_RUN_ZIG_FETCH";

const log = std.log.scoped(.@"verve-cli");

pub const std_options: std.Options = .{ .log_level = .info };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const program = if (args.len > 0) args[0] else "verve-cli";

    if (args.len < 2) {
        printUsage(program);
        return;
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        printUsage(program);
        return;
    }
    if (!std.mem.eql(u8, cmd, "new")) {
        log.err("unknown command: {s}", .{cmd});
        printUsage(program);
        return error.UnknownCommand;
    }

    var target_dir: ?[]const u8 = null;
    var name_opt: ?[]const u8 = null;
    var verve_path: []const u8 = build_options.default_verve_path;
    var kind: Kind = .web;
    var kind_explicit = false;
    var release_tag: ?[]const u8 = null;
    var release_hash: ?[]const u8 = null;
    var desktop_template: DesktopTemplate = .full;
    var template_explicit = false;

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.startsWith(u8, a, "--name=")) {
            name_opt = a["--name=".len..];
        } else if (std.mem.eql(u8, a, "--name")) {
            i += 1;
            if (i >= args.len) {
                log.err("--name requires a value", .{});
                return error.MissingValue;
            }
            name_opt = args[i];
        } else if (std.mem.startsWith(u8, a, "--verve-path=")) {
            verve_path = a["--verve-path=".len..];
        } else if (std.mem.eql(u8, a, "--verve-path")) {
            i += 1;
            if (i >= args.len) {
                log.err("--verve-path requires a value", .{});
                return error.MissingValue;
            }
            verve_path = args[i];
        } else if (std.mem.eql(u8, a, "--desktop")) {
            if (kind_explicit and kind != .desktop) {
                log.err("--desktop and --web are mutually exclusive", .{});
                return error.InvalidArgs;
            }
            kind = .desktop;
            kind_explicit = true;
        } else if (std.mem.eql(u8, a, "--web")) {
            if (kind_explicit and kind != .web) {
                log.err("--desktop and --web are mutually exclusive", .{});
                return error.InvalidArgs;
            }
            kind = .web;
            kind_explicit = true;
        } else if (std.mem.startsWith(u8, a, "--release=")) {
            release_tag = a["--release=".len..];
        } else if (std.mem.eql(u8, a, "--release")) {
            i += 1;
            if (i >= args.len) {
                log.err("--release requires a tag value (e.g. --release v0.1.0)", .{});
                return error.MissingValue;
            }
            release_tag = args[i];
        } else if (std.mem.startsWith(u8, a, "--template=")) {
            const v = a["--template=".len..];
            desktop_template = parseTemplate(v) catch {
                log.err("invalid --template value '{s}' (expected 'full' or 'minimal')", .{v});
                return error.InvalidArgs;
            };
            template_explicit = true;
        } else if (std.mem.eql(u8, a, "--template")) {
            i += 1;
            if (i >= args.len) {
                log.err("--template requires a value (full | minimal)", .{});
                return error.MissingValue;
            }
            desktop_template = parseTemplate(args[i]) catch {
                log.err("invalid --template value '{s}' (expected 'full' or 'minimal')", .{args[i]});
                return error.InvalidArgs;
            };
            template_explicit = true;
        } else if (std.mem.startsWith(u8, a, "--release-hash=")) {
            release_hash = a["--release-hash=".len..];
        } else if (std.mem.eql(u8, a, "--release-hash")) {
            i += 1;
            if (i >= args.len) {
                log.err("--release-hash requires a value", .{});
                return error.MissingValue;
            }
            release_hash = args[i];
        } else if (target_dir == null) {
            target_dir = a;
        } else {
            log.err("unexpected argument: {s}", .{a});
            return error.UnexpectedArgument;
        }
    }

    const dir_path = target_dir orelse {
        log.err("missing target directory", .{});
        printUsage(program);
        return error.MissingTargetDir;
    };

    if (release_hash != null and release_tag == null) {
        log.err("--release-hash requires --release <tag>", .{});
        return error.InvalidArgs;
    }
    if (release_tag != null and kind != .desktop) {
        log.warn("--release only affects desktop scaffolds; ignoring for --web", .{});
        release_tag = null;
        release_hash = null;
    }
    if (template_explicit and kind != .desktop) {
        log.warn("--template only affects desktop scaffolds; ignoring for --web", .{});
    }
    const release_spec: ?ReleaseSpec = if (release_tag) |t|
        .{ .tag = t, .hash = release_hash }
    else
        null;

    // Resolve package name. An explicit `--name` is taken verbatim and
    // validated strictly. A basename-derived name (the common case
    // when the user runs `verve-cli new my-project`) is sanitized: `-`
    // and `.` become `_` so a hyphenated directory still yields a
    // valid Zig identifier. If sanitization can't rescue the name
    // (e.g. leading digit, empty after strip), fall back to a clear
    // error pointing at `--name`.
    var pkg_name_buf: []u8 = &.{};
    defer if (pkg_name_buf.len > 0) init.gpa.free(pkg_name_buf);
    const pkg_name: []const u8 = blk: {
        if (name_opt) |n| {
            if (!isValidIdentifier(n)) {
                log.err("invalid package name '{s}' — must be a Zig identifier (a-z A-Z 0-9 _, no leading digit)", .{n});
                return error.InvalidName;
            }
            break :blk n;
        }
        const raw = basename(dir_path);
        if (isValidIdentifier(raw)) break :blk raw;
        pkg_name_buf = sanitizeIdentifier(init.gpa, raw) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.Unsalvageable => {
                log.err("cannot derive a Zig package name from directory '{s}'. Pass --name <pkg-name> explicitly (a-z A-Z 0-9 _, no leading digit).", .{raw});
                return error.InvalidName;
            },
        };
        log.info("derived package name '{s}' from directory '{s}' (override with --name)", .{ pkg_name_buf, raw });
        break :blk pkg_name_buf;
    };

    try scaffold(io, dir_path, pkg_name, kind, desktop_template, verve_path);

    // Zig's package fingerprint contains a name-derived half that only the
    // compiler knows how to compute. Probe `zig build` once to learn the
    // value and patch build.zig.zon — failures here are non-fatal; the
    // user can fill in the suggested value manually.
    //
    // The fingerprint probe always builds against the path-dep form of
    // the zon (that's what `scaffold` writes). After the probe finds
    // the fingerprint, `fixFingerprint` rewrites the zon — at that
    // point it folds in any `--release` form so the final on-disk zon
    // matches what the user asked for.
    fixFingerprint(io, init.gpa, dir_path, pkg_name, kind, verve_path, release_spec) catch |err| {
        log.warn(
            "could not auto-fill build.zig.zon fingerprint ({s}). Run `zig build` once and copy the suggested value into build.zig.zon.",
            .{@errorName(err)},
        );
    };

    log.info("scaffolded '{s}' ({s}) into {s}", .{ pkg_name, @tagName(kind), dir_path });
    log.info("next:", .{});
    log.info("  cd {s}", .{dir_path});
    log.info("  zig build", .{});
    switch (kind) {
        .web => log.info("  ./zig-out/bin/verve-server", .{}),
        .desktop => log.info("  ./zig-out/bin/app   # or `zig build run`", .{}),
    }
}

fn fixFingerprint(io: std.Io, gpa: std.mem.Allocator, dir_path: []const u8, pkg_name: []const u8, kind: Kind, verve_path: []const u8, release: ?ReleaseSpec) !void {
    var child = std.process.spawn(io, .{
        .argv = &.{ "zig", "build" },
        .cwd = .{ .path = dir_path },
        .stdout = .ignore,
        .stderr = .pipe,
    }) catch |err| {
        return err;
    };

    const stderr = child.stderr orelse {
        _ = try child.wait(io);
        return error.NoStderr;
    };

    var read_buf: [8 * 1024]u8 = undefined;
    var sr = stderr.reader(io, &read_buf);
    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(gpa);
    while (true) {
        const slice = sr.interface.peekGreedy(1) catch break;
        acc.appendSlice(gpa, slice) catch break;
        sr.interface.toss(slice.len);
    }
    _ = try child.wait(io);

    const marker = "use this value: 0x";
    const idx = std.mem.indexOf(u8, acc.items, marker) orelse return error.NoFingerprintSuggestion;
    const start = idx + marker.len;
    var end = start;
    while (end < acc.items.len and std.ascii.isHex(acc.items[end])) end += 1;
    if (end == start) return error.NoFingerprintSuggestion;
    const fp = try std.fmt.parseInt(u64, acc.items[start..end], 16);

    var root = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
    defer root.close(io);

    const rel_verve = if (kind == .desktop)
        try resolveRelativeVervePath(io, gpa, dir_path, verve_path)
    else
        try gpa.dupe(u8, "");
    defer gpa.free(rel_verve);

    const new_zon = try renderZonFull(pkg_name, fp, gpa, kind, rel_verve, release);
    defer gpa.free(new_zon);

    var file = try root.createFile(io, "build.zig.zon", .{});
    defer file.close(io);
    try file.writePositionalAll(io, new_zon, 0);
}

fn canonicalize(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    // Stdlib realpath resolves symlinks (notably macOS's /tmp →
    // /private/tmp) so the subsequent `relativePosix` produces a path
    // that Zig's build.zig.zon parser will actually find on disk.
    // Portable across macOS / Linux / Windows — no direct libc dep.
    if (std.Io.Dir.realPathFileAbsoluteAlloc(io, path, gpa)) |resolved| {
        defer gpa.free(resolved);
        // Strip sentinel; callers free as plain []u8.
        return gpa.dupe(u8, resolved);
    } else |_| {
        // Missing leaves / non-existent paths — fall back to lexical.
        return gpa.dupe(u8, path);
    }
}

fn resolveRelativeVervePath(io: std.Io, gpa: std.mem.Allocator, dir_path: []const u8, verve_path: []const u8) ![]u8 {
    // Zig's build.zig.zon rejects absolute `.path` deps — they must be
    // relative to the build root. Convert the baked-in absolute verve
    // checkout path into one relative to the scaffold target.
    const cwd_abs = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd_abs);

    const lex_dir = if (std.fs.path.isAbsolute(dir_path))
        try gpa.dupe(u8, dir_path)
    else
        try std.fs.path.resolve(gpa, &.{ cwd_abs, dir_path });
    defer gpa.free(lex_dir);

    const lex_verve = if (std.fs.path.isAbsolute(verve_path))
        try gpa.dupe(u8, verve_path)
    else
        try std.fs.path.resolve(gpa, &.{ cwd_abs, verve_path });
    defer gpa.free(lex_verve);

    const abs_dir = try canonicalize(io, gpa, lex_dir);
    defer gpa.free(abs_dir);
    const abs_verve = try canonicalize(io, gpa, lex_verve);
    defer gpa.free(abs_verve);

    // Use the platform-dispatching `relative` (→ relativeWindows on Win,
    // relativePosix elsewhere): the POSIX variant tokenizes on '/' only,
    // so a Windows `C:\...` path shares no prefix with the target and
    // yields a bogus `../C:\...`. relativeWindows understands drive
    // letters + backslash separators.
    const rel = try std.fs.path.relative(gpa, cwd_abs, null, abs_dir, abs_verve);

    // build.zig.zon `.path` is a Zig string literal; backslashes are
    // escape chars (`\U`, `\c` → "invalid escape character"). Zig's build
    // system accepts '/' separators on every host, so normalize. Done
    // in place — `rel` is freshly owned.
    if (builtin.os.tag == .windows) {
        for (rel) |*c| {
            if (c.* == '\\') c.* = '/';
        }
    }
    return rel;
}

fn parseTemplate(s: []const u8) !DesktopTemplate {
    if (std.mem.eql(u8, s, "full")) return .full;
    if (std.mem.eql(u8, s, "minimal")) return .minimal;
    return error.InvalidTemplate;
}

fn scaffold(io: std.Io, dir_path: []const u8, pkg_name: []const u8, kind: Kind, template: DesktopTemplate, verve_path: []const u8) !void {
    var root = openOrCreateEmpty(io, dir_path) catch |err| switch (err) {
        error.NotEmpty => {
            log.err("target directory '{s}' is not empty — refusing to scaffold over existing files", .{dir_path});
            return err;
        },
        else => return err,
    };
    defer root.close(io);

    switch (kind) {
        .web => for (skeleton.entries) |entry| {
            if (std.mem.eql(u8, entry.path, "build.zig.zon")) continue;
            try writeFileWithParents(io, root, entry.path, entry.bytes);
        },
        .desktop => switch (template) {
            .full => for (skeleton_desktop.entries) |entry| {
                if (std.mem.eql(u8, entry.path, "build.zig.zon")) continue;
                try writeFileWithParents(io, root, entry.path, entry.bytes);
            },
            .minimal => for (skeleton_desktop_minimal.entries) |entry| {
                if (std.mem.eql(u8, entry.path, "build.zig.zon")) continue;
                try writeFileWithParents(io, root, entry.path, entry.bytes);
            },
        },
    }

    const gpa = std.heap.page_allocator;
    const rel_verve = if (kind == .desktop)
        try resolveRelativeVervePath(io, gpa, dir_path, verve_path)
    else
        try gpa.dupe(u8, "");
    defer gpa.free(rel_verve);

    const zon = try renderZon(pkg_name, gpa, kind, rel_verve);
    defer gpa.free(zon);
    try writeFileWithParents(io, root, "build.zig.zon", zon);
}

fn openOrCreateEmpty(io: std.Io, dir_path: []const u8) !std.Io.Dir {
    const cwd = std.Io.Dir.cwd();

    // Try to open existing dir; if missing, create.
    var dir = cwd.openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            try cwd.createDirPath(io, dir_path);
            return cwd.openDir(io, dir_path, .{ .iterate = true });
        },
        else => return err,
    };

    // Refuse if non-empty.
    var it = dir.iterate();
    if (try it.next(io)) |_| {
        dir.close(io);
        return error.NotEmpty;
    }
    return dir;
}

fn writeFileWithParents(io: std.Io, root: std.Io.Dir, rel: []const u8, bytes: []const u8) !void {
    if (std.mem.lastIndexOfScalar(u8, rel, '/')) |slash| {
        const parent = rel[0..slash];
        try root.createDirPath(io, parent);
    }
    var file = try root.createFile(io, rel, .{});
    defer file.close(io);
    try file.writePositionalAll(io, bytes, 0);
}

fn renderZon(pkg_name: []const u8, gpa: std.mem.Allocator, kind: Kind, verve_path: []const u8) ![]u8 {
    return renderZonFull(pkg_name, 0, gpa, kind, verve_path, null);
}

fn renderZonWithFingerprint(pkg_name: []const u8, fingerprint: u64, gpa: std.mem.Allocator, kind: Kind, verve_path: []const u8) ![]u8 {
    return renderZonFull(pkg_name, fingerprint, gpa, kind, verve_path, null);
}

/// Render the scaffolded `build.zig.zon`. When `release` is non-null
/// on a desktop scaffold, emits `.verve = .{ .url = ..., .hash = ... }`
/// pointing at the tagged GitHub archive instead of the path-dep
/// form. When the user supplied `--release` without a hash, the hash
/// field carries a sentinel + a comment with the exact `zig fetch`
/// command to fill it in.
fn renderZonFull(
    pkg_name: []const u8,
    fingerprint: u64,
    gpa: std.mem.Allocator,
    kind: Kind,
    verve_path: []const u8,
    release: ?ReleaseSpec,
) ![]u8 {
    return switch (kind) {
        .web => std.fmt.allocPrint(gpa,
            \\.{{
            \\    .name = .{s},
            \\    .version = "0.0.0",
            \\    .fingerprint = 0x{x:0>16},
            \\    .minimum_zig_version = "0.16.0",
            \\    .dependencies = .{{}},
            \\    .paths = .{{
            \\        "build.zig",
            \\        "build.zig.zon",
            \\        "src",
            \\        "tests",
            \\        "tools",
            \\        "LICENSE",
            \\    }},
            \\}}
            \\
        , .{ pkg_name, fingerprint }),
        .desktop => if (release) |r| try renderDesktopReleaseZon(gpa, pkg_name, fingerprint, r) else std.fmt.allocPrint(gpa,
            \\.{{
            \\    .name = .{s},
            \\    .version = "0.0.0",
            \\    .fingerprint = 0x{x:0>16},
            \\    .minimum_zig_version = "0.16.0",
            \\    .dependencies = .{{
            \\        // Path dep baked from `verve-cli`'s build-time
            \\        // default. Override per-scaffold with
            \\        //     verve-cli new ... --verve-path /abs/path
            \\        //
            \\        // To swap to a tagged release, re-scaffold with
            \\        //     verve-cli new ... --desktop --release vX.Y.Z [--release-hash <h>]
            \\        // or run, in this project root,
            \\        //     zig fetch --save https://github.com/sirhco/verve/archive/refs/tags/vX.Y.Z.tar.gz
            \\        // which will rewrite this dep as
            \\        //     .verve = .{{ .url = "...", .hash = "..." }},
            \\        .verve = .{{ .path = "{s}" }},
            \\    }},
            \\    .paths = .{{
            \\        "build.zig",
            \\        "build.zig.zon",
            \\        "src",
            \\        "frontend",
            \\        "public",
            \\        "tools",
            \\        "LICENSE",
            \\    }},
            \\}}
            \\
        , .{ pkg_name, fingerprint, verve_path }),
    };
}

fn renderDesktopReleaseZon(
    gpa: std.mem.Allocator,
    pkg_name: []const u8,
    fingerprint: u64,
    release: ReleaseSpec,
) ![]u8 {
    const url = try std.fmt.allocPrint(
        gpa,
        "https://github.com/{s}/{s}/archive/refs/tags/{s}.tar.gz",
        .{ RELEASE_REPO_OWNER, RELEASE_REPO_NAME, release.tag },
    );
    defer gpa.free(url);

    if (release.hash) |hash| {
        return std.fmt.allocPrint(gpa,
            \\.{{
            \\    .name = .{s},
            \\    .version = "0.0.0",
            \\    .fingerprint = 0x{x:0>16},
            \\    .minimum_zig_version = "0.16.0",
            \\    .dependencies = .{{
            \\        // Tagged release dep emitted by
            \\        // `verve-cli new --desktop --release {s}`.
            \\        .verve = .{{
            \\            .url = "{s}",
            \\            .hash = "{s}",
            \\        }},
            \\    }},
            \\    .paths = .{{
            \\        "build.zig",
            \\        "build.zig.zon",
            \\        "src",
            \\        "frontend",
            \\        "public",
            \\        "tools",
            \\        "LICENSE",
            \\    }},
            \\}}
            \\
        , .{ pkg_name, fingerprint, release.tag, url, hash });
    }
    // No hash given — emit the URL with a placeholder + clear comment.
    // The first `zig build` will fail with Zig's hash-mismatch error
    // showing the real value; rerun `zig fetch --save <url>` to
    // overwrite the placeholder atomically.
    return std.fmt.allocPrint(gpa,
        \\.{{
        \\    .name = .{s},
        \\    .version = "0.0.0",
        \\    .fingerprint = 0x{x:0>16},
        \\    .minimum_zig_version = "0.16.0",
        \\    .dependencies = .{{
        \\        // Tagged release dep emitted by
        \\        // `verve-cli new --desktop --release {s}`. The hash
        \\        // below is a placeholder — run once to fill it in:
        \\        //     zig fetch --save {s}
        \\        // Or pass `--release-hash <h>` to verve-cli next time.
        \\        .verve = .{{
        \\            .url = "{s}",
        \\            .hash = "{s}",
        \\        }},
        \\    }},
        \\    .paths = .{{
        \\        "build.zig",
        \\        "build.zig.zon",
        \\        "src",
        \\        "frontend",
        \\        "public",
        \\        "tools",
        \\        "LICENSE",
        \\    }},
        \\}}
        \\
    , .{ pkg_name, fingerprint, release.tag, url, url, RELEASE_HASH_PLACEHOLDER });
}

fn basename(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and (path[end - 1] == '/' or path[end - 1] == '\\')) end -= 1;
    var start = end;
    while (start > 0 and path[start - 1] != '/' and path[start - 1] != '\\') start -= 1;
    return path[start..end];
}

fn isValidIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    const first = name[0];
    if (!(std.ascii.isAlphabetic(first) or first == '_')) return false;
    for (name[1..]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    }
    return true;
}

/// Convert a directory basename into a valid Zig identifier when
/// possible. `-` and `.` collapse to `_`; any other non-identifier
/// byte is also replaced with `_`. A leading digit gets a single
/// underscore prefix. Returns `error.Unsalvageable` when the input
/// contains no identifier-eligible byte at all (e.g. empty, all
/// `/`s) — caller surfaces a hint to pass `--name` explicitly.
fn sanitizeIdentifier(gpa: std.mem.Allocator, raw: []const u8) error{ OutOfMemory, Unsalvageable }![]u8 {
    if (raw.len == 0) return error.Unsalvageable;

    const needs_prefix = std.ascii.isDigit(raw[0]);
    var buf = try gpa.alloc(u8, raw.len + @as(usize, if (needs_prefix) 1 else 0));
    errdefer gpa.free(buf);
    var idx: usize = 0;
    if (needs_prefix) {
        buf[0] = '_';
        idx = 1;
    }
    for (raw) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_') {
            buf[idx] = c;
        } else {
            buf[idx] = '_';
        }
        idx += 1;
    }
    if (!isValidIdentifier(buf[0..idx])) return error.Unsalvageable;
    return buf[0..idx];
}

fn printUsage(program: []const u8) void {
    std.debug.print(
        \\Usage: {s} new <target-dir> [--name <pkg-name>] [--web | --desktop]
        \\
        \\Creates a new Verve project at <target-dir>. The directory must
        \\not exist or must be empty.
        \\
        \\Modes:
        \\  --web      (default) Full-stack HTTP server with WASM client.
        \\  --desktop  Native desktop app embedding the OS standard webview
        \\             (WKWebView on macOS, WebView2 on Windows, WebKitGTK
        \\             on Linux). Includes a vendored platform layer and a
        \\             sample IPC bridge.
        \\
        \\Options:
        \\  --name NAME           Package name (Zig identifier). Defaults to the
        \\                        basename of the target directory.
        \\  --verve-path PATH     Absolute path to the Verve checkout used as the
        \\                        `.verve` dependency in generated build.zig.zon
        \\                        (desktop scaffolds only). Defaults to the build
        \\                        root baked into this CLI binary.
        \\  --release TAG         Emit a `.url + .hash` GitHub-archive dep in the
        \\                        scaffolded `build.zig.zon` (desktop only) instead
        \\                        of the default local path-dep. TAG is the Verve
        \\                        release tag (e.g. v0.1.0).
        \\  --release-hash HASH   Multihash for the release tarball. When omitted,
        \\                        the zon ships with a placeholder + instructions
        \\                        to run `zig fetch --save <url>` to fill it in.
        \\  --template NAME       Desktop scaffold variant (desktop only):
        \\                          full     (default) demo-rich app: cookies,
        \\                                   multi-window, WASM hydration, tray,
        \\                                   notifications, deep links, print,
        \\                                   smoke harness.
        \\                          minimal  single-window app, one IPC route,
        \\                                   static HTML page. Clean starting
        \\                                   point.
        \\  -h, --help            Show this message and exit.
        \\
        \\Examples:
        \\  {s} new ~/code/my-app
        \\  {s} new ~/code/my-desktop-app --desktop
        \\  {s} new ~/code/my-min-app --desktop --template minimal
        \\  {s} new ~/code/my-pinned-app --desktop --release v0.1.0
        \\
    , .{ program, program, program, program, program });
}
