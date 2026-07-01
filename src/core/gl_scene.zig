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
const gl = @import("gl/gl.zig");

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
    scrub: bool, // scroll-scrub mode (Task 9); when true auto_rotate is forced 0
    pick_export_names: []const []const u8, // parallel DOM-event names ("" = none) — P8 onPickExport
    // NOTE: fog is deliberately NOT a Props field. Fog travels instead as a
    // `data-glfog` attribute on the canvas, read in the chunk via `refGetAttr`
    // (see build() and GlScene.zig hydrate). This was originally adopted on the
    // belief that growing Props tripped a wasm `decodeProps` miscompile — but
    // the blank GlScene pages were ultimately traced to the chunk-data memory
    // window (build.zig main-client stack_size), NOT decodeProps. The
    // data-glfog transport is kept (it works and is shipped); the assert below
    // is a conservative guard that the codec round-trips this exact shape.
    // If you ever revisit moving fog into Props, re-verify hydration on a real
    // GlScene page first.
};

comptime {
    // Conservative guard: the SSR codec and the chunk-side Props mirror must
    // agree on this exact 14-field shape (see the NOTE above).
    std.debug.assert(@typeInfo(Props).@"struct".fields.len == 14);
}

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

pub const FogMode = enum(u32) { none = 0, linear = 1, exp = 2, exp2 = 3 };
pub const FogOpts = struct {
    mode: FogMode = .none,
    color: [3]f32 = .{ 0.5, 0.6, 0.7 },
    near: f32 = 1,
    far: f32 = 50,
    density: f32 = 0.05,
};

/// Camera projection mode. `perspective` is the default (attribute omitted).
/// `orthographic` switches to an ortho matrix driven by `ortho_height`.
pub const Projection = enum(u32) { perspective = 0, orthographic = 1 };
pub const ProjectionOpts = struct {
    mode: Projection = .perspective,
    ortho_height: f32 = 2,
    fov_deg: f32 = 57.3,
    near: f32 = 0.1,
    far: f32 = 100,
};

/// Light kind encoded in the `data-gllights` CSV (type column).
pub const LightKind = enum(u32) { directional = 0, point = 1, spot = 2 };

/// Describes one light for the `data-gllights` out-of-band attribute.
/// `casts_shadow` is serialized as field 15 (0 or 1) in the CSV so the
/// chunk knows which light is the designated shadow caster (S5).
pub const Light = struct {
    kind: LightKind = .directional,
    pos: [3]f32 = .{ 0, 0, 0 },
    dir: [3]f32 = .{ 0, -1, 0 },
    color: [3]f32 = .{ 1, 1, 1 },
    intensity: f32 = 1,
    inner_deg: f32 = 20,
    outer_deg: f32 = 30,
    range: f32 = 0, // 0 = no cutoff
    casts_shadow: bool = false,
};

/// Maximum number of lights accumulated per scene (matches shader UBO capacity).
pub const max_lights = 4;

/// Describes one rect (LTC) area light for the `data-glarealights` out-of-band
/// attribute. `ex`/`ey` are the HALF-edge vectors: the rect's four corners are
/// `pos ± ex ± ey` (CCW c0=pos+ex-ey, c1=pos-ex-ey, c2=pos-ex+ey, c3=pos+ex+ey —
/// matches the S3T1 packing). The rect normal is `normalize(cross(ex,ey))`; the
/// shadow caster (when `casts_shadow`) renders a spot-like perspective depth pass
/// from `pos` along that normal. `two_sided` lights both faces (reserved; the LTC
/// eval is single-sided by default — see S3T1 report).
pub const AreaLight = struct {
    pos: [3]f32,
    ex: [3]f32 = .{ 0.5, 0, 0 }, // half-width edge
    ey: [3]f32 = .{ 0, 0.5, 0 }, // half-height edge
    color: [3]f32 = .{ 1, 1, 1 },
    intensity: f32 = 1,
    two_sided: bool = false,
    casts_shadow: bool = false,
};

/// Max number of area lights accumulated per scene. Mirrors
/// `gl.command.max_area_lights` (the shader UBO `area_lights[16]` = 4 vec4 each).
pub const max_area_lights = 4;

/// Describes one clipping plane for the `data-glclip` out-of-band attribute.
/// `normal` is the plane normal (normalized on write); `constant` is the signed
/// distance from the origin (keep test: `dot(n, p) + constant >= 0`). Field
/// order frozen — Task D parseClipPlanes reads this exact CSV layout.
pub const ClipPlane = struct {
    normal: [3]f32 = .{ 0, 1, 0 },
    constant: f32 = 0,
};

/// Max number of clipping planes accumulated per scene (matches the WGSL
/// uniform array capacity wired in Task D).
pub const max_clip = 4;

/// Options for wireframe overlay. `color` is the line color (default white).
/// Transported outside Props via `data-glwire` (CSV "r,g,b") so Props stays
/// 14 fields. Field order frozen — Task D parseWireframe reads this exact layout.
pub const WireframeOpts = struct {
    color: [3]f32 = .{ 1, 1, 1 },
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
    scrub_on: bool = false,
    fog_opts: FogOpts = .{},
    proj_opts: ProjectionOpts = .{},
    morph_weights_buf: []const f32 = &.{},
    lights_buf: [max_lights]Light = undefined,
    light_count: usize = 0,
    area_lights_buf: [max_area_lights]AreaLight = undefined,
    area_count: usize = 0,
    clip_buf: [max_clip]ClipPlane = undefined,
    clip_count: usize = 0,
    wire_on: bool = false,
    wire_color: [3]f32 = .{ 1, 1, 1 },
    custom_on: bool = false,
    custom_id: u32 = 0,
    custom_params_buf: [16]f32 = [_]f32{0} ** 16,
    custom_param_len: usize = 0,
    pick_names_buf: [max_picks][]const u8 = undefined,
    pick_ids_buf: [max_picks]u32 = undefined,
    pick_export_buf: [max_picks][]const u8 = undefined,
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

    /// Enable scroll-scrub mode (Task 9 timeline). When true, scroll owns yaw
    /// so auto_rotate is forced to 0 at build() to avoid conflicting drives.
    pub fn scrub(self: *GlSceneBuilder, on: bool) *GlSceneBuilder {
        self.scrub_on = on;
        return self;
    }

    /// Distance fog. `mode = .none` (default) disables fog entirely.
    pub fn fog(self: *GlSceneBuilder, f: FogOpts) *GlSceneBuilder {
        self.fog_opts = f;
        return self;
    }

    /// Camera projection. Default is `.perspective`; pass `.{ .mode = .orthographic,
    /// .ortho_height = N }` to switch. Transported as `data-glcam` on the canvas.
    pub fn projection(self: *GlSceneBuilder, p: ProjectionOpts) *GlSceneBuilder {
        self.proj_opts = p;
        return self;
    }

    /// Seed morph-target weights for static or initial values.  Transported
    /// outside Props via `data-glmorph` (CSV "w0,w1,…") so Props stays 14
    /// fields.  An empty slice emits no attribute.
    pub fn morphWeights(self: *GlSceneBuilder, weights: []const f32) *GlSceneBuilder {
        self.morph_weights_buf = weights;
        return self;
    }

    /// Set all lights at once (up to `max_lights`; extra entries are dropped).
    /// Transported outside Props via `data-gllights` so Props stays 14 fields.
    pub fn lights(self: *GlSceneBuilder, ls: []const Light) *GlSceneBuilder {
        const n = @min(ls.len, max_lights);
        @memcpy(self.lights_buf[0..n], ls[0..n]);
        self.light_count = n;
        return self;
    }

    /// Append one spot light (forces `kind = .spot`). Drops when cap reached.
    pub fn spotLight(self: *GlSceneBuilder, l: Light) *GlSceneBuilder {
        if (self.light_count >= max_lights) return self;
        var sl = l;
        sl.kind = .spot;
        self.lights_buf[self.light_count] = sl;
        self.light_count += 1;
        return self;
    }

    /// Append one point light (forces `kind = .point`). Drops when cap reached.
    pub fn pointLight(self: *GlSceneBuilder, l: Light) *GlSceneBuilder {
        if (self.light_count >= max_lights) return self;
        var pl = l;
        pl.kind = .point;
        self.lights_buf[self.light_count] = pl;
        self.light_count += 1;
        return self;
    }

    /// Append one rect (LTC) area light. Drops when `max_area_lights` reached.
    /// Transported outside Props via `data-glarealights` so Props stays 14 fields.
    pub fn areaLight(self: *GlSceneBuilder, a: AreaLight) *GlSceneBuilder {
        if (self.area_count >= max_area_lights) return self;
        self.area_lights_buf[self.area_count] = a;
        self.area_count += 1;
        return self;
    }

    /// Wireframe overlay. When called, the chunk renders scene geometry as
    /// wire edges in the given color. Transported outside Props via `data-glwire`
    /// (CSV "r,g,b") so Props stays 14 fields. Not calling `.wireframe()` emits
    /// no attribute and leaves the chunk in its default filled-mesh mode.
    pub fn wireframe(self: *GlSceneBuilder, o: WireframeOpts) *GlSceneBuilder {
        self.wire_on = true;
        self.wire_color = o.color;
        return self;
    }

    /// Scene-global custom shader material. `params` = the packed initial uniform
    /// values in std140 lane order from the material's packing table (up to
    /// `param_vec4_count * 4` f32 values). Transported outside Props via
    /// `data-glmat` ("id;f0,f1,…") so Props stays 14 fields. Mutually exclusive
    /// with `.wireframe()` (wireframe is pure-replace; custom is a lit-variant) —
    /// combining both returns a poison node from `build()`.
    ///
    /// v1 exclusions (builder does not structurally check these; the demo avoids
    /// them): custom × instanced, custom × double_sided, custom × morph all
    /// produce invalid shader variants per the material injection spec (1B).
    pub fn material(self: *GlSceneBuilder, desc: gl.MaterialDesc, params: []const f32) *GlSceneBuilder {
        self.custom_on = true;
        self.custom_id = desc.id;
        const n = @min(params.len, self.custom_params_buf.len);
        var i: usize = 0;
        while (i < n) : (i += 1) self.custom_params_buf[i] = params[i];
        self.custom_param_len = n;
        return self;
    }

    /// Set clipping planes (up to `max_clip`; extra entries are dropped).
    /// Each plane's normal is normalized at `build()` time via `normalize3`.
    /// Transported outside Props via `data-glclip` so Props stays 14 fields.
    /// No attribute is emitted when the slice is empty.
    pub fn clipPlanes(self: *GlSceneBuilder, ps: []const ClipPlane) *GlSceneBuilder {
        const n = @min(ps.len, max_clip);
        @memcpy(self.clip_buf[0..n], ps[0..n]);
        self.clip_count = n;
        return self;
    }

    /// Register a pickable mesh by name → closure event id. Repeatable up to
    /// `max_picks`; extra registrations past the cap are dropped.
    pub fn onPick(self: *GlSceneBuilder, name: []const u8, event_id: u32) *GlSceneBuilder {
        if (self.pick_count >= max_picks) return self;
        self.pick_names_buf[self.pick_count] = name;
        self.pick_ids_buf[self.pick_count] = event_id;
        self.pick_export_buf[self.pick_count] = ""; // no DOM event on this slot
        self.pick_count += 1;
        return self;
    }

    /// Register a pickable mesh by name → DOM CustomEvent name. On a pick hit
    /// the GlScene chunk dispatches `CustomEvent(event_name, {detail:{name}})`
    /// (bubbling) from the canvas. Shares the `max_picks` budget with `onPick`;
    /// extra registrations past the cap are dropped.
    pub fn onPickExport(self: *GlSceneBuilder, name: []const u8, event_name: []const u8) *GlSceneBuilder {
        if (self.pick_count >= max_picks) return self;
        self.pick_names_buf[self.pick_count] = name;
        self.pick_ids_buf[self.pick_count] = 0; // no closure id on an export slot
        self.pick_export_buf[self.pick_count] = event_name;
        self.pick_count += 1;
        return self;
    }

    /// Finalize: encode props, build the SSR DOM (wrapper > canvas [+ poster]),
    /// and wrap it in the GlScene island marker.
    ///
    /// Scrub mode layout (when `.scrub(true)`):
    ///   island > section[data-ref=glscene-scroll-section, height:300vh, position:relative]
    ///     > div[sticky top:0, height:100vh, display:flex, align-items:center]
    ///       > div[aspect-ratio:8/5, width:100%, max-width:640px, margin:0 auto]
    ///         > canvas + optional poster
    ///
    /// The section MUST live inside the island so that `queryRef` (which
    /// appends the vid suffix) can resolve "glscene-scroll-section" to
    /// "glscene-scroll-section__v{vid}". A section outside the island would
    /// not be rewritten by `rewriteBindings` and queryRef would never find it.
    ///
    /// Non-scrub layout (when `.scrub(false)` / default):
    ///   island > div[position:relative, width:100%, height:100%]
    ///     > canvas + optional poster
    /// The embedding page must supply a definite sized container.
    pub fn build(self: *GlSceneBuilder) *Node {
        const dir = normalize3(self.lgt.dir);
        // scrub=true means scroll owns yaw; auto_rotate would conflict — zero it.
        const effective_rotate: f32 = if (self.scrub_on) 0 else self.auto_rotate_rad;
        const props = encodeProps(self.ctx, Props{
            .src = self.opts.src,
            .env = self.opts.env,
            .orbit_distance = self.cam.distance,
            .orbit_pitch = self.cam.pitch,
            .orbit_yaw = self.cam.yaw,
            .auto_rotate = effective_rotate,
            .light_dir_x = dir[0],
            .light_dir_y = dir[1],
            .light_dir_z = dir[2],
            .light_intensity = self.lgt.intensity,
            .pick_names = self.pick_names_buf[0..self.pick_count],
            .pick_event_ids = self.pick_ids_buf[0..self.pick_count],
            .scrub = self.scrub_on,
            .pick_export_names = self.pick_export_buf[0..self.pick_count],
        }) catch |e| {
            const poison = self.ctx.el("verve-island");
            poison.err = e;
            return poison;
        };

        // Custom×wireframe: mutually exclusive. Wireframe is a pure-replace
        // shader path; custom materials are a lit-variant injection. Combining
        // both would produce an invalid shader permutation. Guard here (at
        // build() time) so the error surfaces at the render call site like
        // other build errors.
        if (self.custom_on and self.wire_on) {
            const poison = self.ctx.el("verve-island");
            poison.err = error.CustomMaterialConflict;
            return poison;
        }

        // Fog travels OUTSIDE Props (see the Props note) as a comma-joined
        // `data-glfog` attribute the chunk reads via refGetAttr: mode,r,g,b,
        // near,far,density. Only emitted when fog is enabled.
        const fog_attr: ?[]const u8 = if (self.fog_opts.mode == .none) null else std.fmt.allocPrint(
            self.ctx.allocator,
            "{d},{d},{d},{d},{d},{d},{d}",
            .{
                @intFromEnum(self.fog_opts.mode),
                self.fog_opts.color[0],
                self.fog_opts.color[1],
                self.fog_opts.color[2],
                self.fog_opts.near,
                self.fog_opts.far,
                self.fog_opts.density,
            },
        ) catch null;

        // The canvas MUST be CSS-sized (decoupled from its width/height
        // attributes): the gl loop sets the backing-store size from
        // clientWidth×dpr each frame, and an unstyled canvas would grow its
        // own layout box from those attributes — an exponential resize
        // feedback loop (observed on Firefox: 9600 → 19200 → … px).
        const canvas = self.ctx.el("canvas")
            .attr("data-ref", "glscene-canvas")
            .attr("style", "display:block;width:100%;height:100%")
            .onPointerDown("glscene_pointerdown")
            .onPointerMove("glscene_pointermove")
            .onPointerUp("glscene_pointerup")
            .onWheel("glscene_wheel")
            .onClick("glscene_click");
        if (fog_attr) |fa| _ = canvas.attr("data-glfog", fa);

        // Camera projection travels OUTSIDE Props as `data-glcam`: mode,ortho_height,
        // fov_deg,near,far. Only emitted when projection is non-default (mode != 0).
        const cam_attr: ?[]const u8 = if (self.proj_opts.mode == .perspective) null else std.fmt.allocPrint(
            self.ctx.allocator,
            "{d},{d},{d},{d},{d}",
            .{
                @intFromEnum(self.proj_opts.mode),
                self.proj_opts.ortho_height,
                self.proj_opts.fov_deg,
                self.proj_opts.near,
                self.proj_opts.far,
            },
        ) catch null;
        if (cam_attr) |ca| _ = canvas.attr("data-glcam", ca);

        // Morph weights travel OUTSIDE Props as a comma-joined `data-glmorph`
        // attribute ("w0,w1,…") the chunk reads via refGetAttr + parseMorph.
        // Only emitted when the slice is non-empty.
        if (self.morph_weights_buf.len > 0) {
            // Build CSV into a stack buffer (64 weights × ~16 chars ≈ 1024 B).
            var mbuf: [1024]u8 = undefined;
            var pos: usize = 0;
            for (self.morph_weights_buf, 0..) |wt, wi| {
                const sep: []const u8 = if (wi != 0) "," else "";
                const chunk = std.fmt.bufPrint(mbuf[pos..], "{s}{d}", .{ sep, wt }) catch break;
                pos += chunk.len;
            }
            if (pos > 0) {
                const morph_attr = std.fmt.allocPrint(self.ctx.allocator, "{s}", .{mbuf[0..pos]}) catch null;
                if (morph_attr) |ma| _ = canvas.attr("data-glmorph", ma);
            }
        }

        // Lights travel OUTSIDE Props as a semicolon-separated list of 15-value
        // comma-separated records (type,intensity,px,py,pz,dx,dy,dz,r,g,b,
        // range,cosIn,cosOut,castsShadow). Only emitted when at least one light
        // was added. dir is normalized; inner_deg/outer_deg are converted to cos
        // of the half-angle. parseLights reads this EXACT layout — field order
        // frozen. castsShadow is 1 for the caster, 0 otherwise.
        if (self.light_count > 0) {
            const deg2rad = std.math.pi / 180.0;
            // Upper bound per light: 15 fields × 20 chars + 14 commas + 1 semi ≈ 315 B.
            // 4 lights × 315 = 1260; round up to 1400 for safety.
            var lbuf: [1400]u8 = undefined;
            var lpos: usize = 0;
            for (self.lights_buf[0..self.light_count], 0..) |lgt, li| {
                const d = normalize3(lgt.dir);
                const cos_in = @cos(lgt.inner_deg * deg2rad);
                const cos_out = @cos(lgt.outer_deg * deg2rad);
                const sep: []const u8 = if (li != 0) ";" else "";
                const lchunk = std.fmt.bufPrint(lbuf[lpos..], "{s}{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d}", .{
                    sep,
                    @intFromEnum(lgt.kind),
                    lgt.intensity,
                    lgt.pos[0],
                    lgt.pos[1],
                    lgt.pos[2],
                    d[0],
                    d[1],
                    d[2],
                    lgt.color[0],
                    lgt.color[1],
                    lgt.color[2],
                    lgt.range,
                    cos_in,
                    cos_out,
                    @as(u32, if (lgt.casts_shadow) 1 else 0),
                }) catch break;
                lpos += lchunk.len;
            }
            if (lpos > 0) {
                const lights_attr = std.fmt.allocPrint(self.ctx.allocator, "{s}", .{lbuf[0..lpos]}) catch null;
                if (lights_attr) |la| _ = canvas.attr("data-gllights", la);
            }
        }

        // Area lights travel OUTSIDE Props as a semicolon-separated list of 15-value
        // comma-separated records (px,py,pz, exx,exy,exz, eyx,eyy,eyz, r,g,b,
        // intensity, two_sided(0/1), casts_shadow(0/1)). Only emitted when at least
        // one area light was added. parseAreaLights reads this EXACT layout — field
        // order frozen. ex/ey are the HALF-edge vectors (NOT normalized; their length
        // is the rect half-size).
        if (self.area_count > 0) {
            // Upper bound per light: 15 fields × 20 chars + 14 commas + 1 semi ≈ 315 B.
            // 4 lights × 315 = 1260; round up to 1400 for safety.
            var abuf: [1400]u8 = undefined;
            var apos: usize = 0;
            for (self.area_lights_buf[0..self.area_count], 0..) |al, ai| {
                const sep: []const u8 = if (ai != 0) ";" else "";
                const achunk = std.fmt.bufPrint(abuf[apos..], "{s}{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d}", .{
                    sep,
                    al.pos[0],
                    al.pos[1],
                    al.pos[2],
                    al.ex[0],
                    al.ex[1],
                    al.ex[2],
                    al.ey[0],
                    al.ey[1],
                    al.ey[2],
                    al.color[0],
                    al.color[1],
                    al.color[2],
                    al.intensity,
                    @as(u32, if (al.two_sided) 1 else 0),
                    @as(u32, if (al.casts_shadow) 1 else 0),
                }) catch break;
                apos += achunk.len;
            }
            if (apos > 0) {
                const area_attr = std.fmt.allocPrint(self.ctx.allocator, "{s}", .{abuf[0..apos]}) catch null;
                if (area_attr) |aa| _ = canvas.attr("data-glarealights", aa);
            }
        }

        // Clipping planes travel OUTSIDE Props as a semicolon-separated list of
        // 4-value comma-separated records (nx,ny,nz,constant). Only emitted when
        // at least one plane was set. Normals are normalized on write.
        // parseClipPlanes reads this EXACT layout — field order frozen.
        if (self.clip_count > 0) {
            // Upper bound per plane: 4 fields × 20 chars + 3 commas + 1 semi ≈ 84 B.
            // 4 planes × 84 = 336; round up to 400 for safety.
            var cbuf: [400]u8 = undefined;
            var cpos: usize = 0;
            for (self.clip_buf[0..self.clip_count], 0..) |cp, ci| {
                const cn = normalize3(cp.normal);
                const sep: []const u8 = if (ci != 0) ";" else "";
                const cchunk = std.fmt.bufPrint(cbuf[cpos..], "{s}{d},{d},{d},{d}", .{
                    sep,
                    cn[0],
                    cn[1],
                    cn[2],
                    cp.constant,
                }) catch break;
                cpos += cchunk.len;
            }
            if (cpos > 0) {
                const clip_attr = std.fmt.allocPrint(self.ctx.allocator, "{s}", .{cbuf[0..cpos]}) catch null;
                if (clip_attr) |ca| _ = canvas.attr("data-glclip", ca);
            }
        }

        // Wireframe overlay travels OUTSIDE Props as `data-glwire`: r,g,b.
        // Only emitted when wireframe mode was enabled via `.wireframe(...)`.
        const wire_attr: ?[]const u8 = if (!self.wire_on) null else std.fmt.allocPrint(
            self.ctx.allocator,
            "{d},{d},{d}",
            .{
                self.wire_color[0],
                self.wire_color[1],
                self.wire_color[2],
            },
        ) catch null;
        if (wire_attr) |wa| _ = canvas.attr("data-glwire", wa);

        // Custom shader material travels OUTSIDE Props as `data-glmat`:
        // "<id>;<f0>,<f1>,…" (the material's fnv32 id, semicolon, then the
        // packed initial param floats as a comma-separated CSV). Only emitted
        // when a custom material was set via `.material(...)`. When absent the
        // chunk uses its standard PBR pipeline — non-custom SSR is byte-identical.
        if (self.custom_on) {
            // Build the float CSV into a stack buffer (16 floats × ~16 chars ≈ 256 B).
            var pbuf: [256]u8 = undefined;
            var ppos: usize = 0;
            for (self.custom_params_buf[0..self.custom_param_len], 0..) |pv, pi| {
                const sep: []const u8 = if (pi != 0) "," else "";
                const pchunk = std.fmt.bufPrint(pbuf[ppos..], "{s}{d}", .{ sep, pv }) catch break;
                ppos += pchunk.len;
            }
            const mat_attr = std.fmt.allocPrint(
                self.ctx.allocator,
                "{d};{s}",
                .{ self.custom_id, pbuf[0..ppos] },
            ) catch null;
            if (mat_attr) |ma| _ = canvas.attr("data-glmat", ma);
        }

        const inner_wrapper = self.ctx.div()
            .attr("style", "position:relative;display:block;width:100%;height:100%");
        if (self.opts.poster) |poster_url| {
            _ = inner_wrapper.children(.{
                canvas,
                self.ctx.el("img")
                    .attr("data-gl-poster", "")
                    .src(poster_url)
                    .attr("alt", "")
                    .attr("style", "position:absolute;inset:0;width:100%;height:100%;object-fit:contain;pointer-events:none"),
            });
        } else {
            _ = inner_wrapper.children(.{canvas});
        }

        if (self.scrub_on) {
            // Scrub layout: island owns the tall scroll section so that
            // `rewriteBindings` stamps the vid suffix on `data-ref=
            // "glscene-scroll-section"`, making it resolvable by queryRef.
            //
            // The canvas parent has aspect-ratio:8/5 + definite width so the
            // canvas fill (width:100%;height:100%) hits a real size — no
            // feedback loop.
            const canvas_box = self.ctx.div()
                .attr("style", "aspect-ratio:8/5;width:100%;max-width:640px;margin:0 auto;position:relative");
            _ = canvas_box.children(.{inner_wrapper});

            const sticky_div = self.ctx.div()
                .attr("style", "position:sticky;top:0;height:100vh;display:flex;align-items:center;justify-content:center");
            _ = sticky_div.children(.{canvas_box});

            const scroll_section = self.ctx.el("section")
                .attr("data-ref", "glscene-scroll-section")
                .attr("style", "height:300vh;position:relative");
            _ = scroll_section.children(.{sticky_div});

            return island(self.ctx, .{ .name = "GlScene", .props = props }, scroll_section);
        }

        // Non-scrub: plain wrapper; page supplies the sized container.
        return island(self.ctx, .{ .name = "GlScene", .props = props }, inner_wrapper);
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

test "glScene onPickExport encodes event name into pick_export_names" {
    island_mod.resetRenderVidSeq();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    const scene = ctx.glScene(.{ .src = "s", .env = "e" })
        .onPickExport("Cube", "verve:glpick")
        .build();
    const raw = try rawProps(attrVal(scene, "data-props").?, arena.allocator());
    const p = try decodeProps(Props, raw, arena.allocator());

    try testing.expectEqual(@as(usize, 1), p.pick_names.len);
    try testing.expectEqualStrings("Cube", p.pick_names[0]);
    // Export-only slot carries no closure id.
    try testing.expectEqual(@as(u32, 0), p.pick_event_ids[0]);
    try testing.expectEqual(@as(usize, 1), p.pick_export_names.len);
    try testing.expectEqualStrings("verve:glpick", p.pick_export_names[0]);
}

test "glScene onPick + onPickExport coexist, arrays stay parallel by slot" {
    island_mod.resetRenderVidSeq();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    const scene = ctx.glScene(.{ .src = "s", .env = "e" })
        .onPick("A", 7)
        .onPickExport("B", "ev")
        .build();
    const raw = try rawProps(attrVal(scene, "data-props").?, arena.allocator());
    const p = try decodeProps(Props, raw, arena.allocator());

    try testing.expectEqual(@as(usize, 2), p.pick_names.len);
    try testing.expectEqualStrings("A", p.pick_names[0]);
    try testing.expectEqualStrings("B", p.pick_names[1]);
    // Slot 0 = onPick (closure id, no export); slot 1 = onPickExport (event, no id).
    try testing.expectEqualSlices(u32, &.{ 7, 0 }, p.pick_event_ids);
    try testing.expectEqual(@as(usize, 2), p.pick_export_names.len);
    try testing.expectEqualStrings("", p.pick_export_names[0]);
    try testing.expectEqualStrings("ev", p.pick_export_names[1]);
}

test "glScene onPick + onPickExport share the max_picks cap" {
    island_mod.resetRenderVidSeq();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    var b = ctx.glScene(.{ .src = "s", .env = "e" });
    _ = b.onPick("A", 1).onPick("B", 2);
    var i: u32 = 0;
    while (i < max_picks) : (i += 1) _ = b.onPickExport("M", "ev"); // overflow the cap
    const scene = b.build();
    const raw = try rawProps(attrVal(scene, "data-props").?, arena.allocator());
    const p = try decodeProps(Props, raw, arena.allocator());
    try testing.expectEqual(@as(usize, max_picks), p.pick_names.len);
    try testing.expectEqual(@as(usize, max_picks), p.pick_export_names.len);
    try testing.expectEqual(@as(usize, max_picks), p.pick_event_ids.len);
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

test "glScene scrub defaults to false" {
    island_mod.resetRenderVidSeq();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    const scene = ctx.glScene(.{ .src = "s", .env = "e" }).build();
    const raw = try rawProps(attrVal(scene, "data-props").?, arena.allocator());
    const p = try decodeProps(Props, raw, arena.allocator());
    try testing.expectEqual(false, p.scrub);
}

test "glScene scrub(true) round-trips and forces auto_rotate to 0" {
    island_mod.resetRenderVidSeq();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    const scene = ctx.glScene(.{ .src = "s", .env = "e" })
        .autoRotate(0.2)
        .scrub(true)
        .build();
    const raw = try rawProps(attrVal(scene, "data-props").?, arena.allocator());
    const p = try decodeProps(Props, raw, arena.allocator());
    try testing.expectEqual(true, p.scrub);
    // scrub owns yaw — auto_rotate must be zeroed out
    try testing.expectEqual(@as(f32, 0), p.auto_rotate);
}

test "glScene scrub(true) emits scroll section with vid-suffixed data-ref" {
    island_mod.resetRenderVidSeq();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    const scene = ctx.glScene(.{ .src = "s", .env = "e" })
        .scrub(true)
        .build();
    const html = try renderHtml(scene, arena.allocator());

    // Section data-ref is vid-suffixed by rewriteBindings (same pattern as
    // the canvas ref). The prefix check is sufficient — vid value is sequential.
    try testing.expect(std.mem.indexOf(u8, html, "data-ref=\"glscene-scroll-section__v") != null);

    // Tall section: height:300vh
    try testing.expect(std.mem.indexOf(u8, html, "height:300vh") != null);

    // Sticky inner container.
    try testing.expect(std.mem.indexOf(u8, html, "position:sticky") != null);

    // Canvas is still present and vid-suffixed.
    try testing.expect(std.mem.indexOf(u8, html, "data-ref=\"glscene-canvas__v") != null);
}

test "glScene scrub(false) emits NO scroll section" {
    island_mod.resetRenderVidSeq();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);

    const scene = ctx.glScene(.{ .src = "s", .env = "e" }).build();
    const html = try renderHtml(scene, arena.allocator());

    try testing.expect(std.mem.indexOf(u8, html, "glscene-scroll-section") == null);
    try testing.expect(std.mem.indexOf(u8, html, "height:300vh") == null);
    try testing.expect(std.mem.indexOf(u8, html, "position:sticky") == null);
}

test "glScene .fog emits data-glfog attribute" {
    island_mod.resetRenderVidSeq();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);
    const scene = ctx.glScene(.{ .src = "s", .env = "e" })
        .fog(.{ .mode = .linear, .color = .{ 0.5, 0.6, 0.7 }, .near = 8, .far = 40 })
        .build();
    const html = try renderHtml(scene, arena.allocator());
    try testing.expect(std.mem.indexOf(u8, html, "data-glfog=\"1,0.5,0.6,0.7,8,40,") != null);
}

test "glScene fog defaults to none (no data-glfog)" {
    island_mod.resetRenderVidSeq();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);
    const scene = ctx.glScene(.{ .src = "s", .env = "e" }).build();
    const html = try renderHtml(scene, arena.allocator());
    try testing.expect(std.mem.indexOf(u8, html, "data-glfog") == null);
}

test "glScene .morphWeights emits data-glmorph attribute" {
    island_mod.resetRenderVidSeq();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);
    const scene = ctx.glScene(.{ .src = "s", .env = "e" })
        .morphWeights(&.{ 0.0, 0.5 })
        .build();
    const html = try renderHtml(scene, arena.allocator());
    try testing.expect(std.mem.indexOf(u8, html, "data-glmorph=\"0,0.5\"") != null);
}

test "glScene no .morphWeights call emits no data-glmorph" {
    island_mod.resetRenderVidSeq();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);
    const scene = ctx.glScene(.{ .src = "s", .env = "e" }).build();
    const html = try renderHtml(scene, arena.allocator());
    try testing.expect(std.mem.indexOf(u8, html, "data-glmorph") == null);
}

test "glScene .spotLight emits data-gllights" {
    island_mod.resetRenderVidSeq();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);
    const scene = ctx.glScene(.{ .src = "s", .env = "e" })
        .spotLight(.{
            .pos = .{ 0, 3, 0 },
            .dir = .{ 0, -1, 0 },
            .intensity = 5,
            .inner_deg = 15,
            .outer_deg = 25,
            .casts_shadow = true,
        })
        .build();
    const html = try renderHtml(scene, arena.allocator());
    // type=2 (spot), intensity=5, pos 0,3,0 at the start of the record.
    try testing.expect(std.mem.indexOf(u8, html, "data-gllights=\"2,5,0,3,0,") != null);
    // cos(15°) ≈ 0.9659; cos(25°) ≈ 0.9063 — check first 4 digits of each.
    try testing.expect(std.mem.indexOf(u8, html, "0.9659") != null);
    try testing.expect(std.mem.indexOf(u8, html, "0.9063") != null);
    // Field 15: castsShadow=1 (casts_shadow=true above). The record ends with
    // ...,cosOut,1" so check that ",1\"" (or ",1;") terminates the attribute.
    try testing.expect(std.mem.indexOf(u8, html, ",1\"") != null or std.mem.indexOf(u8, html, ",1;") != null);
}

test "glScene .areaLight emits data-glarealights" {
    island_mod.resetRenderVidSeq();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);
    const scene = ctx.glScene(.{ .src = "s", .env = "e" })
        .areaLight(.{
            .pos = .{ 0, 3, 0 },
            .ex = .{ 0.5, 0, 0 },
            .ey = .{ 0, 0, 0.5 },
            .color = .{ 1, 0.9, 0.8 },
            .intensity = 4,
            .casts_shadow = true,
        })
        .build();
    const html = try renderHtml(scene, arena.allocator());
    // px,py,pz = 0,3,0 then exx,exy,exz = 0.5,0,0 at the record start.
    try testing.expect(std.mem.indexOf(u8, html, "data-glarealights=\"0,3,0,0.5,0,0,") != null);
    // Last two fields: two_sided=0, casts_shadow=1 → record ends with ",0,1".
    try testing.expect(std.mem.indexOf(u8, html, ",0,1\"") != null or std.mem.indexOf(u8, html, ",0,1;") != null);
}

test "glScene no area lights emits no data-glarealights" {
    island_mod.resetRenderVidSeq();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);
    const scene = ctx.glScene(.{ .src = "s", .env = "e" }).build();
    const html = try renderHtml(scene, arena.allocator());
    try testing.expect(std.mem.indexOf(u8, html, "data-glarealights") == null);
}

test "glScene .areaLight caps at max_area_lights" {
    island_mod.resetRenderVidSeq();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);
    var b = ctx.glScene(.{ .src = "s", .env = "e" });
    var i: u32 = 0;
    while (i < max_area_lights + 3) : (i += 1) _ = b.areaLight(.{ .pos = .{ 0, 1, 0 } });
    const scene = b.build();
    const html = try renderHtml(scene, arena.allocator());
    // Slice out the data-glarealights="…" value and count semicolons:
    // max_area_lights records → max_area_lights-1 separators.
    const key = "data-glarealights=\"";
    const start = std.mem.indexOf(u8, html, key).? + key.len;
    const end = start + std.mem.indexOfScalar(u8, html[start..], '"').?;
    var semis: usize = 0;
    for (html[start..end]) |c| {
        if (c == ';') semis += 1;
    }
    try testing.expectEqual(@as(usize, max_area_lights - 1), semis);
}

test "glScene no lights emits no data-gllights" {
    island_mod.resetRenderVidSeq();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);
    const scene = ctx.glScene(.{ .src = "s", .env = "e" }).build();
    const html = try renderHtml(scene, arena.allocator());
    try testing.expect(std.mem.indexOf(u8, html, "data-gllights") == null);
}

test "glScene .projection orthographic emits data-glcam" {
    island_mod.resetRenderVidSeq();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);
    const scene = ctx.glScene(.{ .src = "s", .env = "e" })
        .projection(.{ .mode = .orthographic, .ortho_height = 5, .near = 0.2, .far = 80 })
        .build();
    const html = try renderHtml(scene, arena.allocator());
    try testing.expect(std.mem.indexOf(u8, html, "data-glcam=\"1,5,57.3,0.2,80\"") != null);
}

test "glScene perspective default emits no data-glcam" {
    island_mod.resetRenderVidSeq();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);
    const scene = ctx.glScene(.{ .src = "s", .env = "e" }).build();
    const html = try renderHtml(scene, arena.allocator());
    try testing.expect(std.mem.indexOf(u8, html, "data-glcam") == null);
}

test "glScene .clipPlanes emits data-glclip" {
    island_mod.resetRenderVidSeq();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);
    const scene = ctx.glScene(.{ .src = "s", .env = "e" })
        .clipPlanes(&.{.{ .normal = .{ 1, 0, 0 }, .constant = 0 }})
        .build();
    const html = try renderHtml(scene, arena.allocator());
    try testing.expect(std.mem.indexOf(u8, html, "data-glclip=\"1,0,0,0\"") != null);
}

test "glScene no .clipPlanes call emits no data-glclip" {
    island_mod.resetRenderVidSeq();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);
    const scene = ctx.glScene(.{ .src = "s", .env = "e" }).build();
    const html = try renderHtml(scene, arena.allocator());
    try testing.expect(std.mem.indexOf(u8, html, "data-glclip") == null);
}

test "glScene .clipPlanes normalizes non-unit normals" {
    island_mod.resetRenderVidSeq();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);
    const scene = ctx.glScene(.{ .src = "s", .env = "e" })
        .clipPlanes(&.{.{ .normal = .{ 0, 2, 0 }, .constant = -1 }})
        .build();
    const html = try renderHtml(scene, arena.allocator());
    // .{0,2,0} normalizes to .{0,1,0}; constant passes through.
    try testing.expect(std.mem.indexOf(u8, html, "data-glclip=\"0,1,0,-1\"") != null);
}

test "glScene .clipPlanes two planes emit semicolon-joined record" {
    island_mod.resetRenderVidSeq();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);
    const scene = ctx.glScene(.{ .src = "s", .env = "e" })
        .clipPlanes(&.{
            .{ .normal = .{ 0, 1, 0 }, .constant = -1 },
            .{ .normal = .{ 1, 0, 0 }, .constant = 0 },
        })
        .build();
    const html = try renderHtml(scene, arena.allocator());
    try testing.expect(std.mem.indexOf(u8, html, "data-glclip=\"0,1,0,-1;1,0,0,0\"") != null);
}

test "glScene .clipPlanes caps at max_clip" {
    island_mod.resetRenderVidSeq();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);
    var b = ctx.glScene(.{ .src = "s", .env = "e" });
    // Pass more than max_clip planes; extras must be dropped.
    _ = b.clipPlanes(&.{
        .{ .normal = .{ 1, 0, 0 }, .constant = 0 },
        .{ .normal = .{ 0, 1, 0 }, .constant = 0 },
        .{ .normal = .{ 0, 0, 1 }, .constant = 0 },
        .{ .normal = .{ 1, 0, 0 }, .constant = 1 },
        .{ .normal = .{ 0, 1, 0 }, .constant = 2 }, // 5th — beyond cap
    });
    const scene = b.build();
    const html = try renderHtml(scene, arena.allocator());
    // Exactly max_clip records → max_clip-1 semicolons.
    const key = "data-glclip=\"";
    const start = std.mem.indexOf(u8, html, key).? + key.len;
    const end = start + std.mem.indexOfScalar(u8, html[start..], '"').?;
    var semis: usize = 0;
    for (html[start..end]) |c| {
        if (c == ';') semis += 1;
    }
    try testing.expectEqual(@as(usize, max_clip - 1), semis);
}

test "glScene .wireframe emits data-glwire attribute" {
    island_mod.resetRenderVidSeq();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);
    const scene = ctx.glScene(.{ .src = "s", .env = "e" })
        .wireframe(.{ .color = .{ 1, 0, 0 } })
        .build();
    const html = try renderHtml(scene, arena.allocator());
    try testing.expect(std.mem.indexOf(u8, html, "data-glwire=\"1,0,0\"") != null);
}

test "glScene no .wireframe call emits no data-glwire" {
    island_mod.resetRenderVidSeq();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);
    const scene = ctx.glScene(.{ .src = "s", .env = "e" }).build();
    const html = try renderHtml(scene, arena.allocator());
    try testing.expect(std.mem.indexOf(u8, html, "data-glwire") == null);
}

// ── custom material tests (1D) ──────────────────────────────────────────────

test "glScene .material emits data-glmat with id prefix and param CSV" {
    island_mod.resetRenderVidSeq();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);
    var b = ctx.glScene(.{ .src = "s", .env = "e" });
    _ = b.material(gl.example_holo, &.{ 0.2, 0.6, 1.0, 0.0 });
    const scene = b.build();
    const html = try renderHtml(scene, arena.allocator());
    // Attribute value starts with "<example_holo.id>;"
    var id_buf: [64]u8 = undefined;
    const id_prefix = try std.fmt.bufPrint(&id_buf, "data-glmat=\"{d};", .{gl.example_holo.id});
    try testing.expect(std.mem.indexOf(u8, html, id_prefix) != null);
    // CSV portion contains the first param value 0.2
    try testing.expect(std.mem.indexOf(u8, html, "0.2") != null);
}

test "glScene no .material call emits no data-glmat (SSR byte-identical)" {
    island_mod.resetRenderVidSeq();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);
    const scene = ctx.glScene(.{ .src = "s", .env = "e" }).build();
    const html = try renderHtml(scene, arena.allocator());
    try testing.expect(std.mem.indexOf(u8, html, "data-glmat") == null);
}

test "glScene .material + .wireframe returns poison (custom×wireframe guard)" {
    island_mod.resetRenderVidSeq();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = Context.init(&arena);
    const scene = ctx.glScene(.{ .src = "s", .env = "e" })
        .material(gl.example_holo, &.{ 1, 0, 0 })
        .wireframe(.{ .color = .{ 1, 1, 1 } })
        .build();
    // Guard fires in build(): returns a poison node with .err set, NOT a GlScene island.
    try testing.expect(scene.err != null);
}

test "gl.example_holo resolves with non-zero id and correct flags" {
    // Purely comptime — exercises the demo_materials re-export chain through gl.zig.
    try testing.expect(gl.example_holo.id != 0);
    try testing.expectEqual(
        gl.command.variant_pbr | gl.command.variant_custom | gl.command.variant_custom_tex,
        gl.example_holo.flags,
    );
}
