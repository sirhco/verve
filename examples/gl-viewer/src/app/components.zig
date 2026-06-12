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
