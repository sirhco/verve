//! `verve-cli` — scaffolds a self-contained starter project.
//!
//! Usage:
//!   verve-cli new <target-dir> [--name=<pkg-name>]
//!
//! The Verve source tree, build wiring, and tests fixture are embedded
//! into this binary at build time (see build.zig:buildCliSkeleton). The
//! `new` subcommand writes them all into the target directory and emits
//! a fresh build.zig.zon with the user's chosen package name (defaults
//! to the target directory's basename).

const std = @import("std");
const skeleton = @import("skeleton");

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

    const pkg_name = name_opt orelse basename(dir_path);
    if (!isValidIdentifier(pkg_name)) {
        log.err("invalid package name '{s}' — must be a Zig identifier (a-z A-Z 0-9 _, no leading digit)", .{pkg_name});
        return error.InvalidName;
    }

    try scaffold(io, dir_path, pkg_name);

    // Zig's package fingerprint contains a name-derived half that only the
    // compiler knows how to compute. Probe `zig build` once to learn the
    // value and patch build.zig.zon — failures here are non-fatal; the
    // user can fill in the suggested value manually.
    fixFingerprint(io, init.gpa, dir_path, pkg_name) catch |err| {
        log.warn(
            "could not auto-fill build.zig.zon fingerprint ({s}). Run `zig build` once and copy the suggested value into build.zig.zon.",
            .{@errorName(err)},
        );
    };

    log.info("scaffolded '{s}' into {s}", .{ pkg_name, dir_path });
    log.info("next:", .{});
    log.info("  cd {s}", .{dir_path});
    log.info("  zig build", .{});
    log.info("  ./zig-out/bin/verve-server", .{});
}

fn fixFingerprint(io: std.Io, gpa: std.mem.Allocator, dir_path: []const u8, pkg_name: []const u8) !void {
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

    const new_zon = try renderZonWithFingerprint(pkg_name, fp, gpa);
    defer gpa.free(new_zon);

    var file = try root.createFile(io, "build.zig.zon", .{});
    defer file.close(io);
    try file.writePositionalAll(io, new_zon, 0);
}

fn scaffold(io: std.Io, dir_path: []const u8, pkg_name: []const u8) !void {
    var root = openOrCreateEmpty(io, dir_path) catch |err| switch (err) {
        error.NotEmpty => {
            log.err("target directory '{s}' is not empty — refusing to scaffold over existing files", .{dir_path});
            return err;
        },
        else => return err,
    };
    defer root.close(io);

    for (skeleton.entries) |entry| {
        if (std.mem.eql(u8, entry.path, "build.zig.zon")) continue;
        try writeFileWithParents(io, root, entry.path, entry.bytes);
    }

    const zon = try renderZon(pkg_name, std.heap.page_allocator);
    defer std.heap.page_allocator.free(zon);
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

fn renderZon(pkg_name: []const u8, gpa: std.mem.Allocator) ![]u8 {
    return renderZonWithFingerprint(pkg_name, 0, gpa);
}

fn renderZonWithFingerprint(pkg_name: []const u8, fingerprint: u64, gpa: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(gpa,
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
        \\        "LICENSE",
        \\    }},
        \\}}
        \\
    , .{ pkg_name, fingerprint });
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

fn printUsage(program: []const u8) void {
    std.debug.print(
        \\Usage: {s} new <target-dir> [--name <pkg-name>]
        \\
        \\Creates a new Verve project at <target-dir>. The directory must
        \\not exist or must be empty. Writes a self-contained tree containing
        \\framework sources, the example app (Counter + TodoList), build
        \\wiring, and a fresh build.zig.zon.
        \\
        \\Options:
        \\  --name NAME    Package name (Zig identifier). Defaults to the
        \\                 basename of the target directory.
        \\  -h, --help     Show this message and exit.
        \\
        \\Example:
        \\  {s} new ~/code/my-app
        \\  cd ~/code/my-app
        \\  zig build && ./zig-out/bin/verve-server
        \\
    , .{ program, program });
}
