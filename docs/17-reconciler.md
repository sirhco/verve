# 17 — Reconciler

Keyed-list reconciliation in the WASM client. When a reactive
list updates, the reconciler emits the minimum sequence of
(insert | move | remove) DOM operations that turns the live DOM
into the new order. Surviving children keep their nodes intact
across moves, so reactive state on their descendants stays put.

## When to reach for it

Anywhere a parent's children are keyed and the key order changes
in response to a Signal. Typical shapes:

- Reordering a todo list when the user drags a row.
- Inserting / removing items in a filtered search result.
- Streaming a feed where new messages arrive at the top.

For static (server-only) keyed iteration, the existing
`verve.forEach` helper already emits `<li data-vkey="<key>">` —
no reconciler involvement, no WASM cost.

## API

### Planner

```zig
const reconciler = @import("client/reconciler.zig");

const ops = try reconciler.plan(arena, old_keys, new_keys);
```

Returns a slice of `Op { kind, key, anchor }`. `kind` is one of
`.insert`, `.move`, `.remove`. `anchor` is the key of the next
surviving sibling (or null when the inserted / moved node should
end up at the end of the parent).

`plan` is allocation-free aside from the returned slice — pass
the per-frame scratch arena so the slice goes away at the end of
the current effect run.

### Runtime handle

```zig
const handle = try runtime.registerForEach("items", &initial_keys);
```

`ForEachHandle` caches the last-known key order against a keyed
parent identified by `parent_bind`. The initial keys must match
what the server rendered into the parent, so the first `update`
emits ops for only the real delta:

```zig
try handle.update(arena, &new_keys, &new_html);
```

`new_html[i]` is the child markup for `new_keys[i]`. Inserted
children are anchored against the next surviving key; removed
children are detached; surviving children keep their DOM nodes
intact across moves.

### Reactive binding

```zig
_ = try runtime.bindForEach(handle, &state, render_fn);
```

Wraps `createEffect`: every Signal `render_fn` reads becomes a
dependency. On change the closure re-runs, computes a new
(keys, html) pairing, and calls `handle.update`. First invocation
runs eagerly so the initial dependency set is recorded.

`render_fn` allocates its returned slices from the runtime's
per-frame scratch allocator (`src/client/scratch.zig`). The
allocator resets at the top of every re-run, so memory usage is
bounded by the single largest frame — not by iteration count.

## Op semantics

| Op | Effect |
|---|---|
| `insert` | Create a new `<*>` from the supplied HTML, stamp `data-vkey="<key>"`, `parent.insertBefore(node, anchor)`. `anchor = null` → `appendChild`. |
| `move`   | Find the existing `[data-vkey="<key>"]` under the parent, `parent.insertBefore(node, anchor)`. Reactive state on the moved subtree survives. |
| `remove` | Find the existing `[data-vkey="<key>"]` under the parent, `node.remove()`. |

## Algorithm

The planner walks the old list to identify removals, walks the
new list to identify inserts, and computes a Longest-Increasing-
Subsequence over the new-list positions of every surviving key
(i.e. the entries whose `idx_in_old` is non-negative). Every key
on the LIS keeps its position; everything else becomes a move.
LIS minimizes the number of moves, which dominates cost in real
lists.

Reference: Vue 3 / Solid / Inferno all settle on the same shape.
The planner runs in O(n log n).

## Example: reactive list of items

```zig
const State = struct {
    items: *verve.Signal([]const u8),

    fn render(self: *@This(), alloc: std.mem.Allocator) anyerror!runtime.ForEachData {
        const lines = self.items.get();
        const keys = try alloc.alloc([]const u8, lines.len);
        const html = try alloc.alloc([]const u8, lines.len);
        for (lines, 0..) |line, i| {
            keys[i] = try std.fmt.allocPrint(alloc, "row-{d}", .{i});
            html[i] = try std.fmt.allocPrint(alloc, "<li>{s}</li>", .{line});
        }
        return .{ .keys = keys, .html = html };
    }
};

const handle = try runtime.registerForEach("items", &.{});
var state: State = .{ .items = items_signal };
_ = try runtime.bindForEach(handle, &state, State.render);

// Any subsequent `items_signal.set(...)` re-runs render and
// dispatches the minimal DOM delta.
```

## Limits today

- HTML for inserted children is rendered into a string by the
  caller. A future revision can take a `*Node` builder closure
  and serialize internally — saves the call site from running
  `escapeHtml` itself.
- `applyReconcile` reads parent elements by their `z-bind` /
  `data-vh` attribute; the parent must be unique on the page (or
  the bridge fans the same op across each match, which is rarely
  what callers want).
- Memory bound: 256 KB scratch per frame. Lists that need more
  per-frame allocation should split the render across multiple
  effects.

## Verification

`zig build test` covers:

- Identity (no ops).
- Pure insert.
- Pure remove.
- Swap → exactly one move.
- Reverse → moves on every-but-LIS key.
- Mixed insert + remove + move.
- Anchor positioning (insert lands before the next surviving key).
- Trailing insert with null anchor.
- `ForEachHandle.update` advances the cached key list correctly.
- `bindForEach` re-runs across signal mutations, scratch usage
  stays bounded.

## Next

- [05 — Reactivity](05-reactivity.md) — the underlying Signal /
  Effect graph the reconciler ties into.
- [12 — WASM client](12-wasm-client.md) — runtime layout, scratch
  region, allocator split.
- [15 — Islands](15-islands.md) — using reconciler-driven lists
  inside an island chunk.
