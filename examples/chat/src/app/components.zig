//! Page components.
//!
//! All HTML is built as a Node tree and streamed by the framework's
//! renderer. The chat page subscribes to /events via a small inline
//! script that reloads the page on counter change, so every visitor
//! sees fresh messages without manual refresh.

const verve = @import("verve");
const api = @import("api.zig");

pub fn home(ctx: *const verve.Context) !*verve.Node {
    return ctx.main_().children(.{
        ctx.h1("Verve Chat"),
        ctx.p().text("A broadcast chat board. Posts fan out to every connected browser via Server-Sent Events."),
        ctx.p().children(.{ ctx.a("/chat", "Open the chat room →") }),
    }).build();
}

pub fn chat(ctx: *const verve.Context, messages: []api.Message) !*verve.Node {
    const root = ctx.main_().attrFmt("data-tick", "{d}", .{api.last_count.load(.monotonic)}).children(.{
        ctx.h1("Chat room"),
        ctx.nav().children(.{
            ctx.a("/", "← Home"),
            ctx.span().textFmt("{d} messages", .{messages.len}),
        }),
        ctx.form(.{ .post = "/api/postMessage", .class = "post" }).children(.{
            ctx.input().name("author").type_("text").placeholder("Your name").required().attr("maxlength", "40"),
            ctx.textarea().name("body").placeholder("What's on your mind?").required().attr("maxlength", "200"),
            ctx.div().children(.{ ctx.button("Post").type_("submit") }),
        }),
    });

    if (messages.len == 0) {
        _ = root.children(.{ ctx.p().class("empty").text("No messages yet. Be the first.") });
    } else {
        const list = ctx.ul().class("msg-list");
        // Render newest first.
        var idx: usize = 0;
        while (idx < messages.len) : (idx += 1) {
            const src = &messages[messages.len - 1 - idx];
            _ = list.children(.{
                ctx.li().children(.{
                    ctx.div().children(.{
                        ctx.span().class("msg-author").text(src.authorSlice()),
                        ctx.span().class("msg-time").textFmt("#{d}", .{src.seq}),
                    }),
                    ctx.p().class("msg-body").text(src.bodySlice()),
                }),
            });
        }
        _ = root.children(.{list});
    }

    _ = root.children(.{
        ctx.form(.{ .post = "/api/clearMessages" }).children(.{
            ctx.button("Clear all").type_("submit").class("danger"),
        }),
        ctx.el("script").text(
            \\(()=>{const seen=Number(document.body.dataset.tick||0);const es=new EventSource('/events');es.addEventListener('count',(e)=>{const v=Number(e.data);if(!Number.isNaN(v)&&v!==seen){location.reload();}});})();
        ),
    });

    return root.build();
}

pub fn notFound(ctx: *const verve.Context, path: []const u8) !*verve.Node {
    return ctx.main_().children(.{
        ctx.h1("404 — Not Found"),
        ctx.p().children(.{
            ctx.span().text("No route for "),
            ctx.code(path),
        }),
        ctx.p().children(.{ ctx.a("/", "← Home") }),
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
        ctx.p().children(.{ ctx.a("/", "← Home") }),
    }).build();
}

pub fn page(ctx: *const verve.Context, body: *verve.Node) !*verve.Node {
    return ctx.el("html").children(.{
        ctx.el("head").children(.{
            ctx.meta("charset", "utf-8"),
            ctx.title("Verve Chat"),
            ctx.style(
                \\body{font:16px system-ui;margin:0;background:#0e0e10;color:#f5f5f5}
                \\main{max-width:42rem;margin:2rem auto;padding:0 1rem}
                \\h1{margin-top:0}
                \\.msg-list{list-style:none;padding:0;margin:1rem 0;border:1px solid #333;border-radius:8px;background:#15151a}
                \\.msg-list li{padding:.75rem 1rem;border-bottom:1px solid #222}
                \\.msg-list li:last-child{border-bottom:0}
                \\.msg-author{font-weight:600;color:#58a6ff}
                \\.msg-time{color:#777;font-size:.85em;margin-left:.5rem}
                \\.msg-body{margin:.25rem 0 0;white-space:pre-wrap;word-wrap:break-word}
                \\.empty{padding:1.5rem;text-align:center;color:#888}
                \\form.post{display:grid;gap:.5rem;margin:1rem 0}
                \\input,textarea{font:inherit;padding:.5rem;background:#1c1c1f;color:inherit;border:1px solid #333;border-radius:4px}
                \\textarea{resize:vertical;min-height:5rem}
                \\button{font:inherit;padding:.5rem 1rem;background:#1f6feb;color:#fff;border:0;border-radius:4px;cursor:pointer}
                \\button.danger{background:#5b2727}
                \\button:hover{filter:brightness(1.15)}
                \\nav{display:flex;gap:1rem;margin-bottom:1rem}
                \\a{color:#58a6ff;text-decoration:none}
            ),
        }),
        ctx.el("body").children(.{body}),
    }).build();
}
