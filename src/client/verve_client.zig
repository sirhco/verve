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

test {
    _ = runtime;
    _ = scratch_mod;
    _ = allocator_mod;
}
