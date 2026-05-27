//! Public façade for the wasm32-freestanding client runtime.
//!
//! Pure re-export surface. Downstream apps (e.g. the desktop template
//! scaffold) get `Signal` / `Effect` / `Owner` from the core reactive
//! graph plus the DOM-wired `registerI32` / `registerStr` / `bindForEach`
//! adapter — `Signal.set` drives DOM mutations through `on_set`. Same
//! integration shape the main repo's own `client.wasm` uses.
//!
//! Target-agnostic: every dep already compiles for both host (so the
//! native-target unit tests participate in `zig build test`) and
//! wasm32-freestanding (where `dom.zig`'s extern declarations resolve
//! against the bridge JS).

const verve = @import("verve");
const runtime = @import("runtime.zig");
const scratch_mod = @import("scratch.zig");
const allocator_mod = @import("allocator.zig");

// ---- Reactive primitives (re-exported from core via the verve module) -----

pub const Signal = verve.Signal;
pub const Effect = verve.Effect;
pub const Owner = verve.Owner;
pub const createEffect = verve.createEffect;
pub const untrack = verve.untrack;
pub const batch = verve.batch;
pub const setReactivePendingAllocator = verve.setReactivePendingAllocator;

// ---- Server functions / actions ------------------------------------------
//
// Action wraps an imperative async operation in a reactive struct
// (pending / value / input / version Signals). serverFnGen.post() on
// wasm32 serializes args to JSON and fires the `server_fn_post` extern
// the bridge JS exposes — see `src/bridge/verve.js`.

pub const Action = verve.Action;
pub const createAction = verve.createAction;
pub const serverFn = verve.serverFn;
pub const serverFnGen = verve.serverFnGen;

// ---- Async resources -----------------------------------------------------
//
// Resource holds a `Signal(ResourceState(T))` where the union is
// `loading | ready(T) | err(anyerror)`. `createLocalResource` is the
// client-only variant (currently a pass-through to `createResource`).

pub const Resource = verve.Resource;
pub const ResourceState = verve.ResourceState;
pub const createResource = verve.createResource;
pub const createLocalResource = verve.createLocalResource;

// ---- Field-grained reactivity --------------------------------------------
//
// Store(T) gives each field of T its own Signal so reads via `.get(.field)`
// subscribe to that field only — finer granularity than wrapping the
// whole struct in a single Signal.

pub const Store = verve.Store;
pub const createStore = verve.createStore;

// ---- Error boundary ------------------------------------------------------

pub const ErrorBoundary = verve.ErrorBoundary;
pub const createErrorBoundary = verve.createErrorBoundary;

// ---- NodeRef -------------------------------------------------------------
//
// `NodeRef(.tag)` is the server-side handle stamped via `Node.ref(...)`
// onto a rendered element as `data-ref="<id>"`. After hydration,
// `queryRef(ref)` returns a JS-owned handle the caller can keep around
// for future per-handle mutation externs (those land in a later bundle).

pub const NodeRef = verve.NodeRef;
pub const NodeRefTag = verve.NodeRefTag;
pub const queryRef = runtime.queryRef;

// ---- Per-handle NodeRef ops ---------------------------------------------
//
// Use the handle returned from `queryRef(ref)` to mutate or read the
// live element. Out-of-range / stale handles are silently ignored at
// the bridge — keeps wasm-side code resilient to a hot-swapped build.

pub const setRefText = runtime.setRefText;
pub const setRefTextI32 = runtime.setRefTextI32;
pub const setRefAttr = runtime.setRefAttr;
pub const setRefValue = runtime.setRefValue;
pub const setRefClass = runtime.setRefClass;
pub const focusRef = runtime.focusRef;
pub const removeRef = runtime.removeRef;
pub const refValueI32 = runtime.refValueI32;
pub const refValueF32 = runtime.refValueF32;

// ---- Declarative hydration -----------------------------------------------
//
// `autoHydrate(bindings)` batches register* calls behind a single
// declarative slice. Mixes i32 / str / bool / f32 entries freely; the
// union tag on `Binding.initial` picks the right registrar. Initial
// values still come from the caller — the bridge's existing
// `verve_init_<name>(value)` walker captures DOM-seeded values into
// module-level vars that get fed in here.

pub const Binding = runtime.Binding;
pub const BindingInitial = runtime.BindingInitial;
pub const autoHydrate = runtime.autoHydrate;

// ---- Closure-style event handlers ----------------------------------------
//
// Alternative to the string-named `[z-on-click="exportName"]` dispatch:
// `registerEvent(fn)` returns a u32 slot id; pass it to
// `Node.onClickFn(id)` at render time. The bridge JS click delegate
// routes `[z-on-click-id="<id>"]` through `verve_event_dispatch(id)`,
// which invokes the registered fn pointer — handler runs in WASM with
// whatever state it captured at registration.

pub const registerEvent = runtime.registerEvent;
pub const dispatchEvent = runtime.dispatchEvent;

// ---- DOM-wired adapter (from src/client/runtime.zig) ----------------------

pub const registerI32 = runtime.registerI32;
pub const registerStr = runtime.registerStr;
pub const registerBool = runtime.registerBool;
pub const registerF32 = runtime.registerF32;
pub const signalI32 = runtime.signalI32;
pub const signalStr = runtime.signalStr;
pub const signalBool = runtime.signalBool;
pub const signalF32 = runtime.signalF32;
pub const registerForEach = runtime.registerForEach;
pub const bindForEach = runtime.bindForEach;
pub const applyReconcile = runtime.applyReconcile;
pub const ForEachHandle = runtime.ForEachHandle;
pub const ForEachData = runtime.ForEachData;
pub const ensureOwner = runtime.ensureOwner;
pub const resetForTesting = runtime.resetForTesting;

// ---- Introspection (debugging / smoke harness) ----------------------------

pub const scratch = struct {
    pub const reset = scratch_mod.reset;
    pub const bytesUsed = scratch_mod.bytesUsed;
    pub const capacity = scratch_mod.capacityBytes;
};

pub const heap = struct {
    pub const reset = allocator_mod.reset;
    pub const bytesUsed = allocator_mod.bytesUsed;
    pub const capacity = allocator_mod.capacity;
};

// Force the chunk-callable wrapper surface into downstream wasm clients
// so the bridge's Phase-14 auto-walker can call `verve_register_*` on
// them too. Same pattern the main client uses internally. On host-target
// test builds these become regular C-ABI symbols — harmless.
comptime {
    _ = @import("runtime_exports.zig");
}

test {
    _ = runtime;
    _ = scratch_mod;
    _ = allocator_mod;
}
