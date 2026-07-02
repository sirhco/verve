//! Build-time viz graph packer.
//!
//! Generates the deterministic ~1500-node jittered-grid graph (via
//! `src/app/viz_data.buildGraph`) and packs it into the frozen canvas_buf
//! binary layout (via `canvas_buf.packGraph`). The output is served at
//! `/viz/graph.bin` and fetched by the VizGraphCanvas island chunk (slice VF2)
//! so the graph is provably server-authored rather than chunk-synthesised.
//!
//! argv shape: <out.bin>. Build.zig wires this via addRunArtifact +
//! addOutputFileArg, then embeds the result in viz_assets.zig.
const std = @import("std");
const canvas_buf = @import("canvas_buf");
const viz_data = @import("viz_data");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.log.err("viz_graph_gen: usage: viz_graph_gen <out.bin>", .{});
        return error.MissingArgs;
    }
    const out_path = args[1];
    const alloc = init.gpa;

    // Generate server-side deterministic graph.
    const graph = try viz_data.buildGraph(alloc);
    defer graph.deinit(alloc);

    // Pack into canvas_buf binary (48-byte header + node xy pairs + edge pairs).
    const bytes = try canvas_buf.packGraph(alloc, graph.xs, graph.ys, graph.ef, graph.et);
    defer alloc.free(bytes);

    // Write to the build output file.
    const cwd = std.Io.Dir.cwd();
    var out_file = cwd.createFile(io, out_path, .{}) catch |err| {
        std.log.err("viz_graph_gen: {s}: cannot create: {s}", .{ out_path, @errorName(err) });
        return err;
    };
    defer out_file.close(io);
    try out_file.writePositionalAll(io, bytes, 0);

    std.log.info("viz_graph_gen: wrote {d} bytes ({d} nodes, {d} edges) → {s}", .{
        bytes.len,
        graph.xs.len,
        graph.ef.len,
        out_path,
    });
}
