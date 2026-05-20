//! Verve — full-stack Zig web framework public API.
//!
//! Shared between native server build and wasm32-freestanding client build.
//! Anything imported here must compile in both targets, so this file avoids
//! std.Io / std.heap.page_allocator etc. Server-only or wasm-only helpers
//! live in their respective subtrees.

const node_mod = @import("core/node.zig");
const signal_mod = @import("core/signal.zig");
const effect_mod = @import("core/effect.zig");
const owner_mod = @import("core/owner.zig");
const noderef_mod = @import("core/noderef.zig");
const context_mod = @import("core/context.zig");
const renderer_mod = @import("core/renderer.zig");
const request_meta_mod = @import("core/request_meta.zig");
const location_mod = @import("core/location.zig");
const route_mod = @import("core/route.zig");
const stored_mod = @import("core/stored.zig");
const head_mod = @import("core/head.zig");
const fetch_mod = @import("core/fetch.zig");
const resource_mod = @import("core/resource.zig");
const action_mod = @import("core/action.zig");
const suspense_mod = @import("core/suspense.zig");
const serialize_mod = @import("core/serialize.zig");
const csrf_mod = @import("core/csrf.zig");
const control_flow_mod = @import("core/control_flow.zig");
const slot_mod = @import("core/slot.zig");
const link_mod = @import("core/link.zig");
const store_mod = @import("core/store.zig");
const i18n_mod = @import("core/i18n.zig");
const error_boundary_mod = @import("core/error_boundary.zig");

pub const Node = node_mod.Node;
pub const Attr = node_mod.Attr;
pub const Signal = signal_mod.Signal;
pub const Effect = effect_mod.Effect;
pub const Owner = owner_mod.Owner;
pub const NodeRef = noderef_mod.NodeRef;
pub const NodeRefTag = noderef_mod.Tag;
pub const StoredValue = stored_mod.StoredValue;
pub const Head = head_mod.Head;
pub const HeadMeta = head_mod.Meta;
pub const HeadLink = head_mod.Link;
pub const HeadScript = head_mod.Script;
pub const FetchOptions = fetch_mod.FetchOptions;
pub const FetchResponse = fetch_mod.FetchResponse;
pub const Resource = resource_mod.Resource;
pub const ResourceState = resource_mod.ResourceState;
pub const createResource = resource_mod.create;
pub const createLocalResource = resource_mod.createLocal;
pub const Action = action_mod.Action;
pub const createAction = action_mod.create;
pub const suspense = suspense_mod.suspense;
pub const transition = suspense_mod.transition;
pub const markSuspended = suspense_mod.markSuspended;
pub const encode = serialize_mod.encode;
pub const csrf = csrf_mod;
pub const show = control_flow_mod.show;
pub const forEach = control_flow_mod.forEach;
pub const portal = control_flow_mod.portal;
pub const Slot = slot_mod.Slot;
pub const SlotMap = slot_mod.SlotMap;
pub const link = link_mod.link;
pub const LinkOpts = link_mod.LinkOpts;
pub const serverFn = @import("core/server_fn.zig").call;
pub const Store = store_mod.Store;
pub const createStore = store_mod.create;
pub const I18nCatalog = i18n_mod.Catalog;
pub const I18nEntry = i18n_mod.Entry;
pub const resolveLocale = i18n_mod.resolveLocale;
pub const ErrorBoundary = error_boundary_mod.ErrorBoundary;
pub const createErrorBoundary = error_boundary_mod.create;
pub const untrack = signal_mod.untrack;
pub const batch = signal_mod.batch;
pub const setReactivePendingAllocator = effect_mod.setPendingAllocator;
pub const setDiTablesAllocator = @import("core/context_di.zig").setOwnerTablesAllocator;
pub const Context = context_mod.Context;
pub const AssetResolver = context_mod.AssetResolver;
pub const Renderer = renderer_mod.Renderer;
pub const escapeHtml = renderer_mod.escapeHtml;
pub const RequestMeta = request_meta_mod.RequestMeta;
pub const Cookie = request_meta_mod.Cookie;
pub const Method = request_meta_mod.Method;
pub const Location = location_mod.Location;
pub const QueryPair = location_mod.QueryPair;
pub const Route = route_mod.Route;
pub const RouteSegment = route_mod.Segment;
pub const Redirect = route_mod.Redirect;
pub const RouteGuard = route_mod.Guard;

test {
    _ = node_mod;
    _ = signal_mod;
    _ = effect_mod;
    _ = owner_mod;
    _ = noderef_mod;
    _ = context_mod;
    _ = renderer_mod;
    _ = request_meta_mod;
    _ = location_mod;
    _ = route_mod;
    _ = stored_mod;
    _ = @import("core/context_di.zig");
    _ = @import("core/head.zig");
    _ = @import("core/fetch.zig");
    _ = @import("core/resource.zig");
    _ = @import("core/action.zig");
    _ = @import("core/suspense.zig");
    _ = @import("core/serialize.zig");
    _ = @import("core/csrf.zig");
    _ = @import("core/control_flow.zig");
    _ = @import("core/slot.zig");
    _ = @import("core/link.zig");
    _ = @import("core/store.zig");
    _ = @import("core/i18n.zig");
    _ = @import("core/error_boundary.zig");
    _ = @import("core/server_fn.zig");
}
