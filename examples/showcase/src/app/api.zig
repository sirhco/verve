//! Verve Showcase — Hybrid Product Hub.
//!
//! One binary exercising every Verve public export across three
//! integrated sub-products:
//!   - /blog/* — content area (posts, categories, RSS, sitemap, i18n)
//!   - /app/* — collaborative project tracker (org → project → issue)
//!   - /admin/* — analytics + settings + protected admin
//!
//! This module re-exports `routes`, `components`, `Actions`, and
//! `last_count` so the framework's `app` module hook resolves
//! everything from a single entry point.

const std = @import("std");
const verve = @import("verve");

pub const components = @import("components.zig");
pub const islands = @import("islands.zig");
pub const routes_mod = @import("routes.zig");
pub const routes = routes_mod.routes;

pub const i18n = @import("components/i18n.zig");

const log = std.log.scoped(.showcase);

/// Required by the framework's WebSocket / SSE counter hooks. Mirrors
/// the main demo so the existing `/counter` wire keeps working.
pub var last_count: std.atomic.Value(i32) = .init(0);

// ---- domain types ----------------------------------------------------

pub const Role = enum { admin, member, viewer };

pub const User = struct {
    id: u32,
    name: []const u8,
    email: []const u8,
    role: Role,
    avatar_seed: []const u8,
};

pub const Org = struct {
    id: u32,
    name: []const u8,
    slug: []const u8,
    accent: []const u8,
};

pub const ProjectStatus = enum { active, archived };
pub const Project = struct {
    id: u32,
    org_id: u32,
    name: []const u8,
    slug: []const u8,
    status: ProjectStatus,
};

pub const IssueStatus = enum { open, in_progress, done };
pub const Issue = struct {
    id: u32,
    project_id: u32,
    num: u32,
    title: []const u8,
    body: []const u8,
    status: IssueStatus,
    assignee_id: ?u32,
    created_at: []const u8,
};

pub const Comment = struct {
    id: u32,
    issue_id: u32,
    author_id: u32,
    body: []const u8,
    created_at: []const u8,
};

pub const Post = struct {
    id: u32,
    title: []const u8,
    slug: []const u8,
    body_md: []const u8,
    author_id: u32,
    category_slug: []const u8,
    published_at: []const u8,
    locale: []const u8,
};

pub const Category = struct {
    slug: []const u8,
    name: []const u8,
    description: []const u8,
};

pub const Activity = struct {
    id: u32,
    kind: []const u8,
    actor_id: u32,
    target_kind: []const u8,
    target_id: u32,
    body: []const u8,
    created_at: []const u8,
};

// ---- seed data (immutable for read paths; mutable lists hold dynamic state) ----

pub const users: []const User = &.{
    .{ .id = 1, .name = "Alice Park",   .email = "alice@acme.io",   .role = .admin,  .avatar_seed = "ap" },
    .{ .id = 2, .name = "Bobby Liang",  .email = "bobby@acme.io",   .role = .member, .avatar_seed = "bl" },
    .{ .id = 3, .name = "Carmen Vela",  .email = "carmen@acme.io",  .role = .member, .avatar_seed = "cv" },
    .{ .id = 4, .name = "Dev Patel",    .email = "dev@globex.dev",  .role = .member, .avatar_seed = "dp" },
    .{ .id = 5, .name = "Elena Bauer",  .email = "elena@globex.dev",.role = .viewer, .avatar_seed = "eb" },
};

pub const orgs: []const Org = &.{
    .{ .id = 1, .name = "Acme",   .slug = "acme",   .accent = "#1f6feb" },
    .{ .id = 2, .name = "Globex", .slug = "globex", .accent = "#9333ea" },
    .{ .id = 3, .name = "Initech",.slug = "initech",.accent = "#2ea043" },
};

pub const projects: []const Project = &.{
    .{ .id = 1, .org_id = 1, .name = "Website",    .slug = "website",    .status = .active },
    .{ .id = 2, .org_id = 1, .name = "Mobile",     .slug = "mobile",     .status = .active },
    .{ .id = 3, .org_id = 1, .name = "Infra",      .slug = "infra",      .status = .archived },
    .{ .id = 4, .org_id = 2, .name = "ML Lab",     .slug = "ml-lab",     .status = .active },
    .{ .id = 5, .org_id = 2, .name = "Payments",   .slug = "payments",   .status = .active },
    .{ .id = 6, .org_id = 3, .name = "Onboarding", .slug = "onboarding", .status = .active },
    .{ .id = 7, .org_id = 3, .name = "Reports",    .slug = "reports",    .status = .active },
    .{ .id = 8, .org_id = 3, .name = "Beta",       .slug = "beta",       .status = .archived },
};

pub const categories: []const Category = &.{
    .{ .slug = "zig",   .name = "Zig",   .description = "Language updates, comptime tricks, std.Io." },
    .{ .slug = "wasm",  .name = "WASM",  .description = "wasm32-freestanding, growable heaps, hydration." },
    .{ .slug = "ssr",   .name = "SSR",   .description = "Server-side rendering, streaming, head slots." },
    .{ .slug = "ops",   .name = "Ops",   .description = "Deploy, observability, performance." },
};

pub const posts: []const Post = &.{
    .{ .id = 1, .title = "Welcome to Verve",                .slug = "welcome",       .body_md = post_welcome,       .author_id = 1, .category_slug = "ssr",  .published_at = "2026-05-01", .locale = "en" },
    .{ .id = 2, .title = "Bienvenidos a Verve",             .slug = "welcome",       .body_md = post_welcome_es,    .author_id = 1, .category_slug = "ssr",  .published_at = "2026-05-01", .locale = "es" },
    .{ .id = 3, .title = "Bienvenue sur Verve",             .slug = "welcome",       .body_md = post_welcome_fr,    .author_id = 1, .category_slug = "ssr",  .published_at = "2026-05-01", .locale = "fr" },
    .{ .id = 4, .title = "Comptime route parsing",          .slug = "comptime-routes",.body_md = post_routes,       .author_id = 2, .category_slug = "zig",  .published_at = "2026-05-04", .locale = "en" },
    .{ .id = 5, .title = "Growable WASM heaps",             .slug = "growable-heap", .body_md = post_heap,          .author_id = 3, .category_slug = "wasm", .published_at = "2026-05-08", .locale = "en" },
    .{ .id = 6, .title = "Head slots done right",           .slug = "head-slots",    .body_md = post_head,          .author_id = 1, .category_slug = "ssr",  .published_at = "2026-05-11", .locale = "en" },
    .{ .id = 7, .title = "Owner trees in 200 lines",        .slug = "owner-tree",    .body_md = post_owner,         .author_id = 2, .category_slug = "zig",  .published_at = "2026-05-13", .locale = "en" },
    .{ .id = 8, .title = "Cache-busted assets at compile",  .slug = "asset-hashing", .body_md = post_hash,          .author_id = 4, .category_slug = "ops",  .published_at = "2026-05-15", .locale = "en" },
    .{ .id = 9, .title = "Nested routes without macros",    .slug = "nested-routes", .body_md = post_nested,        .author_id = 1, .category_slug = "ssr",  .published_at = "2026-05-16", .locale = "en" },
    .{ .id = 10,.title = "CSRF in pure Zig",                .slug = "csrf-zig",      .body_md = post_csrf,          .author_id = 2, .category_slug = "ops",  .published_at = "2026-05-17", .locale = "en" },
    .{ .id = 11,.title = "Field-grained Stores",            .slug = "stores",        .body_md = post_stores,        .author_id = 3, .category_slug = "zig",  .published_at = "2026-05-18", .locale = "en" },
    .{ .id = 12,.title = "Islands without a build pipeline",.slug = "islands",       .body_md = post_islands,       .author_id = 4, .category_slug = "wasm", .published_at = "2026-05-19", .locale = "en" },
};

const post_welcome    = "# Welcome\n\nVerve is a pure-Zig full-stack framework. This site exercises every public export of the framework so you can see what shipping a feature looks like in context.\n\nClick around — nothing here is a static page; every URL is a real Verve route.";
const post_welcome_es = "# Bienvenidos\n\nVerve es un marco web Zig puro. Este sitio ejercita cada API pública.";
const post_welcome_fr = "# Bienvenue\n\nVerve est un framework web 100% Zig.";
const post_routes     = "Route patterns are parsed at comptime via `verve.Route.init`. The parser produces a static `[]const Segment` slice — no allocations at request time.";
const post_heap       = "The wasm32-freestanding client uses a bump arena backed by `@wasmMemoryGrow`. Reset rewinds the pointer; growth happens lazily.";
const post_head       = "Components push title/meta/link/json-ld entries into `ctx.head`. The shell drains them in priority order. Replace-not-append semantics keep things stable.";
const post_owner      = "The Owner tree mirrors SolidJS / Leptos. Per-request owner; LIFO cleanup; `on_cleanup` hooks fire deterministically.";
const post_hash       = "Build-time Wyhash → 8 hex chars → `/public/style-<hash>.css`. `Cache-Control: immutable` for hashed URLs, max-age=300 for unhashed.";
const post_nested     = "`Route.layout(pattern, render, children)` declares a layout with nested children. `ctx.outlet()` is the placeholder the child renders into.";
const post_csrf       = "HMAC-SHA256 token signed over a timestamp. Cookie + form field round-trip. SameSite=Strict closes the cross-origin gap.";
const post_stores     = "A Store(T) is a comptime tuple of Signal(field.type), one per declared field. Reads subscribe to ONLY the field touched. Writes notify ONLY that field's effects.";
const post_islands    = "Islands ship as `<verve-island data-name=… data-props=…>` markers. The Phase 8 client runtime will fetch each island's WASM chunk on demand.";

// ---- mutable state: issues + comments + activity ----

const MAX_ISSUES: usize = 256;
const MAX_COMMENTS: usize = 512;
const MAX_ACTIVITY: usize = 128;

var issue_storage: [MAX_ISSUES]Issue = undefined;
var issue_count: usize = 0;
var issue_mu: std.atomic.Mutex = .unlocked;

var comment_storage: [MAX_COMMENTS]Comment = undefined;
var comment_count: usize = 0;
var comment_mu: std.atomic.Mutex = .unlocked;

var activity_storage: [MAX_ACTIVITY]Activity = undefined;
var activity_head: usize = 0;
var activity_len: usize = 0;
var activity_mu: std.atomic.Mutex = .unlocked;

fn lockIssues() void {
    while (!issue_mu.tryLock()) std.atomic.spinLoopHint();
}
fn lockComments() void {
    while (!comment_mu.tryLock()) std.atomic.spinLoopHint();
}
fn lockActivity() void {
    while (!activity_mu.tryLock()) std.atomic.spinLoopHint();
}

/// Seed issues + comments at startup. Idempotent: subsequent calls are
/// no-ops. The framework's main.zig invokes this lazily on first
/// snapshot read.
fn ensureSeeded() void {
    seedIssues();
    seedComments();
    seedActivity();
}

fn seedIssues() void {
    lockIssues();
    defer issue_mu.unlock();
    if (issue_count != 0) return;

    const seed = [_]struct { project_id: u32, title: []const u8, status: IssueStatus, assignee_id: ?u32, body: []const u8 }{
        .{ .project_id = 1, .title = "Wire up SPA Link in nav",      .status = .done,        .assignee_id = 1, .body = "Replace bare anchors with verve.link so client-side nav works." },
        .{ .project_id = 1, .title = "Make hashed assets default",   .status = .in_progress, .assignee_id = 2, .body = "Audit places using /public/<file>; switch to ctx.assetHref." },
        .{ .project_id = 1, .title = "Audit head-slot priorities",   .status = .open,        .assignee_id = 3, .body = "Canonical / OG / JSON-LD ordering should be stable across pages." },
        .{ .project_id = 1, .title = "Tune SSR cache headers",       .status = .open,        .assignee_id = 1, .body = "Vary on Accept-Language; max-age=300 on dynamic, immutable on assets." },
        .{ .project_id = 1, .title = "Add CSP report-uri",           .status = .open,        .assignee_id = null, .body = "Track CSP violations during onboarding rollouts." },
        .{ .project_id = 2, .title = "iOS push tokens",              .status = .in_progress, .assignee_id = 2, .body = "APNs handshake on app launch; persist token server-side." },
        .{ .project_id = 2, .title = "Android deep links",           .status = .open,        .assignee_id = 4, .body = "Match `/app/o/:org/p/:project/i/:num` via app links." },
        .{ .project_id = 2, .title = "Offline mode",                 .status = .open,        .assignee_id = null, .body = "Service worker + IndexedDB scaffolding." },
        .{ .project_id = 4, .title = "Replace TF with JAX",          .status = .done,        .assignee_id = 4, .body = "Internal models; perf benchmarks attached." },
        .{ .project_id = 4, .title = "Vector store sharding",        .status = .in_progress, .assignee_id = 4, .body = "Move from single Postgres to per-tenant pgvector." },
        .{ .project_id = 5, .title = "PCI scope reduction",          .status = .open,        .assignee_id = 1, .body = "Tokenize card numbers at the edge; reduce stored fields." },
        .{ .project_id = 5, .title = "3DS challenge flow",           .status = .open,        .assignee_id = 3, .body = "Test against Stripe + Adyen sandboxes." },
        .{ .project_id = 6, .title = "Onboarding email cadence",     .status = .open,        .assignee_id = 5, .body = "Day 0 / Day 3 / Day 7 with optional opt-out." },
        .{ .project_id = 7, .title = "Quarterly snapshot job",       .status = .done,        .assignee_id = 4, .body = "Cron at 02:00 UTC each Sunday; CSV + Parquet exports." },
        .{ .project_id = 7, .title = "Report builder UI",            .status = .in_progress, .assignee_id = 5, .body = "Drag-and-drop fields onto a canvas; save as templates." },
    };
    for (seed, 0..) |s, i| {
        const id: u32 = @intCast(i + 1);
        issue_storage[issue_count] = .{
            .id = id,
            .project_id = s.project_id,
            .num = id,
            .title = s.title,
            .body = s.body,
            .status = s.status,
            .assignee_id = s.assignee_id,
            .created_at = "2026-05-14",
        };
        issue_count += 1;
    }
}

fn seedComments() void {
    lockComments();
    defer comment_mu.unlock();
    if (comment_count != 0) return;

    const comment_seed = [_]struct { issue_id: u32, author_id: u32, body: []const u8 }{
        .{ .issue_id = 1, .author_id = 2, .body = "Pushed verve.link in nav.zig — head merge looks correct." },
        .{ .issue_id = 1, .author_id = 3, .body = "Ship it. Adding follow-up for prefetch tuning." },
        .{ .issue_id = 2, .author_id = 1, .body = "Started a list at /admin/audit. Will close once /blog updates land." },
        .{ .issue_id = 3, .author_id = 1, .body = "Tracking the priority order at the top of head.zig." },
        .{ .issue_id = 6, .author_id = 4, .body = "Token refresh + retry loop tested against 3 device classes." },
        .{ .issue_id = 9, .author_id = 1, .body = "Numbers are in the README. ~22% perf win." },
    };
    for (comment_seed, 0..) |c, i| {
        comment_storage[comment_count] = .{
            .id = @intCast(i + 1),
            .issue_id = c.issue_id,
            .author_id = c.author_id,
            .body = c.body,
            .created_at = "2026-05-15",
        };
        comment_count += 1;
    }
}

fn seedActivity() void {
    lockActivity();
    defer activity_mu.unlock();
    if (activity_len != 0) return;

    const activity_seed = [_]struct { kind: []const u8, actor_id: u32, target_kind: []const u8, target_id: u32, body: []const u8 }{
        .{ .kind = "issue.created", .actor_id = 1, .target_kind = "issue",   .target_id = 15, .body = "Quarterly snapshot job" },
        .{ .kind = "issue.closed",  .actor_id = 4, .target_kind = "issue",   .target_id = 1,  .body = "Wire up SPA Link in nav" },
        .{ .kind = "comment.added", .actor_id = 2, .target_kind = "issue",   .target_id = 1,  .body = "head merge looks correct" },
        .{ .kind = "post.published",.actor_id = 1, .target_kind = "post",    .target_id = 12, .body = "Islands without a build pipeline" },
        .{ .kind = "user.invited",  .actor_id = 1, .target_kind = "user",    .target_id = 5,  .body = "Elena Bauer (viewer)" },
        .{ .kind = "project.created",.actor_id=4, .target_kind = "project", .target_id = 8,  .body = "Beta" },
    };
    for (activity_seed) |a| {
        activity_storage[activity_head] = .{
            .id = @intCast(activity_head + 1),
            .kind = a.kind,
            .actor_id = a.actor_id,
            .target_kind = a.target_kind,
            .target_id = a.target_id,
            .body = a.body,
            .created_at = "2026-05-19",
        };
        activity_head = (activity_head + 1) % MAX_ACTIVITY;
        if (activity_len < MAX_ACTIVITY) activity_len += 1;
    }
}

// ---- read snapshots --------------------------------------------------

pub fn allIssues(arena: std.mem.Allocator) ![]const Issue {
    ensureSeeded();
    lockIssues();
    defer issue_mu.unlock();
    const out = try arena.alloc(Issue, issue_count);
    @memcpy(out, issue_storage[0..issue_count]);
    return out;
}

pub fn issuesForProject(arena: std.mem.Allocator, project_id: u32) ![]const Issue {
    const all = try allIssues(arena);
    var list: std.ArrayListUnmanaged(Issue) = .empty;
    for (all) |it| {
        if (it.project_id == project_id) try list.append(arena, it);
    }
    return list.toOwnedSlice(arena);
}

pub fn issueByNum(arena: std.mem.Allocator, project_id: u32, num: u32) ?Issue {
    const all = allIssues(arena) catch return null;
    for (all) |it| if (it.project_id == project_id and it.num == num) return it;
    return null;
}

pub fn commentsForIssue(arena: std.mem.Allocator, issue_id: u32) ![]const Comment {
    ensureSeeded();
    lockComments();
    defer comment_mu.unlock();
    var list: std.ArrayListUnmanaged(Comment) = .empty;
    for (comment_storage[0..comment_count]) |c| {
        if (c.issue_id == issue_id) try list.append(arena, c);
    }
    return list.toOwnedSlice(arena);
}

pub fn recentActivity(arena: std.mem.Allocator, limit: usize) ![]const Activity {
    ensureSeeded();
    lockActivity();
    defer activity_mu.unlock();
    const n = @min(limit, activity_len);
    var out = try arena.alloc(Activity, n);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        // Walk backwards from activity_head (most recent first).
        const idx = (activity_head + MAX_ACTIVITY - 1 - i) % MAX_ACTIVITY;
        out[i] = activity_storage[idx];
    }
    return out;
}

pub fn postsByLocale(arena: std.mem.Allocator, locale: []const u8) ![]const Post {
    var list: std.ArrayListUnmanaged(Post) = .empty;
    for (posts) |p| {
        if (std.mem.eql(u8, p.locale, locale)) try list.append(arena, p);
    }
    return list.toOwnedSlice(arena);
}

pub fn postBySlug(slug: []const u8, locale: []const u8) ?Post {
    for (posts) |p| {
        if (std.mem.eql(u8, p.slug, slug) and std.mem.eql(u8, p.locale, locale)) return p;
    }
    // Fall back to English if the localized version isn't available.
    for (posts) |p| {
        if (std.mem.eql(u8, p.slug, slug) and std.mem.eql(u8, p.locale, "en")) return p;
    }
    return null;
}

pub fn postsInCategory(arena: std.mem.Allocator, slug: []const u8, locale: []const u8) ![]const Post {
    var list: std.ArrayListUnmanaged(Post) = .empty;
    for (posts) |p| {
        if (std.mem.eql(u8, p.category_slug, slug) and std.mem.eql(u8, p.locale, locale)) {
            try list.append(arena, p);
        }
    }
    return list.toOwnedSlice(arena);
}

pub fn userById(id: u32) ?User {
    for (users) |u| if (u.id == id) return u;
    return null;
}

pub fn orgBySlug(slug: []const u8) ?Org {
    for (orgs) |o| if (std.mem.eql(u8, o.slug, slug)) return o;
    return null;
}

pub fn projectBySlug(org_id: u32, slug: []const u8) ?Project {
    for (projects) |p| if (p.org_id == org_id and std.mem.eql(u8, p.slug, slug)) return p;
    return null;
}

pub fn projectsForOrg(arena: std.mem.Allocator, org_id: u32) ![]const Project {
    var list: std.ArrayListUnmanaged(Project) = .empty;
    for (projects) |p| if (p.org_id == org_id) try list.append(arena, p);
    return list.toOwnedSlice(arena);
}

// ---- write paths (Actions) -------------------------------------------

pub const Actions = struct {
    pub fn addComment(args: struct { issue_id: u32, body: []const u8 }) !void {
        ensureSeeded();
        const body = std.mem.trim(u8, args.body, &std.ascii.whitespace);
        if (body.len == 0) return error.EmptyBody;
        lockComments();
        defer comment_mu.unlock();
        if (comment_count >= MAX_COMMENTS) return error.Full;
        comment_storage[comment_count] = .{
            .id = @intCast(comment_count + 1),
            .issue_id = args.issue_id,
            .author_id = 1, // current user is always Alice in this demo
            .body = body,
            .created_at = "2026-05-20",
        };
        comment_count += 1;
        log.info("comment added to issue #{d}: {s}", .{ args.issue_id, body });
    }

    pub fn updateIssueStatus(args: struct { issue_id: u32, status: []const u8 }) !void {
        ensureSeeded();
        lockIssues();
        defer issue_mu.unlock();
        for (issue_storage[0..issue_count]) |*it| {
            if (it.id == args.issue_id) {
                if (std.mem.eql(u8, args.status, "open"))        it.status = .open
                else if (std.mem.eql(u8, args.status, "in_progress")) it.status = .in_progress
                else if (std.mem.eql(u8, args.status, "done"))   it.status = .done
                else return error.BadStatus;
                _ = last_count.fetchAdd(1, .monotonic);
                return;
            }
        }
        return error.NotFound;
    }

    pub fn incrementCount(_: struct {}) void {
        _ = last_count.fetchAdd(1, .monotonic);
    }

    pub fn decrementCount(_: struct {}) void {
        _ = last_count.fetchSub(1, .monotonic);
    }

    pub fn draft(args: struct { title: []const u8 }) []const u8 {
        return args.title;
    }
};

// ---- route guards ----------------------------------------------------

pub fn adminGuard(ctx: *verve.Context) ?verve.Redirect {
    const meta = ctx.request_meta orelse return .{ .to = "/?reason=admin-only" };
    const role = meta.cookie("role") orelse "";
    if (std.mem.eql(u8, role, "admin")) return null;
    return .{ .to = "/?reason=admin-only" };
}

pub fn teamGuard(ctx: *verve.Context) ?verve.Redirect {
    const meta = ctx.request_meta orelse return .{ .to = "/app?reason=team-only" };
    const loc = ctx.location orelse return .{ .to = "/app?reason=team-only" };
    var l = loc.*;
    const t = l.queryGet(ctx.alloc(), "token") catch return .{ .to = "/app?reason=team-only" };
    if (t) |v| if (v.len > 0) return null;
    _ = meta;
    return .{ .to = "/app?reason=team-only" };
}

/// Synthesize the current user from a `role=` cookie. Real apps wire
/// this to a session store. The DI demo (provide/use) reads this to
/// surface the current user across the tracker shell.
pub fn currentUser(ctx: *const verve.Context) User {
    const meta = ctx.request_meta orelse return users[1];
    const role = meta.cookie("role") orelse return users[1];
    if (std.mem.eql(u8, role, "admin")) return users[0];
    if (std.mem.eql(u8, role, "viewer")) return users[4];
    return users[1];
}
