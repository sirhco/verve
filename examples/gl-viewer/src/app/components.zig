//! SSR components for the gl-viewer example. Two pages, each declaring a
//! `verve.gl` scene through the fluent `ctx.glScene(...)` builder. The poster
//! is an inline SVG data URI shown until the WebGL2 chunk hydrates.

const std = @import("std");
const verve = @import("verve");

/// Inline SVG poster swapped out the moment the chunk paints its first frame.
const POSTER = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='640' height='400' viewBox='0 0 640 400'%3E%3Crect width='640' height='400' rx='10' fill='%23121420'/%3E%3Ccircle cx='320' cy='190' r='70' fill='none' stroke='%231f6feb' stroke-width='3'/%3E%3Ctext x='320' y='320' font-family='system-ui' font-size='22' font-weight='600' fill='%238b949e' text-anchor='middle'%3Eloading 3D…%3C/text%3E%3C/svg%3E";

/// `/` — scroll-scrub product turntable. The builder owns the 300vh scroll
/// section + sticky viewport internally (scrub(true)); auto-rotate is forced
/// off so scroll alone drives yaw. `.onPick("Cube", 0)` stamps the canvas with
/// `data-gl-pick` on a hit (closure id 0 = no SSR closure, name-only pick).
pub fn viewerPage(ctx: *verve.Context) !*verve.Node {
    try ctx.setTitle("verve.gl — product viewer");

    const scene = ctx.glScene(.{
        .src = "/gl/demo.vmesh",
        .env = "/gl/studio.venv",
        .poster = POSTER,
    })
        .camera(.{ .distance = 4, .pitch = 0.3, .yaw = 0.6 })
        .light(.{ .dir = .{ -0.4, -0.7, -0.6 }, .intensity = 3.0 })
        .onPick("Cube", 0)
        .scrub(true)
        .build();

    return ctx.main_().class("page").children(.{
        ctx.h1("Scroll to spin"),
        ctx.p().text("A PBR + image-based-lit mesh, declared in Zig and rendered " ++
            "in WebGL2. Scroll scrubs a full-rotation turntable timeline; drag to " ++
            "orbit, wheel to zoom, click a mesh to pick."),
        // The island brings its own 300vh scroll section + sticky viewport.
        scene,
        ctx.p().class("hint").text("Keep scrolling — the model completes one full " ++
            "rotation over 300vh of scroll travel, then frees up for manual orbit."),
        ctx.p().children(.{
            ctx.raw("Prefer free orbiting? "),
            ctx.a("/orbit", "Try the interactive orbit view →"),
        }),
    }).build();
}

/// `/orbit` — plain interactive orbit/pick mode. scrub(false) + a gentle
/// continuous auto-rotate; the embedding page supplies the sized container.
pub fn orbitPage(ctx: *verve.Context) !*verve.Node {
    try ctx.setTitle("verve.gl — orbit view");

    const scene = ctx.glScene(.{
        .src = "/gl/demo.vmesh",
        .env = "/gl/studio.venv",
        .poster = POSTER,
    })
        .camera(.{ .distance = 4, .pitch = 0.3, .yaw = 0.6 })
        .light(.{ .dir = .{ -0.4, -0.7, -0.6 }, .intensity = 3.0 })
        .onPick("Cube", 0)
        .autoRotate(0.2)
        .scrub(false)
        .build();

    return ctx.main_().class("page").children(.{
        ctx.h1("Interactive orbit"),
        ctx.p().text("Drag to orbit · wheel to zoom · click a mesh to pick · hover " ++
            "to highlight. The scene auto-rotates until you grab it. Same Zig scene " ++
            "declaration as the home page — only scrub(false) + autoRotate(0.2) differ."),
        // Non-scrub mode needs a definite sized container around the canvas.
        ctx.div().class("stage").children(.{scene}),
        ctx.p().children(.{
            ctx.a("/", "← Back to the scroll-scrub viewer"),
        }),
    }).build();
}

/// `/wireframe` — same demo.vmesh, wireframe overlay via `.wireframe(.{.color})`.
/// No new fixture; GlScene island reused as-is.
pub fn wireframePage(ctx: *verve.Context) !*verve.Node {
    try ctx.setTitle("verve.gl — wireframe");

    const scene = ctx.glScene(.{
        .src = "/gl/demo.vmesh",
        .env = "/gl/studio.venv",
        .poster = POSTER,
    })
        .camera(.{ .distance = 4, .pitch = 0.35, .yaw = 0.5 })
        .light(.{ .dir = .{ -0.4, -0.7, -0.6 }, .intensity = 3.0 })
        .wireframe(.{ .color = .{ 0.2, 1.0, 0.5 } })
        .autoRotate(0.2)
        .build();

    return ctx.main_().class("page").children(.{
        ctx.h1("Wireframe mode"),
        ctx.p().text("The mesh triangle edges rendered as thin lines — " ++
            "no shading, no texture, just the triangle topology. " ++
            "Enable with .wireframe(.{ .color = .{ r, g, b } }) on any GlScene. " ++
            "Both WebGL2 and WebGPU backends."),
        ctx.div().class("stage").children(.{scene}),
        ctx.p().children(.{
            ctx.a("/orbit", "← Orbit view"),
            ctx.raw(" · "),
            ctx.a("/ortho", "Orthographic →"),
        }),
    }).build();
}

/// `/ortho` — demo.vmesh with orthographic (parallel) projection.
pub fn orthoPage(ctx: *verve.Context) !*verve.Node {
    try ctx.setTitle("verve.gl — orthographic");

    const scene = ctx.glScene(.{
        .src = "/gl/demo.vmesh",
        .env = "/gl/studio.venv",
        .poster = POSTER,
    })
        .camera(.{ .distance = 6, .pitch = 0.35, .yaw = 0.4 })
        .light(.{ .dir = .{ -0.4, -0.7, -0.6 }, .intensity = 3.0 })
        .projection(.{ .mode = .orthographic, .ortho_height = 3.0 })
        .autoRotate(0.15)
        .build();

    return ctx.main_().class("page").children(.{
        ctx.h1("Orthographic projection"),
        ctx.p().text("Parallel projection: all parallel lines remain parallel " ++
            "at any depth — no perspective foreshortening. Enable with " ++
            ".projection(.{ .mode = .orthographic, .ortho_height = N }) " ++
            "where N is the view half-height in world units."),
        ctx.div().class("stage").children(.{scene}),
        ctx.p().children(.{
            ctx.a("/wireframe", "← Wireframe"),
            ctx.raw(" · "),
            ctx.a("/clip", "Clip planes →"),
        }),
    }).build();
}

/// `/clip` — shadow.vmesh (cube on a floor) with a world-space clip plane.
pub fn clipPage(ctx: *verve.Context) !*verve.Node {
    try ctx.setTitle("verve.gl — clip planes");

    const scene = ctx.glScene(.{
        .src = "/gl/shadow.vmesh",
        .env = "/gl/studio.venv",
        .poster = POSTER,
    })
        .camera(.{ .distance = 9, .pitch = 0.55, .yaw = 0.7 })
        .light(.{ .dir = .{ -0.45, -0.82, -0.35 }, .intensity = 3.2 })
        .clipPlanes(&.{.{ .normal = .{ 1, 0.4, 0 }, .constant = 0 }})
        .autoRotate(0.2)
        .build();

    return ctx.main_().class("page").children(.{
        ctx.h1("Clipping planes"),
        ctx.p().text("World-space clip plane: fragments where " ++
            "dot(normal, worldPos) + constant \u{2265} 0 are kept; " ++
            "below the plane is discarded. The diagonal cut exposes " ++
            "the solid interior. Up to 4 planes via " ++
            ".clipPlanes(&.{ .{ .normal = .{nx,ny,nz}, .constant = k } })."),
        ctx.div().class("stage").children(.{scene}),
        ctx.p().children(.{
            ctx.a("/ortho", "← Orthographic"),
            ctx.raw(" · "),
            ctx.a("/shadow", "Shadows →"),
        }),
    }).build();
}

/// `/shadow` — shadow.vmesh with a directional shadow-casting light.
/// The cube casts a depth-mapped shadow onto the floor via PCF sampling.
pub fn shadowPage(ctx: *verve.Context) !*verve.Node {
    try ctx.setTitle("verve.gl — directional shadows");

    const scene = ctx.glScene(.{
        .src = "/gl/shadow.vmesh",
        .env = "/gl/studio.venv",
        .poster = POSTER,
    })
        .camera(.{ .distance = 9, .pitch = 0.55, .yaw = 0.7 })
        .light(.{ .dir = .{ -0.45, -0.82, -0.35 }, .intensity = 3.2 })
        .autoRotate(0.25)
        .build();

    return ctx.main_().class("page").children(.{
        ctx.h1("Directional shadows"),
        ctx.p().text("A cube on a floor. The directional light casts a real " ++
            "depth-mapped shadow (P9 slice 3): a depth pass renders from the " ++
            "light's POV, and the floor samples it with 3\u{00d7}3 PCF. " ++
            "Both WebGL2 and WebGPU backends."),
        ctx.div().class("stage").children(.{scene}),
        ctx.p().children(.{
            ctx.a("/clip", "← Clip planes"),
            ctx.raw(" · "),
            ctx.a("/skin", "Skeletal skinning →"),
        }),
    }).build();
}

/// `/skin` — GPU-skinned rigged bar (GlSkin island, skinbar.vmesh).
/// The GlSkin chunk fetches /gl/skinbar.vmesh and drives variant_pbr|variant_skinned.
pub fn skinPage(ctx: *verve.Context) !*verve.Node {
    try ctx.setTitle("verve.gl — skeletal skinning");

    const canvas = ctx.div().class("stage").children(.{
        ctx.el("canvas")
            .attr("data-ref", "glskin-canvas")
            .attr("width", "640")
            .attr("height", "400")
            .attr("style", "width:100%;height:100%"),
    });

    // Controls wired to the GlSkin chunk's no-arg exports via z-on-click.
    // Must live INSIDE the island subtree so events route to this chunk.
    const controls = ctx.div().class("gl-controls").children(.{
        ctx.el("button").attr("z-on-click", "glskin_clip0").text("Bend"),
        ctx.el("button").attr("z-on-click", "glskin_clip1").text("Twist"),
        ctx.el("button").attr("z-on-click", "glskin_clip2").text("Smooth"),
        ctx.el("button").attr("z-on-click", "glskin_pause").text("Pause"),
        ctx.el("button").attr("z-on-click", "glskin_play").text("Play"),
        ctx.el("button").attr("z-on-click", "glskin_loop").text("Loop"),
        ctx.el("button").attr("z-on-click", "glskin_once").text("Once"),
    });

    const inner = ctx.section().children(.{ canvas, controls });
    const demo_island = verve.island(ctx, .{ .name = "GlSkin" }, inner);

    return ctx.main_().class("page").children(.{
        ctx.h1("Skeletal skinning"),
        ctx.p().text("GPU-skinned rigged bar playing baked animation clips. " ++
            "Per-vertex joint indices + weights; bone matrices uploaded each " ++
            "frame. variant_pbr | variant_skinned shader. Switch clips with " ++
            "Bend / Twist / Smooth; Pause/Play controls playback."),
        demo_island,
        ctx.p().children(.{
            ctx.a("/shadow", "← Shadows"),
            ctx.raw(" · "),
            ctx.a("/", "Home"),
        }),
    }).build();
}

/// Rendered by the framework server for unmatched routes.
pub fn notFound(ctx: *const verve.Context, path: []const u8) !*verve.Node {
    return ctx.main_().class("page").children(.{
        ctx.h1("404 — Not Found"),
        ctx.p().children(.{
            ctx.span().text("No route for "),
            ctx.code(path),
        }),
        ctx.p().children(.{ctx.a("/", "← Home")}),
    }).build();
}

/// Rendered by the framework server for 4xx/5xx responses.
pub fn errorPage(
    ctx: *const verve.Context,
    status_code: u16,
    status_text: []const u8,
    message: []const u8,
) !*verve.Node {
    return ctx.main_().class("page").children(.{
        ctx.el("h1").textFmt("{d} — {s}", .{ status_code, status_text }),
        ctx.p().text(message),
        ctx.p().children(.{ctx.a("/", "← Home")}),
    }).build();
}

/// HTML document shell. Drains `ctx.head` into a static buffer emitted verbatim
/// inside `<head>`, then wraps the page body.
pub fn page(ctx: *const verve.Context, body: *verve.Node) !*verve.Node {
    try ctx.setTitleIfUnset("verve.gl viewer");

    var aw: std.Io.Writer.Allocating = .init(ctx.alloc());
    try ctx.head.?.render(&aw.writer);
    const head_html = aw.written();

    return ctx.el("html").children(.{
        ctx.el("head").children(.{
            ctx.raw(head_html),
            ctx.style(
                \\:root{color-scheme:dark}
                \\body{font:16px/1.55 system-ui,sans-serif;margin:0;background:#0e0e10;color:#f5f5f5}
                \\.page{max-width:42rem;margin:0 auto;padding:2.5rem 1.5rem}
                \\h1{font-size:2rem;margin:0 0 .75rem}
                \\p{color:#c9d1d9;margin:.75rem 0}
                \\.hint{color:#8b949e;font-size:.9rem}
                \\a{color:#58a6ff;text-decoration:none}
                \\a:hover{text-decoration:underline}
                \\.stage{position:relative;width:100%;aspect-ratio:8/5;max-width:640px;margin:1.5rem auto;border-radius:10px;overflow:hidden;background:#121420}
                \\canvas{display:block;width:100%;height:100%}
            ),
        }),
        ctx.el("body").children(.{body}),
    }).build();
}
