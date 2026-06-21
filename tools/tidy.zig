//! tools/tidy.zig — Verve's consistency linter (TigerStyle-inspired).
//!
//! Dependency-free (std only). Walks the source tree and fails the build on
//! consistency regressions. Three checks:
//!
//!   1. Banned tokens (hard-fail): leftover `FIXME` / `XXX` / `dbg(` markers.
//!   2. Line length > 100 columns — ratcheted against tools/tidy_baseline.txt.
//!   3. Function length > 70 lines  — ratcheted against tools/tidy_baseline.txt.
//!
//! Ratcheted checks compare a file's current violation *count* to its baseline
//! count: only an increase fails. New code is held to the limit (absent files
//! have an implicit baseline of zero). The baseline only ever moves down on a
//! normal run; `--update` regenerates it from the current tree (the sole way
//! to absorb a deliberate new long line / function — visible in the diff).
//!
//! Usage (wired by build.zig):
//!   verve-tidy <project-root>            # check, exits 1 on regression
//!   verve-tidy <project-root> --update   # rewrite tools/tidy_baseline.txt
//!
//! Trailing-whitespace and tab checks are intentionally omitted — `zig fmt
//! --check` already covers them.

const std = @import("std");
const Io = std.Io;
const Ast = std.zig.Ast;

const max_line_columns: usize = 100;
const max_function_lines: usize = 70;

/// Directories walked for `.zig` files, relative to the project root.
const scan_dirs = [_][]const u8{ "src", "tests", "tools" };

/// This file embeds the banned needles as string literals, so it must exempt
/// itself from the banned-token scan (it is still subject to the ratcheted
/// length checks).
const self_path = "tools/tidy.zig";

const baseline_path = "tools/tidy_baseline.txt";

const Banned = struct { needle: []const u8, message: []const u8 };
const banned_tokens = [_]Banned{
    .{ .needle = "FIXME", .message = "leftover FIXME — resolve before merge" },
    .{ .needle = "XXX", .message = "leftover XXX marker — resolve before merge" },
    .{ .needle = "dbg(", .message = "leftover dbg( — remove debug call" },
};

const Counts = struct { long_lines: u32 = 0, long_fns: u32 = 0 };

/// One scanned `.zig` file's ratcheted-violation line numbers (1-based).
const FileScan = struct {
    path: []const u8,
    long_lines: []const u32,
    long_fns: []const u32,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);

    const root = if (args.len > 1) args[1] else ".";
    var update = false;
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--update")) update = true;
    }

    var root_dir = try Io.Dir.cwd().openDir(io, root, .{});
    defer root_dir.close(io);

    const baseline = try loadBaseline(gpa, io, root_dir);

    // Hard-fail errors (banned tokens + ratchet regressions), printed sorted.
    var errors: std.ArrayList([]const u8) = .empty;
    // Per-file scan results, used for the baseline and ratchet comparison.
    var scans: std.ArrayList(FileScan) = .empty;

    for (scan_dirs) |dir| {
        var d = root_dir.openDir(io, dir, .{ .iterate = true }) catch continue;
        defer d.close(io);

        var walker = try d.walk(gpa);
        defer walker.deinit();

        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

            const rel = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, entry.path });
            const forward = try gpa.dupe(u8, rel);
            for (forward) |*c| if (c.* == '\\') {
                c.* = '/';
            };

            const source = try root_dir.readFileAllocOptions(
                io,
                rel,
                gpa,
                .unlimited,
                .of(u8),
                0,
            );

            try scanFile(gpa, forward, source, &errors, &scans);
        }
    }

    if (update) {
        try writeBaseline(io, root_dir, scans.items);
        try report(io, "tidy: baseline regenerated ({d} files tracked)\n", .{countTracked(scans.items)});
        return;
    }

    // Ratchet: a file fails only when its current count exceeds the baseline.
    for (scans.items) |scan| {
        const base = baseline.get(scan.path) orelse Counts{};
        if (scan.long_lines.len > base.long_lines) {
            try errors.append(gpa, try std.fmt.allocPrint(
                gpa,
                "{s}: error: {d} lines exceed {d} columns (baseline {d}){s}",
                .{ scan.path, scan.long_lines.len, max_line_columns, base.long_lines, fmtLines(gpa, scan.long_lines) },
            ));
        }
        if (scan.long_fns.len > base.long_fns) {
            try errors.append(gpa, try std.fmt.allocPrint(
                gpa,
                "{s}: error: {d} functions exceed {d} lines (baseline {d}){s}",
                .{ scan.path, scan.long_fns.len, max_function_lines, base.long_fns, fmtLines(gpa, scan.long_fns) },
            ));
        }
    }

    if (errors.items.len == 0) {
        try report(io, "tidy: clean ({d} files scanned)\n", .{scans.items.len});
        return;
    }

    std.mem.sort([]const u8, errors.items, {}, lessThanStr);
    var buf: [4096]u8 = undefined;
    var ew = Io.File.stderr().writer(io, &buf);
    const w = &ew.interface;
    for (errors.items) |e| {
        try w.writeAll(e);
        try w.writeAll("\n");
    }
    try w.print(
        "tidy: {d} violation(s). Fix them, or run `zig build tidy-update` if a new long line/function is intentional.\n",
        .{errors.items.len},
    );
    try w.flush();
    std.process.exit(1);
}

/// Run all three checks against one file's bytes, appending banned-token
/// errors immediately and recording ratcheted counts in `scans`.
fn scanFile(
    gpa: std.mem.Allocator,
    path: []const u8,
    source: [:0]const u8,
    errors: *std.ArrayList([]const u8),
    scans: *std.ArrayList(FileScan),
) !void {
    var long_lines: std.ArrayList(u32) = .empty;
    var line_no: u32 = 0;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| {
        line_no += 1;

        // Check 2: line length. Byte length, matching TigerBeetle; Verve source
        // is ASCII today so bytes == columns.
        if (line.len > max_line_columns) try long_lines.append(gpa, line_no);

        // Check 1: banned tokens (hard-fail, self-exempt).
        if (!std.mem.eql(u8, path, self_path)) {
            for (banned_tokens) |b| {
                if (std.mem.indexOf(u8, line, b.needle) != null) {
                    try errors.append(gpa, try std.fmt.allocPrint(
                        gpa,
                        "{s}:{d}: error: {s}",
                        .{ path, line_no, b.message },
                    ));
                }
            }
        }
    }

    // Check 3: function length, via the Zig parser.
    const long_fns = try longFunctions(gpa, source);

    try scans.append(gpa, .{
        .path = path,
        .long_lines = try long_lines.toOwnedSlice(gpa),
        .long_fns = long_fns,
    });
}

/// Parse `source` and return the 1-based start line of every `fn_decl` whose
/// span exceeds `max_function_lines`.
fn longFunctions(gpa: std.mem.Allocator, source: [:0]const u8) ![]const u32 {
    var tree = try Ast.parse(gpa, source, .zig);
    defer tree.deinit(gpa);

    var hits: std.ArrayList(u32) = .empty;
    var i: usize = 0;
    while (i < tree.nodes.len) : (i += 1) {
        const node: Ast.Node.Index = @enumFromInt(i);
        if (tree.nodeTag(node) != .fn_decl) continue;

        const start_line = tree.tokenLocation(0, tree.firstToken(node)).line;
        const end_line = tree.tokenLocation(0, tree.lastToken(node)).line;
        const span = end_line - start_line + 1;
        if (span > max_function_lines) try hits.append(gpa, @intCast(start_line + 1));
    }
    return hits.toOwnedSlice(gpa);
}

/// Read tools/tidy_baseline.txt into a path → Counts map. Missing file → empty.
fn loadBaseline(gpa: std.mem.Allocator, io: Io, root_dir: Io.Dir) !std.StringHashMap(Counts) {
    var map = std.StringHashMap(Counts).init(gpa);
    const content = root_dir.readFileAllocOptions(io, baseline_path, gpa, .unlimited, .of(u8), 0) catch
        return map;

    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;

        var parts = std.mem.tokenizeScalar(u8, line, ' ');
        const path = parts.next() orelse continue;
        const ll = parts.next() orelse continue;
        const lf = parts.next() orelse continue;
        try map.put(try gpa.dupe(u8, path), .{
            .long_lines = std.fmt.parseInt(u32, ll, 10) catch continue,
            .long_fns = std.fmt.parseInt(u32, lf, 10) catch continue,
        });
    }
    return map;
}

/// Rewrite tools/tidy_baseline.txt from current scan results (sorted, only
/// files with at least one violation).
fn writeBaseline(io: Io, root_dir: Io.Dir, scans: []FileScan) !void {
    std.mem.sort(FileScan, scans, {}, lessThanScan);

    var f = try root_dir.createFile(io, baseline_path, .{});
    defer f.close(io);
    var buf: [8192]u8 = undefined;
    var fw = f.writer(io, &buf);
    const w = &fw.interface;

    try w.writeAll(
        \\# Generated by `zig build tidy-update`. Do not edit by hand.
        \\# Columns: <path> <lines_over_100> <functions_over_70>
        \\# tidy ratchets these counts: a normal run fails if any file exceeds
        \\# its recorded count. Regenerate only for deliberate, reviewed growth.
        \\
    );
    for (scans) |scan| {
        if (scan.long_lines.len == 0 and scan.long_fns.len == 0) continue;
        try w.print("{s} {d} {d}\n", .{ scan.path, scan.long_lines.len, scan.long_fns.len });
    }
    try w.flush();
}

fn countTracked(scans: []const FileScan) usize {
    var n: usize = 0;
    for (scans) |s| {
        if (s.long_lines.len != 0 or s.long_fns.len != 0) n += 1;
    }
    return n;
}

/// Render up to 10 line numbers as `: lines 12, 88, …` for an error message.
fn fmtLines(gpa: std.mem.Allocator, lines: []const u32) []const u8 {
    if (lines.len == 0) return "";
    var s: std.ArrayList(u8) = .empty;
    s.appendSlice(gpa, ": lines ") catch return "";
    const shown = @min(lines.len, 10);
    for (lines[0..shown], 0..) |ln, idx| {
        if (idx != 0) s.appendSlice(gpa, ", ") catch return "";
        s.print(gpa, "{d}", .{ln}) catch return "";
    }
    if (lines.len > shown) s.print(gpa, ", …(+{d})", .{lines.len - shown}) catch return "";
    return s.items;
}

fn report(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [512]u8 = undefined;
    var ow = Io.File.stdout().writer(io, &buf);
    const w = &ow.interface;
    try w.print(fmt, args);
    try w.flush();
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn lessThanScan(_: void, a: FileScan, b: FileScan) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}
