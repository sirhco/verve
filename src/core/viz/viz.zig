//! Verve visualization library — public surface, re-exported as `verve.viz`.
//!
//! A native, pure-Zig, declarative toolkit for graphs, hierarchies, and charts.
//! Layout and geometry are computed in Zig (server-side or in wasm); output is
//! an SVG `*Node` tree that serializes through the normal renderer — so the
//! same call works for SSR (no-JS-friendly) and as the SSR half of an
//! interactive island.
//!
//! Quick start:
//! ```zig
//! // Node-link graph
//! const g = verve.viz.Graph{
//!     .nodes  = &.{ .{ .id = "a", .label = "A" }, .{ .id = "b", .label = "B" } },
//!     .edges  = &.{ .{ .from = "a", .to = "b" } },
//!     .layout = .force, // .tree | .radial | .force
//! };
//! const svg = try verve.viz.renderGraph(ctx, g, .{ .width = 800, .height = 600 }).build();
//!
//! // Bar chart
//! const node = try verve.viz.barChart(ctx, &.{
//!     .{ .label = "Jan", .value = 10 }, .{ .label = "Feb", .value = 14 },
//! }, .{}).build();
//! ```

const geom = @import("geom.zig");
const scale = @import("scale.zig");
const axis_mod = @import("axis.zig");
const scene_mod = @import("scene.zig");
const chart_mod = @import("chart.zig");
const graph_mod = @import("graph.zig");
const tree_mod = @import("layout/tree.zig");
const radial_mod = @import("layout/radial.zig");
const force_mod = @import("layout/force.zig");
const dag_mod = @import("layout/dag.zig");
const interact_mod = @import("interact.zig");

// ---- geometry ----
pub const Vec2 = geom.Vec2;
pub const Rect = geom.Rect;
pub const lerp = geom.lerp;
pub const clamp = geom.clamp;

// ---- scales / axes ----
pub const LinearScale = scale.Linear;
pub const BandScale = scale.Band;
pub const LogScale = scale.Log;
pub const TimeScale = scale.Time;
pub const Tick = scale.Tick;
pub const Axis = axis_mod;

// ---- scene model ----
pub const Scene = scene_mod.Scene;
pub const Shape = scene_mod.Shape;
pub const Style = scene_mod.Style;
pub const sceneToNode = scene_mod.toNode;

// ---- charts ----
pub const Datum = chart_mod.Datum;
pub const Point = chart_mod.Point;
pub const ChartOpts = chart_mod.Opts;
pub const PieOpts = chart_mod.PieOpts;
pub const palette = chart_mod.palette;
pub const barChart = chart_mod.bar;
pub const lineChart = chart_mod.line;
pub const scatterChart = chart_mod.scatter;
pub const areaChart = chart_mod.area;
pub const pieChart = chart_mod.pie;

// ---- graphs ----
pub const Graph = graph_mod.Graph;
pub const GraphNode = graph_mod.GraphNode;
pub const GraphEdge = graph_mod.GraphEdge;
pub const GraphOpts = graph_mod.Opts;
pub const Layout = graph_mod.Layout;
pub const renderGraph = graph_mod.render;
/// Lower-level graph entry points for interactive islands: compute the fitted
/// positions once, reuse them for both the SSR tree and the hydration props.
pub const graphPositions = graph_mod.computePositions;
pub const renderGraphWith = graph_mod.renderWithPositions;

// ---- layout algorithms (lower-level, index/edge-pair based) ----
pub const treeLayout = tree_mod.layout;
pub const radialLayout = radial_mod.layout;
pub const dagLayout = dag_mod.layout;
pub const forceLayout = force_mod.run;
pub const ForceState = force_mod.State;
pub const forceInit = force_mod.init;

// ---- interaction math (for custom interactive islands) ----
pub const interact = interact_mod;
pub const View = interact_mod.View;

test {
    _ = geom;
    _ = scale;
    _ = axis_mod;
    _ = scene_mod;
    _ = chart_mod;
    _ = graph_mod;
    _ = tree_mod;
    _ = radial_mod;
    _ = force_mod;
    _ = dag_mod;
    _ = interact_mod;
    _ = @import("layout/common.zig");
}
