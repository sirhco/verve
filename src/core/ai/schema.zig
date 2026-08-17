//! Comptime Zig type -> JSON Schema. Emits compact JSON (no whitespace) so
//! the output is byte-stable and can be frozen by golden tests.

const std = @import("std");
const tool = @import("tool.zig");

/// Emit a JSON Schema object for `T`, an action's argument struct.
///
/// Must be called in a comptime context; the result is a comptime string with
/// no runtime cost. Unrepresentable types are a `@compileError` naming the
/// offending field — a tool schema that silently omitted a parameter would
/// hand the model a lie.
pub fn jsonSchema(comptime T: type, comptime docs: []const tool.ArgDoc) []const u8 {
    return jsonSchemaPath(T, docs, "");
}

// Path-carrying implementation behind the public `jsonSchema`. `path` is a
// dotted/bracketed breadcrumb ("nested.inner", "tags[]") built up as the
// walk descends into nested structs and slice item types, so a
// `@compileError` deep in the recursion can still name the field that
// caused it rather than just the leaf Zig type.
fn jsonSchemaPath(comptime T: type, comptime docs: []const tool.ArgDoc, comptime path: []const u8) []const u8 {
    comptime {
        const info = @typeInfo(T);
        if (info != .@"struct") @compileError("tool argument must be a struct, got " ++ @typeName(T));
        const fields = info.@"struct".fields;

        var props: []const u8 = "";
        var required: []const u8 = "";
        for (fields) |f| {
            if (props.len != 0) props = props ++ ",";
            const field_path = if (path.len == 0) f.name else path ++ "." ++ f.name;
            props = props ++ "\"" ++ escape(f.name) ++ "\":" ++ typeSchema(f.type, docFor(docs, f.name), field_path);

            // Optionals and defaulted fields are legitimately omittable; every
            // other field must be supplied or the call is malformed.
            const omittable = f.default_value_ptr != null or @typeInfo(f.type) == .optional;
            if (!omittable) {
                if (required.len != 0) required = required ++ ",";
                required = required ++ "\"" ++ escape(f.name) ++ "\"";
            }
        }
        return "{\"type\":\"object\",\"properties\":{" ++ props ++
            "},\"required\":[" ++ required ++ "],\"additionalProperties\":false}";
    }
}

fn docFor(comptime docs: []const tool.ArgDoc, comptime name: []const u8) ?[]const u8 {
    comptime {
        for (docs) |d| {
            if (std.mem.eql(u8, d.field, name)) return d.description;
        }
        return null;
    }
}

fn typeSchema(comptime T: type, comptime desc: ?[]const u8, comptime path: []const u8) []const u8 {
    comptime {
        const tail = if (desc) |d| ",\"description\":\"" ++ escape(d) ++ "\"" else "";
        return switch (@typeInfo(T)) {
            .bool => "{\"type\":\"boolean\"" ++ tail ++ "}",
            // Bounds from the declared width, so a model learns that a `u8`
            // field cannot be 300 rather than discovering it from a rejected
            // call. Comptime-evaluated, so this costs nothing at runtime.
            // `tail` (the optional description) stays last, matching every
            // other arm.
            .int => "{\"type\":\"integer\",\"minimum\":" ++ std.fmt.comptimePrint("{d}", .{std.math.minInt(T)}) ++
                ",\"maximum\":" ++ std.fmt.comptimePrint("{d}", .{std.math.maxInt(T)}) ++ tail ++ "}",
            .float => "{\"type\":\"number\"" ++ tail ++ "}",
            // An optional is the same shape as its child; omittability is
            // expressed by leaving the field out of `required`, not here.
            .optional => |o| typeSchema(o.child, desc, path),
            .@"enum" => |e| blk: {
                var vals: []const u8 = "";
                for (e.fields) |ef| {
                    if (vals.len != 0) vals = vals ++ ",";
                    vals = vals ++ "\"" ++ escape(ef.name) ++ "\"";
                }
                break :blk "{\"type\":\"string\",\"enum\":[" ++ vals ++ "]" ++ tail ++ "}";
            },
            .pointer => |p| blk: {
                if (p.size != .slice) @compileError("unsupported type for field '" ++ path ++ "': " ++ @typeName(T));
                if (p.child == u8) break :blk "{\"type\":\"string\"" ++ tail ++ "}";
                break :blk "{\"type\":\"array\",\"items\":" ++ typeSchema(p.child, null, path ++ "[]") ++ tail ++ "}";
            },
            .@"struct" => jsonSchemaPath(T, &.{}, path),
            else => @compileError("unsupported type for field '" ++ path ++ "': " ++ @typeName(T)),
        };
    }
}

/// Public alias so callers outside this file (the registry, for tool
/// descriptions) can reuse the same escaping without duplicating it.
pub const escapeJson = escape;

/// Minimal JSON string escaping for comptime literals. Descriptions are
/// author-written source text, so only the structural characters can appear.
fn escape(comptime s: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (s) |c| {
            out = out ++ switch (c) {
                '"' => "\\\"",
                '\\' => "\\\\",
                '\n' => "\\n",
                '\r' => "\\r",
                '\t' => "\\t",
                else => &[_]u8{c},
            };
        }
        return out;
    }
}

// ---- tests ------------------------------------------------------------

test "schema: flat struct with string and int" {
    const Args = struct { text: []const u8, count: i32 };
    const got = comptime jsonSchema(Args, &.{});
    try std.testing.expectEqualStrings(
        \\{"type":"object","properties":{"text":{"type":"string"},"count":{"type":"integer","minimum":-2147483648,"maximum":2147483647}},"required":["text","count"],"additionalProperties":false}
    , got);
}

test "schema: integer bounds come from the Zig bit width" {
    // Without bounds a model only learns "integer" and discovers the real
    // range by having its call rejected. The declared width already carries
    // that information, so emit it.
    const Args = struct { small: u8, signed: i8 };
    const got = comptime jsonSchema(Args, &.{});
    try std.testing.expectEqualStrings(
        \\{"type":"object","properties":{"small":{"type":"integer","minimum":0,"maximum":255},"signed":{"type":"integer","minimum":-128,"maximum":127}},"required":["small","signed"],"additionalProperties":false}
    , got);
}

test "schema: usize emits its full 64-bit range" {
    // `src/app/ai.zig`'s `removeTodo` takes `index: usize`, so this is the
    // shape a real app ships. The bound is honest but enormous, and some
    // models handle a 20-digit literal poorly — pinned here so that narrowing
    // `usize` (to `u32`, or by clamping the emitted maximum) is a deliberate
    // decision with a failing test attached, not a silent drift.
    const Args = struct { index: usize };
    const got = comptime jsonSchema(Args, &.{});
    try std.testing.expectEqualStrings(
        \\{"type":"object","properties":{"index":{"type":"integer","minimum":0,"maximum":18446744073709551615}},"required":["index"],"additionalProperties":false}
    , got);
}

test "schema: an integer field's description still comes last" {
    // `tail` carries the optional description and must stay after the bounds,
    // matching every other type arm. Nothing else pins this ordering.
    const Args = struct { n: u8 };
    const got = comptime jsonSchema(Args, &.{.{ .field = "n", .description = "how many" }});
    try std.testing.expectEqualStrings(
        \\{"type":"object","properties":{"n":{"type":"integer","minimum":0,"maximum":255,"description":"how many"}},"required":["n"],"additionalProperties":false}
    , got);
}

test "schema: empty struct" {
    const got = comptime jsonSchema(struct {}, &.{});
    try std.testing.expectEqualStrings(
        \\{"type":"object","properties":{},"required":[],"additionalProperties":false}
    , got);
}

test "schema: default and optional fields are not required" {
    const Args = struct { a: []const u8, b: u8 = 3, c: ?[]const u8 = null };
    const got = comptime jsonSchema(Args, &.{});
    try std.testing.expectEqualStrings(
        \\{"type":"object","properties":{"a":{"type":"string"},"b":{"type":"integer","minimum":0,"maximum":255},"c":{"type":"string"}},"required":["a"],"additionalProperties":false}
    , got);
}

test "schema: bool, float, enum, slice" {
    const Mode = enum { fast, slow };
    const Args = struct { on: bool, ratio: f64, mode: Mode, tags: []const []const u8 };
    const got = comptime jsonSchema(Args, &.{});
    try std.testing.expectEqualStrings(
        \\{"type":"object","properties":{"on":{"type":"boolean"},"ratio":{"type":"number"},"mode":{"type":"string","enum":["fast","slow"]},"tags":{"type":"array","items":{"type":"string"}}},"required":["on","ratio","mode","tags"],"additionalProperties":false}
    , got);
}

test "schema: arg_docs attach descriptions" {
    const Args = struct { text: []const u8 };
    const got = comptime jsonSchema(Args, &.{
        .{ .field = "text", .description = "Item text." },
    });
    try std.testing.expectEqualStrings(
        \\{"type":"object","properties":{"text":{"type":"string","description":"Item text."}},"required":["text"],"additionalProperties":false}
    , got);
}

test "schema: field names and enum values are JSON-escaped, not interpolated raw" {
    // Comptime and author-controlled, so this is theoretical for a normal
    // app — but the escaper already exists for descriptions, and a struct
    // field or enum tag declared via `@"..."` syntax can contain a quote or
    // backslash that would otherwise produce structurally invalid JSON.
    const Weird = enum { @"a\"b", plain };
    const Args = struct { @"say\"hi\"": []const u8, mode: Weird };
    const got = comptime jsonSchema(Args, &.{});
    try std.testing.expectEqualStrings(
        \\{"type":"object","properties":{"say\"hi\"":{"type":"string"},"mode":{"type":"string","enum":["a\"b","plain"]}},"required":["say\"hi\"","mode"],"additionalProperties":false}
    , got);
}

test "schema: descriptions are JSON-escaped" {
    const Args = struct { text: []const u8 };
    const got = comptime jsonSchema(Args, &.{
        .{ .field = "text", .description = "Say \"hi\"" },
    });
    try std.testing.expectEqualStrings(
        \\{"type":"object","properties":{"text":{"type":"string","description":"Say \"hi\""}},"required":["text"],"additionalProperties":false}
    , got);
}
