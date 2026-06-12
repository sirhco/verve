//! Declarative `verve.gl` scene island — the SSR side of the GlScene island
//! (P4 Task 11). `ctx.glScene(.{...})` returns a fluent `GlSceneBuilder`;
//! chain `.camera(...)`, `.light(...)`, `.autoRotate(...)`, `.onPick(...)`,
//! then `.build()` to get the wrapped `<verve-island data-name="GlScene">`
//! `*Node`. The builder encodes a frozen `Props` blob (base64, serialize.zig)
//! into `data-props`; the GlScene client chunk (Task 12) decodes the same
//! positional struct to drive a WebGL2 scene over shared linear memory.
//!
//! Codec note: serialize.zig has no fixed-array (`[N]T`) tag, so the light
//! travel direction is encoded as three scalar fields (`light_dir_x/y/z`)
//! rather than `[3]f32`. The builder's `.light(.{ .dir = .{x,y,z} })` ergonomics
//! are unchanged; only the wire/Props layout splits the vector.

const std = @import("std");
const Context = @import("context.zig").Context;
const Node = @import("node.zig").Node;
const island = @import("island.zig").island;
const encodeProps = @import("props.zig").encodeProps;

/// Frozen props contract decoded verbatim by the GlScene client chunk
/// (positional mirror — fields are read in declaration order). `[3]f32`
/// from the design sketch is flattened to three scalars because the SSR↔
/// hydration codec (serialize.zig) supports slices but not fixed arrays.
pub const Props = struct {
    src: []const u8, // vmesh url
    env: []const u8, // venv url
    orbit_distance: f32,
    orbit_pitch: f32,
    orbit_yaw: f32,
    auto_rotate: f32, // rad/s, 0 = off
    light_dir_x: f32, // normalized travel direction (x)
    light_dir_y: f32,
    light_dir_z: f32,
    light_intensity: f32,
    pick_names: []const []const u8,
    pick_event_ids: []const u32, // parallel closure ids (0 = none)
};

/// Max number of `.onPick(...)` registrations accumulated per scene.
pub const max_picks = 4;

/// `ctx.glScene(.{...})` options. `poster` is optional — when null no
/// `<img data-gl-poster>` is emitted, and the canvas shows the wrapper
/// background until the chunk hydrates.
pub const GlSceneOpts = struct {
    src: []const u8,
    env: []const u8,
    poster: ?[]const u8 = null,
};

pub const CameraOpts = struct {
    distance: f32 = 4,
    pitch: f32 = 0.3,
    yaw: f32 = 0,
};

pub const LightOpts = struct {
    dir: [3]f32 = .{ -0.4, -0.7, -0.6 },
    intensity: f32 = 3,
};

/// Fluent builder. Returned by `ctx.glScene`; finalize with `.build()`.
/// All setters return `*GlSceneBuilder` so calls chain; `build()` returns
/// the island-wrapped `*verve.Node` (or a poison node carrying the error,
/// surfaced at the enclosing `.build()`/render).
pub const GlSceneBuilder = struct {
    ctx: *const Context,
    opts: GlSceneOpts,
    cam: CameraOpts = .{},
    lgt: LightOpts = .{},
    auto_rotate_rad: f32 = 0,
    pick_names_buf: [max_picks][]const u8 = undefined,
    pick_ids_buf: [max_picks]u32 = undefined,
    pick_count: usize = 0,

    pub fn camera(self: *GlSceneBuilder, c: CameraOpts) *GlSceneBuilder {
        self.cam = c;
        return self;
    }

    pub fn light(self: *GlSceneBuilder, l: LightOpts) *GlSceneBuilder {
        self.lgt = l;
        return self;
    }

    /// Continuous spin in rad/s; 0 disables.
    pub fn autoRotate(self: *GlSceneBuilder, rad_per_s: f32) *GlSceneBuilder {
        self.auto_rotate_rad = rad_per_s;
        return self;
    }

    /// Register a pickable mesh by name → closure event id. Repeatable up to
    /// `max_picks`; extra registrations past the cap are dropped.
    pub fn onPick(self: *GlSceneBuilder, name: []const u8, event_id: u32) *GlSceneBuilder {
        if (self.pick_count >= max_picks) return self;
        self.pick_names_buf[self.pick_count] = name;
        self.pick_ids_buf[self.pick_count] = event_id;
        self.pick_count += 1;
        return self;
    }

    /// Finalize: encode props, build the SSR DOM (wrapper > canvas [+ poster]),
    /// and wrap it in the GlScene island marker.
    pub fn build(self: *GlSceneBuilder) *Node {
        const dir = normalize3(self.lgt.dir);
        const props = encodeProps(self.ctx, Props{
            .src = self.opts.src,
            .env = self.opts.env,
            .orbit_distance = self.cam.distance,
            .orbit_pitch = self.cam.pitch,
            .orbit_yaw = self.cam.yaw,
            .auto_rotate = self.auto_rotate_rad,
            .light_dir_x = dir[0],
            .light_dir_y = dir[1],
            .light_dir_z = dir[2],
            .light_intensity = self.lgt.intensity,
            .pick_names = self.pick_names_buf[0..self.pick_count],
            .pick_event_ids = self.pick_ids_buf[0..self.pick_count],
        }) catch |e| {
            const poison = self.ctx.el("verve-island");
            poison.err = e;
            return poison;
        };

        const canvas = self.ctx.el("canvas")
            .attr("data-ref", "glscene-canvas")
            .onPointerDown("glscene_pointerdown")
            .onPointerMove("glscene_pointermove")
            .onPointerUp("glscene_pointerup")
            .onWheel("glscene_wheel")
            .onClick("glscene_click");

        const wrapper = self.ctx.div().attr("style", "position:relative");
        if (self.opts.poster) |poster_url| {
            _ = wrapper.children(.{
                canvas,
                self.ctx.el("img")
                    .attr("data-gl-poster", "")
                    .src(poster_url)
                    .attr("alt", "")
                    .attr("style", "position:absolute;inset:0;width:100%;height:100%;object-fit:contain;pointer-events:none"),
            });
        } else {
            _ = wrapper.children(.{canvas});
        }

        return island(self.ctx, .{ .name = "GlScene", .props = props }, wrapper);
    }
};

/// Normalize a 3-vector; a zero vector falls back to the default light dir
/// so the encoded direction is always usable by the chunk.
fn normalize3(v: [3]f32) [3]f32 {
    const len = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    // Fallback = default light dir (-0.4,-0.7,-0.6)/√1.01, pre-normalized so
    // the zero-vector path also yields a unit direction.
    if (len == 0) return .{ -0.39801488, -0.69652603, -0.59702231 };
    return .{ v[0] / len, v[1] / len, v[2] / len };
}

// ---- tests ------------------------------------------------------------

const testing = std.testing;
const Renderer = @import("renderer.zig").Renderer;
const decodeProps = @import("props.zig").decodeProps;
const island_mod = @import("island.zig");

fn renderHtml(node: *Node, alloc: std.mem.Allocator) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try Renderer.render(&aw.writer, node);
    return aw.written();
}

fn rawProps(b64: []const u8, alloc: std.mem.Allocator) ![]u8 {
    const dec = std.base64.standard.Decoder;
    const n = try dec.calcSizeForSlice(b64);
    const raw = try alloc.alloc(u8, n);
    try dec.decode(raw, b64);
    return raw;
}

fn attrVal(node: *Node, key: []const u8) ?[]const u8 {
    for (node.attrs.items) |a| if (std.mem.eql(u8, a.key, key)) return a.value;
    return null;
}

test "glScene emits GlScene island with non-empty data-props" {
    island_mod.resetRenderVidSeq();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    const scene = ctx.glScene(.{ .src = "/gl/demo.vmesh", .env = "/gl/studio.venv" }).build();
    const html = try renderHtml(scene, arena.allocator());

    try testing.expect(std.mem.indexOf(u8, html, "data-name=\"GlScene\"") != null);
    const props = attrVal(scene, "data-props").?;
    try testing.expect(props.len > 0);
}

test "glScene canvas carries data-ref and all five z-on handlers" {
    island_mod.resetRenderVidSeq();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    const scene = ctx.glScene(.{ .src = "a", .env = "b" }).build();
    const html = try renderHtml(scene, arena.allocator());

    // data-ref is vid-suffixed by the island wrapper (per-instance binding).
    try testing.expect(std.mem.indexOf(u8, html, "data-ref=\"glscene-canvas__v") != null);
    try testing.expect(std.mem.indexOf(u8, html, "z-on-pointerdown=\"glscene_pointerdown\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "z-on-pointermove=\"glscene_pointermove\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "z-on-pointerup=\"glscene_pointerup\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "z-on-wheel=\"glscene_wheel\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "z-on-click=\"glscene_click\"") != null);
}

test "glScene emits poster img only when poster set" {
    island_mod.resetRenderVidSeq();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    const with = ctx.glScene(.{ .src = "a", .env = "b", .poster = "/gl/poster.png" }).build();
    const with_html = try renderHtml(with, arena.allocator());
    try testing.expect(std.mem.indexOf(u8, with_html, "data-gl-poster") != null);
    try testing.expect(std.mem.indexOf(u8, with_html, "/gl/poster.png") != null);

    island_mod.resetRenderVidSeq();
    const without = ctx.glScene(.{ .src = "a", .env = "b" }).build();
    const without_html = try renderHtml(without, arena.allocator());
    try testing.expect(std.mem.indexOf(u8, without_html, "data-gl-poster") == null);
}

test "glScene defaults round-trip through decodeProps" {
    island_mod.resetRenderVidSeq();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    const scene = ctx.glScene(.{ .src = "/gl/demo.vmesh", .env = "/gl/studio.venv" }).build();
    const b64 = attrVal(scene, "data-props").?;
    const raw = try rawProps(b64, arena.allocator());
    const p = try decodeProps(Props, raw, arena.allocator());

    try testing.expectEqualStrings("/gl/demo.vmesh", p.src);
    try testing.expectEqualStrings("/gl/studio.venv", p.env);
    try testing.expectEqual(@as(f32, 4), p.orbit_distance);
    try testing.expectEqual(@as(f32, 0.3), p.orbit_pitch);
    try testing.expectEqual(@as(f32, 0), p.orbit_yaw);
    try testing.expectEqual(@as(f32, 0), p.auto_rotate);
    try testing.expectEqual(@as(f32, 3), p.light_intensity);
    try testing.expectEqual(@as(usize, 0), p.pick_names.len);
    try testing.expectEqual(@as(usize, 0), p.pick_event_ids.len);
    // Default light dir is normalized (unit length).
    const len = @sqrt(p.light_dir_x * p.light_dir_x + p.light_dir_y * p.light_dir_y + p.light_dir_z * p.light_dir_z);
    try testing.expect(@abs(len - 1.0) < 1e-5);
}

test "glScene chained setters encode camera, light, autoRotate, picks" {
    island_mod.resetRenderVidSeq();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    const scene = ctx.glScene(.{ .src = "s", .env = "e" })
        .camera(.{ .distance = 3, .pitch = 0.5, .yaw = 1.2 })
        .light(.{ .dir = .{ 0, -1, 0 }, .intensity = 2 })
        .autoRotate(0.2)
        .onPick("Cube", 11)
        .onPick("Sphere", 22)
        .build();
    const b64 = attrVal(scene, "data-props").?;
    const raw = try rawProps(b64, arena.allocator());
    const p = try decodeProps(Props, raw, arena.allocator());

    try testing.expectEqual(@as(f32, 3), p.orbit_distance);
    try testing.expectEqual(@as(f32, 0.5), p.orbit_pitch);
    try testing.expectEqual(@as(f32, 1.2), p.orbit_yaw);
    try testing.expectEqual(@as(f32, 0.2), p.auto_rotate);
    try testing.expectEqual(@as(f32, 2), p.light_intensity);
    // dir {0,-1,0} normalizes to {0,-1,0}
    try testing.expectEqual(@as(f32, 0), p.light_dir_x);
    try testing.expectEqual(@as(f32, -1), p.light_dir_y);
    try testing.expectEqual(@as(f32, 0), p.light_dir_z);
    try testing.expectEqual(@as(usize, 2), p.pick_names.len);
    try testing.expectEqualStrings("Cube", p.pick_names[0]);
    try testing.expectEqualStrings("Sphere", p.pick_names[1]);
    try testing.expectEqualSlices(u32, &.{ 11, 22 }, p.pick_event_ids);
}

test "glScene onPick caps at max_picks" {
    island_mod.resetRenderVidSeq();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    var b = ctx.glScene(.{ .src = "s", .env = "e" });
    var i: u32 = 0;
    while (i < max_picks + 3) : (i += 1) _ = b.onPick("M", i + 1);
    const scene = b.build();
    const raw = try rawProps(attrVal(scene, "data-props").?, arena.allocator());
    const p = try decodeProps(Props, raw, arena.allocator());
    try testing.expectEqual(@as(usize, max_picks), p.pick_names.len);
}
