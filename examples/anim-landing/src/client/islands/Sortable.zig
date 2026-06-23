//! Sortable island for anim-landing: a single drag-to-reorder list + a
//! two-column cross-list board. Mirrors the AnimDemo.zig sortable wiring
//! (the verified-working pattern from the main app).

const verve = @import("verve");

export fn hydrate(props_ptr: u32, props_len: u32, root_id: u32) void {
    _ = props_ptr;
    _ = props_len;
    _ = root_id;

    // Single vertical list — FLIP-animated reorder.
    verve.registerStr("sort_status", "drag an item to reorder");
    _ = verve.sortable("#sort-list", .{ .items = "li", .toggle_class = "sorting" }, .{
        .on_reorder = &onReorder,
    });

    // Two-column board — cross-list group transfer.
    verve.registerStr("board_status", "drag an item between columns");
    _ = verve.sortable("#board-col-a", .{
        .items = "li",
        .group = "board",
        .toggle_class = "sorting",
    }, .{
        .on_reorder = &onBoardReorder,
        .on_enter_group = &onBoardEnter,
    });
    _ = verve.sortable("#board-col-b", .{
        .items = "li",
        .group = "board",
        .toggle_class = "sorting",
    }, .{
        .on_reorder = &onBoardReorder,
        .on_enter_group = &onBoardEnter,
    });
}

fn onReorder() void {
    verve.signalSetStr("sort_status", "reordered!");
}

fn onBoardReorder() void {
    verve.signalSetStr("board_status", "item moved!");
}

fn onBoardEnter() void {
    verve.signalSetStr("board_status", "item entering column…");
}
