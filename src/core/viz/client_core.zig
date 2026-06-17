//! `viz_core` — the chunk-visible slice of the viz library. Re-exports only
//! the pure-math pieces (geometry, layouts, interaction, edge paths) so wasm
//! island chunks can recompute layouts client-side with the exact algorithms
//! SSR used. MUST NOT transitively import `node.zig`/`context.zig` (or any
//! renderer/server code) — the wasm32-freestanding chunk build is the guard.
//!
//! Address-taken functions (allocator vtables, writer drains, `&fn`) are
//! fine here: every island chunk instantiates against a PRIVATE function
//! table (see the bridge's chunk loader + `makeChunkRuntime`), so a chunk's
//! element segment can't clobber the main client's table. Fn-pointer
//! indices crossing into the main runtime are translated at the JS boundary.

pub const canvas_buf = @import("canvas_buf.zig");
pub const geom = @import("geom.zig");
pub const interact = @import("interact.zig");
pub const edge_path = @import("edge_path.zig");
pub const common = @import("layout/common.zig");
pub const tree = @import("layout/tree.zig");
pub const radial = @import("layout/radial.zig");
pub const force = @import("layout/force.zig");
pub const dag = @import("layout/dag.zig");
