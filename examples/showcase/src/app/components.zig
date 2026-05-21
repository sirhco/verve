//! Barrel module re-exporting everything `routes.zig` needs.

pub const shell = @import("components/shell.zig");
pub const ui = @import("components/ui.zig");
pub const blog = struct {
    pub const post = @import("components/blog/post.zig");
    pub const list = @import("components/blog/list.zig");
    pub const feed = @import("components/blog/feed.zig");
};
pub const tracker = struct {
    pub const org = @import("components/tracker/org.zig");
    pub const project = @import("components/tracker/project.zig");
    pub const board = @import("components/tracker/board.zig");
    pub const issue = @import("components/tracker/issue.zig");
    pub const issues = @import("components/tracker/issues.zig");
    pub const team = @import("components/tracker/team.zig");
    pub const realtime = @import("components/tracker/realtime.zig");
};
pub const admin = struct {
    pub const index = @import("components/admin/index.zig");
    pub const analytics = @import("components/admin/analytics.zig");
    pub const settings = @import("components/admin/settings.zig");
    pub const jobs = @import("components/admin/jobs.zig");
    pub const audit = @import("components/admin/audit.zig");
    pub const users = @import("components/admin/users.zig");
};
pub const not_found = @import("components/notFound.zig");

// Hooks the framework's main.zig expects on the `app.components`
// namespace.
pub const page = shell.page;
pub const notFound = not_found.notFound;
pub const errorPage = not_found.errorPage;
