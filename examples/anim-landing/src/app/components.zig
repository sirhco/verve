//! anim-landing page: one smooth-scrolled landing page composing the
//! whole `verve.anim` plugin set the way a real product page would —
//! not a kitchen-sink demo (that's the framework's /anim route).
//!
//! Composition map:
//!   hero        SplitText chars entrance + parallax layers + lag badge
//!   features    zero-wasm class reveals + scroll-gated card stagger
//!   journey     MotionPath flight along a curve, scrubbed by scroll
//!   morph       MorphSVG star -> blob, scrubbed by scroll
//!   pinned      transform-pinned panel, scrubbed bar, points snap
//!   playground  zero-wasm Draggable with inertia + drop-zone hover
//!   gallery     FLIP island (shuffle + remove/restore)
//! The whole page rides a ScrollSmoother — render the smoothScroll()
//! RETURN VALUE, and note position:fixed/sticky are dead inside it.

const std = @import("std");
const verve = @import("verve");

const star_d: []const u8 =
    "M50,5 L61,38 L95,38 L67,58 L78,91 L50,71 L22,91 L33,58 L5,38 L39,38 Z";
const blob_d: []const u8 =
    "M10,50 A40,40 0 0 1 90,50 A40,40 0 0 1 10,50 Z";
const flight_d: []const u8 =
    "M10,90 C120,90 120,20 240,20 C360,20 360,70 470,70";

pub fn index(ctx: *const verve.Context) !*verve.Node {
    const anim = verve.anim;
    const a = ctx.alloc();

    const content = ctx.main_().class("landing").children(.{
        // ---- hero: SplitText + parallax under the smoother ---------------
        ctx.el("section").class("hero").children(.{
            ctx.div().class("hero-bg").ariaHidden(true).parallaxSpeed(0.45),
            ctx.div().class("hero-mid").ariaHidden(true).parallaxSpeed(0.75),
            ctx.h1("Motion, served.").splitText(.{ .by = .chars })
                .animate(anim.from(a, ".hero .st-char")
                .opacity(0).y(26)
                .duration(0.55).ease(.out_cubic)
                .stagger(.{ .each = 0.035 })),
            ctx.p().class("lede")
                .text("A GSAP-class animation engine in pure Zig. " ++
                    "This page is one server-rendered tree — every effect " ++
                    "below is a data attribute the bridge interprets.")
                .animate(anim.from(a, ".lede").opacity(0).y(12).duration(0.6).delay(0.5)),
            ctx.div().class("hero-badge").text("smooth-scrolled · lag 0.35").parallaxLag(0.35),
        }),

        // ---- features: reveals + gated stagger ----------------------------
        sectionTitle(ctx, "Declarative by default"),
        ctx.p().class("hint")
            .text("These cards stagger in at 80% viewport and reverse when " ++
                "you scroll back up. The heading got a zero-wasm class toggle.")
            .splitText(.{ .by = .lines })
            .animate(anim.from(a, ".st-line")
            .opacity(0).y(20)
            .duration(0.5).ease(.out_cubic)
            .stagger(.{ .each = 0.1 })
            .scrollTrigger(.{
            .start = .{ .viewport = .{ .pct = 85 } },
            .actions = .{ .on_enter = .play, .on_leave_back = .reverse },
        })),
        featureDeck(ctx),

        // ---- journey: scrubbed MotionPath ---------------------------------
        sectionTitle(ctx, "Fly the curve"),
        ctx.p().class("hint").text("Scroll drives the marker along an SVG path (smoothed scrub, tangent rotation)."),
        ctx.div().class("flight-wrap")
            .children(.{
                ctx.el("svg").attr("viewBox", "0 0 480 110").attr("width", "480").attr("height", "110").children(.{
                    ctx.el("path").attr("d", flight_d).attr("fill", "none").attr("stroke", "#2a2f3a").attr("stroke-width", "1.5").attr("stroke-dasharray", "4 4"),
                }),
                ctx.div().class("flyer").ariaHidden(true).text("➤"),
            })
            .animate(anim.to(a, ".flyer")
            .motionPath(.{ .path = flight_d, .rotate = true })
            .duration(1).ease(.linear)
            .scrollTrigger(.{
            .start = .{ .viewport = .{ .pct = 85 } },
            .end = .{ .at = .{ .trigger = .bottom, .viewport = .{ .pct = 35 } } },
            .scrub = .{ .smooth = 0.3 },
        })),

        // ---- morph: scrubbed MorphSVG -------------------------------------
        sectionTitle(ctx, "Shape-shift on scroll"),
        ctx.p().class("hint").text("MorphSVG lerps matched cubic control points — the star becomes a blob as it crosses the viewport."),
        ctx.div().class("morph-wrap")
            .children(.{
                ctx.el("svg").attr("viewBox", "0 0 100 100").attr("width", "140").attr("height", "140").children(.{
                    ctx.el("path").id("land-morph").attr("d", star_d).attr("fill", "#1f6feb"),
                }),
            })
            .animate(anim.to(a, "#land-morph")
            .morph(.{ .from = star_d, .to = blob_d })
            .duration(1).ease(.linear)
            .scrollTrigger(.{
            .start = .{ .viewport = .{ .pct = 90 } },
            .end = .{ .at = .{ .trigger = .bottom, .viewport = .{ .pct = 40 } } },
            .scrub = .{ .smooth = 0.3 },
        })),

        // ---- pinned: transform-pin + snap under the smoother --------------
        sectionTitle(ctx, "Pin + snap"),
        ctx.p().class("hint").text("The panel pins for 150vh while the bar scrubs; let go and the scroll settles on 0 / 50 / 100%. Under a smoother, pins counter-translate instead of position:fixed."),
        ctx.div().class("pin-panel")
            .children(.{
                ctx.div().class("scrub-bar").ariaHidden(true),
                ctx.p().text("Pinned while the bar scrubs (points snap: 0, ½, 1)."),
            })
            .animate(anim.to(a, ".scrub-bar")
            .scaleX(1).propFrom("scaleX", 0)
            .duration(1).ease(.linear)
            .scrollTrigger(.{
            .start = .{ .trigger = .top, .viewport = .{ .pct = 20 } },
            .end = .{ .rel_vh = 1.5 },
            .scrub = .{ .smooth = 0.3 },
            .pin = .self,
            .snap = .{ .points = &.{ 0, 0.5, 1 } },
        })),

        // ---- playground: zero-wasm Draggable + drop zones -----------------
        sectionTitle(ctx, "Drag, flick, drop"),
        ctx.p().class("hint").text("Pure data-drag — no island. Flick the chip (analytic inertia, 32px grid snap); the zones light up on hover, zero wasm involved."),
        ctx.div().class("pen").children(.{
            ctx.div().class("chip drag-chip").text("flick me")
                .draggable(anim.draggable(a, .{
                .bounds = .{ .selector = ".pen" },
                .inertia = .on,
                .snap = .{ .grid = .{ .x = 32, .y = 32 } },
                .zones = ".dz",
                .zone_class = "dz-hover",
                .toggle_class = "dragging",
            })),
            ctx.div().class("dz").text("inbox"),
            ctx.div().class("dz").text("archive"),
        }),

        // ---- gallery: FLIP island ------------------------------------------
        sectionTitle(ctx, "Layout that animates itself"),
        ctx.p().class("hint").text("The island reorders keyed cards through the reconciler; FLIP measures the before/after and animates the difference. Remove/restore exercises the enter/leave callbacks + fade-in."),
        gallery(ctx),

        ctx.el("footer").class("foot").children(.{
            ctx.p().text("Built with verve.anim — every animation on this page survives prefers-reduced-motion (entrances land instantly, loops skip, the smoother turns off)."),
        }),
    });

    // Whole page rides the smoother — return the WRAPPER.
    return content.smoothScroll(.{ .smooth = 1.1 }).build();
}

fn sectionTitle(ctx: *const verve.Context, t: []const u8) *verve.Node {
    const anim = verve.anim;
    const a = ctx.alloc();
    return ctx.h2(t).animate(anim.reveal(a, "in-view", .{
        .start = .{ .viewport = .{ .pct = 88 } },
        .once = true,
    }));
}

fn featureDeck(ctx: *const verve.Context) *verve.Node {
    const anim = verve.anim;
    const a = ctx.alloc();
    const labels = [_][]const u8{ "tweens", "timelines", "scroll", "drag", "split", "flip" };

    const deck = ctx.div().class("deck");
    for (labels) |l| {
        _ = deck.children(.{ctx.div().class("chip fchip").text(l)});
    }
    return deck.animate(anim.from(a, ".fchip")
        .opacity(0).y(36)
        .duration(0.5).ease(.out_back)
        .stagger(.{ .each = 0.06 })
        .scrollTrigger(.{
        .start = .{ .viewport = .{ .pct = 80 } },
        .actions = .{ .on_enter = .play, .on_leave_back = .reverse },
    }));
}

/// FLIP gallery island: keyed cards (data-vkey g1..g8) + controls. The
/// grid is a keyed bind so move_keyed_child preserves element identity
/// (the FLIP fast path).
fn gallery(ctx: *const verve.Context) *verve.Node {
    const grid = ctx.div().class("gal-grid").bind("gallery_list");
    const keys = [_][]const u8{ "g1", "g2", "g3", "g4", "g5", "g6", "g7", "g8" };
    for (keys, 0..) |k, i| {
        _ = grid.children(.{
            ctx.div().class("chip gcard").attr("data-vkey", k).textInt(i + 1),
        });
    }
    const inner = ctx.div().children(.{
        ctx.div().class("gal-controls").children(.{
            ctx.el("button").attr("z-on-click", "gal_shuffle").text("shuffle"),
            ctx.el("button").attr("z-on-click", "gal_toggle").text("remove/restore"),
            ctx.span().class("hint").bind("g_status").text("ready"),
        }),
        grid,
    });
    return verve.island(ctx, .{ .name = "Gallery" }, inner);
}

pub fn page(ctx: *const verve.Context, body: *verve.Node) !*verve.Node {
    return ctx.el("html").children(.{
        ctx.el("head").children(.{
            ctx.meta("charset", "utf-8"),
            ctx.title("verve.anim — Motion, served."),
            ctx.style(
                \\body{font:16px/1.6 system-ui;margin:0;background:#0b0c10;color:#e6e6e6}
                \\.landing{max-width:none}
                \\section,h2,.hint,.deck,.flight-wrap,.morph-wrap,.pin-panel,.pen,.foot{max-width:46rem;margin-left:auto;margin-right:auto;padding:0 1.5rem}
                \\h2{margin:4rem auto 0.5rem;opacity:.25;transform:translateY(10px);transition:opacity .5s,transform .5s}
                \\h2.in-view{opacity:1;transform:none}
                \\.hint{color:#9aa0a6;font-size:.92em}
                \\button{font:inherit;padding:.4rem .8rem;background:#21262d;color:#e6e6e6;border:1px solid #30363d;border-radius:6px;cursor:pointer}
                \\button:hover{filter:brightness(1.2)}
                \\.hero{position:relative;min-height:100vh;display:flex;flex-direction:column;justify-content:center;overflow:hidden}
                \\.hero-bg,.hero-mid{position:absolute;inset:-20% 0;pointer-events:none;will-change:transform}
                \\.hero-bg{background:radial-gradient(circle at 28% 38%,#141d33 0,transparent 60%)}
                \\.hero-mid{background:radial-gradient(circle at 72% 62%,#15261c 0,transparent 50%)}
                \\.hero h1{font-size:3.2rem;margin:0 0 .5rem}
                \\.lede{max-width:34rem}
                \\.hero-badge{display:inline-block;align-self:flex-start;margin-top:1rem;padding:.4rem .8rem;border:1px solid #3a4150;border-radius:999px;background:#13151b;color:#9aa0a6;font-size:.85em;will-change:transform}
                \\.st-char,.st-word{display:inline-block;will-change:transform}
                \\.chip{display:flex;align-items:center;justify-content:center;background:#1f6feb;color:#fff;border-radius:10px;font-weight:600;will-change:transform}
                \\.deck{display:flex;gap:.6rem;flex-wrap:wrap;margin-top:.75rem}
                \\.fchip{padding:1.1rem 1.3rem}
                \\.flight-wrap{position:relative;margin-top:.75rem}
                \\.flyer{position:absolute;left:0;top:80px;width:1.6rem;height:1.6rem;color:#58a6ff;font-size:1.3rem;line-height:1.6rem;text-align:center;will-change:transform}
                \\.morph-wrap{margin-top:.75rem}
                \\.pin-panel{background:#13151b;border:1px solid #2a2f3a;border-radius:12px;padding:1.25rem;margin-top:.75rem}
                \\.scrub-bar{height:.45rem;background:#58a6ff;border-radius:3px;transform-origin:left center;margin-bottom:.75rem}
                \\.pen{position:relative;height:13rem;background:#101218;border:1px dashed #2a2f3a;border-radius:12px;margin-top:.75rem;display:flex;gap:.75rem;align-items:flex-end;padding:1rem}
                \\.drag-chip{position:absolute;top:1rem;left:1rem;width:6rem;height:3rem;cursor:grab;touch-action:none}
                \\.drag-chip.dragging{filter:brightness(1.25);cursor:grabbing}
                \\.dz{flex:1;min-height:4.5rem;display:flex;align-items:center;justify-content:center;border:1px dashed #3a4150;border-radius:10px;color:#8b949e}
                \\.dz.dz-hover{border-color:#58a6ff;color:#58a6ff;background:#11161f}
                \\.gal-controls{display:flex;gap:.5rem;align-items:center;margin:.75rem 0}
                \\.gal-grid{display:flex;gap:.5rem;flex-wrap:wrap;max-width:19rem}
                \\.gcard{width:3.8rem;height:3.8rem}
                \\.foot{padding:5rem 1.5rem 6rem;color:#8b949e}
            ),
        }),
        ctx.el("body").children(.{
            body,
            ctx.script("/verve.js"),
        }),
    }).build();
}

pub fn notFound(ctx: *const verve.Context, path: []const u8) !*verve.Node {
    return ctx.main_().children(.{
        ctx.h1("404 — Not Found"),
        ctx.p().children(.{ ctx.span().text("No route for "), ctx.code(path) }),
        ctx.p().children(.{ctx.a("/", "← Home")}),
    }).build();
}

pub fn errorPage(
    ctx: *const verve.Context,
    status_code: u16,
    status_text: []const u8,
    message: []const u8,
) !*verve.Node {
    return ctx.main_().children(.{
        ctx.el("h1").textFmt("{d} — {s}", .{ status_code, status_text }),
        ctx.p().text(message),
        ctx.p().children(.{ctx.a("/", "← Home")}),
    }).build();
}
