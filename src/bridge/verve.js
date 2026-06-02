// Verve JS bridge — ~50 lines of glue between DOM and wasm.
// Loaded after server-rendered HTML. Imports wasm with hand-rolled DOM helpers.

(async () => {
  let memory = null;
  const readStr = (ptr, len) =>
    new TextDecoder().decode(new Uint8Array(memory.buffer, ptr, len));

  // NodeRef handles. Index 0 is the sentinel for "not found" so wasm
  // can treat the return value as truthy/null without a separate flag.
  const refHandles = [null];

  const setTextByBind = (bind, text) => {
    document
      .querySelectorAll(`[z-bind="${CSS.escape(bind)}"]`)
      .forEach((el) => {
        el.textContent = text;
      });
  };

  const eachBind = (bind, fn) => {
    document
      .querySelectorAll(`[z-bind="${CSS.escape(bind)}"]`)
      .forEach(fn);
    // Phase 12 dual-stamps `data-vh` next to `z-bind` so the new
    // hydration walker can find the same nodes without colliding
    // with the legacy class-name selector.
    document
      .querySelectorAll(`[data-vh="${CSS.escape(bind)}"]`)
      .forEach((el) => {
        if (!el.hasAttribute("z-bind")) fn(el);
      });
  };

  const env = {
    verve: {
      set_text_by_bind: (bp, bl, tp, tl) =>
        setTextByBind(readStr(bp, bl), readStr(tp, tl)),
      set_text_by_bind_i32: (bp, bl, v) =>
        setTextByBind(readStr(bp, bl), String(v | 0)),
      post_json_i32: (pp, pl, fp, fl, v) => {
        const path = readStr(pp, pl);
        const field = readStr(fp, fl);
        fetch(path, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ [field]: v | 0 }),
        }).catch((err) => console.error("verve fetch failed:", err));
      },
      console_log_i32: (v) => console.log("verve:", v | 0),

      // ---- Phase 12 primitives ----------------------------------------
      set_attr_by_bind: (bp, bl, ap, al, vp, vl) => {
        const attr = readStr(ap, al);
        const val = readStr(vp, vl);
        eachBind(readStr(bp, bl), (el) => el.setAttribute(attr, val));
      },
      set_class_by_bind: (bp, bl, cp, cl, on) => {
        const cls = readStr(cp, cl);
        eachBind(readStr(bp, bl), (el) =>
          on ? el.classList.add(cls) : el.classList.remove(cls),
        );
      },
      set_text_by_bind_str: (bp, bl, tp, tl) =>
        eachBind(readStr(bp, bl), (el) => {
          el.textContent = readStr(tp, tl);
        }),
      set_value_by_bind: (bp, bl, vp, vl) =>
        eachBind(readStr(bp, bl), (el) => {
          el.value = readStr(vp, vl);
        }),
      remove_by_bind: (bp, bl) =>
        eachBind(readStr(bp, bl), (el) => el.remove()),

      // ---- Phase 12C: keyed-list reconciler primitives ------------------
      create_keyed_child: (pp, pl, kp, kl, hp, hl, ap, al) => {
        const parentName = readStr(pp, pl);
        const key = readStr(kp, kl);
        const html = readStr(hp, hl);
        const anchorKey = al ? readStr(ap, al) : null;
        const tpl = document.createElement("template");
        tpl.innerHTML = html;
        const node = tpl.content.firstElementChild;
        if (!node) return;
        node.setAttribute("data-vkey", key);
        eachBind(parentName, (parent) => {
          const anchor = anchorKey
            ? parent.querySelector(`[data-vkey="${CSS.escape(anchorKey)}"]`)
            : null;
          // Re-clone for each matching parent so multiple bound parents
          // don't share the same node reference.
          parent.insertBefore(node.cloneNode(true), anchor);
        });
      },
      move_keyed_child: (pp, pl, kp, kl, ap, al) => {
        const parentName = readStr(pp, pl);
        const key = readStr(kp, kl);
        const anchorKey = al ? readStr(ap, al) : null;
        eachBind(parentName, (parent) => {
          const node = parent.querySelector(
            `[data-vkey="${CSS.escape(key)}"]`,
          );
          if (!node) return;
          const anchor = anchorKey
            ? parent.querySelector(`[data-vkey="${CSS.escape(anchorKey)}"]`)
            : null;
          parent.insertBefore(node, anchor);
        });
      },
      remove_keyed_child: (pp, pl, kp, kl) => {
        const parentName = readStr(pp, pl);
        const key = readStr(kp, kl);
        eachBind(parentName, (parent) => {
          const node = parent.querySelector(
            `[data-vkey="${CSS.escape(key)}"]`,
          );
          if (node) node.remove();
        });
      },

      // ---- Phase 12G: bool + f32 primitives -----------------------------
      set_class_present_by_bind: (bp, bl, cp, cl, on) => {
        const cls = readStr(cp, cl);
        eachBind(readStr(bp, bl), (el) =>
          on ? el.classList.add(cls) : el.classList.remove(cls),
        );
      },
      set_text_by_bind_f32: (bp, bl, v) =>
        eachBind(readStr(bp, bl), (el) => {
          el.textContent = String(v);
        }),

      // ---- Phase 11B: fire-and-forget typed server-fn POST -------------
      //
      // Reply dispatch: when the wasm side has registered a response
      // handler via `verve.registerResponseHandler("<name>", &fn)`,
      // the reply body lands in shared scratch and the handler fires.
      // Replies bigger than scratch capacity drop with a warning.
      server_fn_post: (np, nl, bp, bl, rid) => {
        const name = readStr(np, nl);
        const body = readStr(bp, bl);
        const headers = { "content-type": "application/json" };
        // Correlation id for `_call` (the server echoes it in the reply so the
        // client routes the reply to the right one-shot handler). `_post` sends
        // rid 0 → no header.
        if (rid) headers["x-verve-rid"] = String(rid >>> 0);
        fetch(`/api/${name}`, {
          method: "POST",
          headers,
          body,
        })
          .then(async (resp) => {
            if (typeof exp.verve_dispatch_response !== "function") return;
            if (typeof exp.verve_island_scratch_ptr !== "function") return;
            const text = await resp.text();
            const scratchPtr = exp.verve_island_scratch_ptr();
            const scratchCap = exp.verve_island_scratch_capacity();
            const enc = new TextEncoder();
            const routeBytes = enc.encode(name);
            const bodyBytes = enc.encode(text);
            if (routeBytes.length + bodyBytes.length > scratchCap) {
              console.warn("verve server_fn_post: reply exceeds scratch", name);
              return;
            }
            const view = new Uint8Array(memory.buffer, scratchPtr, scratchCap);
            view.set(routeBytes, 0);
            view.set(bodyBytes, routeBytes.length);
            exp.verve_dispatch_response(
              scratchPtr,
              routeBytes.length,
              scratchPtr + routeBytes.length,
              bodyBytes.length,
            );
          })
          .catch((err) => console.error("verve server_fn_post failed:", err));
      },

      // ---- NodeRef resolution -----------------------------------------
      // Map `data-ref="<id>"` to a JS-owned Element handle. Index 0 is
      // reserved for "not found"; live elements get indices >=1 in the
      // module-scoped `refHandles` array.
      query_ref: (ip, il) => {
        const id = readStr(ip, il);
        const el = document.querySelector(
          `[data-ref="${CSS.escape(id)}"]`,
        );
        if (!el) return 0;
        refHandles.push(el);
        return refHandles.length - 1;
      },

      // ---- Per-handle NodeRef ops -------------------------------------
      // Each looks up `refHandles[h]`. Bad / stale handles short-circuit
      // to a no-op so wasm code doesn't crash against a hot-swapped build.
      ref_set_text: (h, tp, tl) => {
        const el = refHandles[h];
        if (el) el.textContent = readStr(tp, tl);
      },
      ref_set_text_i32: (h, v) => {
        const el = refHandles[h];
        if (el) el.textContent = String(v | 0);
      },
      ref_set_attr: (h, np, nl, vp, vl) => {
        const el = refHandles[h];
        if (el) el.setAttribute(readStr(np, nl), readStr(vp, vl));
      },
      ref_set_value: (h, vp, vl) => {
        const el = refHandles[h];
        if (el) el.value = readStr(vp, vl);
      },
      ref_set_class: (h, cp, cl, on) => {
        const el = refHandles[h];
        if (!el) return;
        const cls = readStr(cp, cl);
        if (on) el.classList.add(cls);
        else el.classList.remove(cls);
      },
      ref_focus: (h) => {
        const el = refHandles[h];
        if (el && typeof el.focus === "function") el.focus();
      },
      ref_remove: (h) => {
        const el = refHandles[h];
        if (el) el.remove();
      },
      ref_get_value_i32: (h) => {
        const el = refHandles[h];
        if (!el) return 0;
        const n = parseInt(el.value, 10);
        return Number.isFinite(n) ? n | 0 : 0;
      },
      ref_get_value_f32: (h) => {
        const el = refHandles[h];
        if (!el) return 0;
        const n = parseFloat(el.value);
        return Number.isFinite(n) ? n : 0;
      },

      // ---- Named templates (Phase 16 / G2) ----------------------------
      // `clone_template(name)` looks up `[data-vt="<name>"]`, clones
      // the prototype's content, stores the cloned root in
      // `refHandles[]`, returns the handle. Subsequent setRef* /
      // slot_text / slot_attr ops target the detached subtree; append
      // grafts it into the live DOM. Re-cloning on append lets the
      // same prototype get reused across many parents.
      clone_template: (np, nl) => {
        const name = readStr(np, nl);
        const tpl = document.querySelector(
          `[data-vt="${CSS.escape(name)}"]`,
        );
        if (!tpl || !tpl.content) return 0;
        const frag = tpl.content.cloneNode(true);
        const root = frag.firstElementChild;
        if (!root) return 0;
        refHandles.push(root);
        return refHandles.length - 1;
      },
      slot_text: (h, sp, sl, tp, tl) => {
        const root = refHandles[h];
        if (!root) return;
        const slot = readStr(sp, sl);
        const el = root.querySelector(
          `[data-vt-slot="${CSS.escape(slot)}"]`,
        );
        if (el) el.textContent = readStr(tp, tl);
      },
      slot_attr: (h, sp, sl, np, nl, vp, vl) => {
        const root = refHandles[h];
        if (!root) return;
        const slot = readStr(sp, sl);
        const el = root.querySelector(
          `[data-vt-slot="${CSS.escape(slot)}"]`,
        );
        if (el) el.setAttribute(readStr(np, nl), readStr(vp, vl));
      },
      append_to_bind: (pp, pl, h) => {
        const root = refHandles[h];
        if (!root) return;
        eachBind(readStr(pp, pl), (parent) => {
          parent.appendChild(root.cloneNode(true));
        });
      },
    },
  };

  // Exposed for hand-written JS that wants to round-trip a NodeRef.id
  // without going through wasm — e.g. inline event handlers in
  // `components.zig` raw HTML scripts. Identical lookup to the extern.
  window.verveQueryRef = (id) =>
    document.querySelector(`[data-ref="${CSS.escape(String(id))}"]`);

  // Phase 21 — generic JS-interop registry. Apps register host
  // functions here for wasm to call by name (Intl date/number
  // formatting, markdown, syntax highlight, canvas draw — the
  // unbounded long tail verve does not type natively):
  //   window.verveHost.fmtDate = (args) => new Date(args.ms).toLocaleString();
  // Each receives the JSON-parsed args object and returns a
  // JSON-serializable result (sync) or a Promise of one (async).
  window.verveHost = window.verveHost || {};

  const resp = await fetch("/client.wasm");
  const wasm = await WebAssembly.instantiateStreaming(resp, env);
  memory = wasm.instance.exports.memory;
  const exp = wasm.instance.exports;

  // Seed wasm state from server-rendered DOM. Any `verve_init_<bind>` export
  // is matched to `[z-bind="<bind>"]` and seeded with its parsed i32 text.
  for (const name of Object.keys(exp)) {
    const m = /^verve_init_(.+)$/.exec(name);
    if (!m || typeof exp[name] !== "function") continue;
    const el = document.querySelector(`[z-bind="${CSS.escape(m[1])}"]`);
    if (!el) continue;
    const n = parseInt(el.textContent, 10);
    if (!Number.isNaN(n)) exp[name](n | 0);
  }

  if (typeof exp.verve_hydrate === "function") exp.verve_hydrate();

  // Phase 14 auto-walker. Every `[data-vh-type]` element carries
  // typed-binding metadata stamped by `Node.bindI32` / `bindStr` /
  // `bindBool` / `bindF32`. Walk them after `verve_hydrate` so any
  // manually-registered slots stand first (idempotent `register*` then
  // returns the existing slot for the second registration — no
  // duplicate allocation, no clobber). Names + str initials stage
  // through the main runtime's island scratch buffer so we don't need
  // a separate string-passing extern.
  if (
    typeof exp.verve_register_i32 === "function" &&
    typeof exp.verve_island_scratch_ptr === "function" &&
    typeof exp.verve_island_scratch_capacity === "function"
  ) {
    const walkerScratchPtr = exp.verve_island_scratch_ptr();
    const walkerScratchCap = exp.verve_island_scratch_capacity();
    const enc = new TextEncoder();
    const stageOne = (s) => {
      const bytes = enc.encode(s);
      if (bytes.length > walkerScratchCap) {
        console.warn("verve auto-walker: value exceeds scratch", s);
        return null;
      }
      new Uint8Array(memory.buffer, walkerScratchPtr, walkerScratchCap).set(bytes, 0);
      return { ptr: walkerScratchPtr, len: bytes.length };
    };
    const stageTwo = (s1, s2) => {
      const b1 = enc.encode(s1);
      const b2 = enc.encode(s2);
      if (b1.length + b2.length > walkerScratchCap) {
        console.warn("verve auto-walker: combined values exceed scratch", s1, s2);
        return null;
      }
      const view = new Uint8Array(memory.buffer, walkerScratchPtr, walkerScratchCap);
      view.set(b1, 0);
      view.set(b2, b1.length);
      return {
        a: { ptr: walkerScratchPtr, len: b1.length },
        b: { ptr: walkerScratchPtr + b1.length, len: b2.length },
      };
    };
    document.querySelectorAll("[data-vh-type]").forEach((el) => {
      const name = el.getAttribute("data-vh") || el.getAttribute("z-bind");
      if (!name) return;
      const kind = el.getAttribute("data-vh-type");
      const initial = el.getAttribute("data-vh-initial") || "";
      if (kind === "i32") {
        const n = parseInt(initial, 10);
        const r = stageOne(name);
        if (r) exp.verve_register_i32(r.ptr, r.len, Number.isFinite(n) ? n | 0 : 0);
      } else if (kind === "str" && typeof exp.verve_register_str === "function") {
        const r = stageTwo(name, initial);
        if (r) exp.verve_register_str(r.a.ptr, r.a.len, r.b.ptr, r.b.len);
      } else if (kind === "bool" && typeof exp.verve_register_bool === "function") {
        const cls = el.getAttribute("data-vh-class") || "";
        const r = stageTwo(name, cls);
        if (r) exp.verve_register_bool(r.a.ptr, r.a.len, r.b.ptr, r.b.len, initial === "1" || initial === "true" ? 1 : 0);
      } else if (kind === "f32" && typeof exp.verve_register_f32 === "function") {
        const f = parseFloat(initial);
        const r = stageOne(name);
        if (r) exp.verve_register_f32(r.ptr, r.len, Number.isFinite(f) ? f : 0);
      }
    });
  }

  // Live counter sync. Prefer bidirectional WebSocket (lets +/- buttons
  // bypass the fetch-then-redirect path); fall back to Server-Sent
  // Events when WS open fails. The fallback is one-way — clicks still
  // go through wasm/post_json_i32 or the native <form> submit.
  let ws = null;
  const setCount = (raw) => {
    const v = parseInt(raw, 10);
    if (Number.isNaN(v)) return;
    // Phase 12: route counter updates through WASM so the reactive
    // graph stays authoritative. Fall back to the legacy direct DOM
    // write when the export is absent (older builds).
    if (typeof exp.verve_set_count === "function") {
      exp.verve_set_count(v);
    } else {
      setTextByBind("count", String(v));
    }
  };

  try {
    const proto = location.protocol === "https:" ? "wss:" : "ws:";
    ws = new WebSocket(`${proto}//${location.host}/ws`);
    ws.onmessage = (e) => setCount(e.data);
    ws.onerror = () => {};
    ws.onclose = () => {
      ws = null;
    };
  } catch (err) {
    console.warn("verve: WebSocket not available:", err);
    ws = null;
  }

  try {
    const es = new EventSource("/events");
    es.addEventListener("count", (e) => {
      // Only let SSE drive the count when WS isn't connected, so we
      // don't double-update on every tick.
      if (!ws || ws.readyState !== WebSocket.OPEN) setCount(e.data);
    });
    es.onerror = () => {};
  } catch (err) {
    console.warn("verve: SSE not available:", err);
  }

  const wsCounterAction = (action) => {
    if (!ws || ws.readyState !== WebSocket.OPEN) return false;
    if (action === "increment_counter") {
      ws.send("+");
      return true;
    }
    if (action === "decrement_counter") {
      ws.send("-");
      return true;
    }
    return false;
  };

  // Closure-style event dispatch. Looks for `z-on-<event>-id="<n>"`
  // on the closest ancestor of `e.target`, parses the slot id, calls
  // `verve_event_dispatch(id)`. Returns true when a handler ran so
  // the caller can decide whether to also fall through to other
  // dispatch paths.
  // Phase 18 — stage the dispatching event's data (modifiers, key,
  // pointer coords, the handler element's `dataset`) into the main
  // runtime before invoking the wasm handler, so handlers can read it
  // via the `verve_event_*` accessors. Bytes (key + dataset JSON) stage
  // through the island scratch buffer.
  const stageEvent = (e, node) => {
    if (typeof exp.verve_event_begin !== "function") return;
    exp.verve_event_begin();
    let mods = 0;
    if (e.metaKey) mods |= 1;
    if (e.ctrlKey) mods |= 2;
    if (e.shiftKey) mods |= 4;
    if (e.altKey) mods |= 8;
    exp.verve_event_set_mods(mods >>> 0);
    if (typeof e.clientX === "number") {
      exp.verve_event_set_coords(e.clientX, e.clientY);
    }
    const scratchPtr =
      typeof exp.verve_island_scratch_ptr === "function"
        ? exp.verve_island_scratch_ptr()
        : 0;
    const scratchCap = scratchPtr ? exp.verve_island_scratch_capacity() : 0;
    const enc = new TextEncoder();
    const stage = (s) => {
      if (!scratchPtr) return null;
      const b = enc.encode(s);
      if (b.length > scratchCap) return null;
      new Uint8Array(memory.buffer, scratchPtr, scratchCap).set(b, 0);
      return { ptr: scratchPtr, len: b.length };
    };
    if (e.key) {
      const r = stage(e.key);
      if (r) exp.verve_event_set_key(r.ptr, r.len);
    }
    if (node && node.dataset) {
      const ds = {};
      for (const k in node.dataset) ds[k] = node.dataset[k];
      const r = stage(JSON.stringify(ds));
      if (r) exp.verve_event_set_dataset(r.ptr, r.len);
    }
  };

  // Honor preventDefault / stopPropagation the wasm handler requested,
  // then release the staged dataset doc.
  const applyEventFlags = (e) => {
    if (typeof exp.verve_event_flags !== "function") return;
    const f = exp.verve_event_flags();
    if (f & 1) e.preventDefault();
    if (f & 2) e.stopPropagation();
    if (typeof exp.verve_event_end === "function") exp.verve_event_end();
  };

  const dispatchEventId = (e, attr, prevent) => {
    const node = e.target.closest(`[${attr}]`);
    if (!node) return false;
    const id = parseInt(node.getAttribute(attr), 10);
    if (!Number.isFinite(id)) return false;
    if (typeof exp.verve_event_dispatch !== "function") return false;
    stageEvent(e, node);
    if (prevent) e.preventDefault();
    exp.verve_event_dispatch(id >>> 0);
    applyEventFlags(e);
    return true;
  };

  document.addEventListener("click", (e) => {
    // Closure-style: `[z-on-click-id="<id>"]` → fn pointer registered
    // via `verve.registerEvent(...)`, routed through
    // `verve_event_dispatch(id)`. Wins over the string-name form when
    // both attrs land on the same node.
    if (dispatchEventId(e, "z-on-click-id", true)) return;

    const target = e.target.closest("[z-on-click]");
    if (!target) return;
    const action = target.getAttribute("z-on-click");

    if (wsCounterAction(action)) {
      e.preventDefault();
      return;
    }

    // Resolve the handler against the main client first, then any island
    // chunk's exports. Chunk handlers are exported fns called directly here
    // (no cross-module function table); they call back into the main runtime
    // via their `verve_runtime` imports. Scope the call to the enclosing
    // island's vid so name-keyed signal lookups resolve that island's signals.
    const islandEl = target.closest("verve-island");
    const islandName = islandEl ? islandEl.getAttribute("data-name") || "" : "";
    const fn =
      typeof exp[action] === "function"
        ? exp[action]
        : islandName && chunkExports[islandName]
          ? chunkExports[islandName][action]
          : undefined;
    if (typeof fn === "function") {
      e.preventDefault();
      const vid = islandEl ? parseInt(islandEl.getAttribute("data-vid"), 10) || 0 : 0;
      const scope = vid && typeof exp.verve_enter_island === "function";
      if (scope) exp.verve_enter_island(vid);
      try {
        fn();
      } finally {
        if (scope && typeof exp.verve_exit_island === "function") exp.verve_exit_island();
      }
    } else {
      console.warn("verve: no wasm export for action", action);
    }
  });

  // Delegated submit / input / change / keydown handlers. Same dispatch
  // model as click-id — handler is `fn () void`; reads incoming state
  // via `verve.refValueI32` / `refValueF32` against a co-stamped
  // NodeRef. Submit gets `preventDefault()` so the native form post
  // doesn't fire; input / change / keydown do NOT, so the native input
  // still updates and the handler runs alongside it.
  document.addEventListener("submit", (e) => {
    dispatchEventId(e, "z-on-submit-id", true);
  });
  document.addEventListener("input", (e) => {
    dispatchEventId(e, "z-on-input-id", false);
  });
  document.addEventListener("change", (e) => {
    dispatchEventId(e, "z-on-change-id", false);
  });
  document.addEventListener("keydown", (e) => {
    dispatchEventId(e, "z-on-keydown-id", false);
  });

  // ---- Phase 13: island hydration dispatch ----------------------------
  // Register `<verve-island>` so the browser stops complaining about
  // the unknown tag. The actual hydration runs in a single post-WASM
  // pass below — connectedCallback may fire before WASM is up.
  if (typeof customElements !== "undefined" && !customElements.get("verve-island")) {
    customElements.define(
      "verve-island",
      class extends HTMLElement {
        connectedCallback() {
          // SSR HTML is already inside this element; the post-hydrate
          // pass below routes any custom registration via the WASM
          // dispatch entry.
        }
      },
    );
  }

  // Island hydrate/dispose lifecycle (initial pass + MutationObserver) is
  // set up below, after `loadIslandChunk` is defined.

  // ---- Phase 13C: per-island WASM chunk loader -------------------------
  // For every `<verve-island>` marker on the page, fetch the matching
  // chunk (cached per name across the session), instantiate it, copy
  // the data-props string into the chunk's own scratch buffer, then
  // call its `hydrate` export. The main client.wasm's data-vh walker
  // has already wired reactive state inside the marker by this point —
  // the chunk hook is the place island-specific code lives.
  // Phase 13E: chunks import the main client's linear memory at
  // instantiation time so each island ships as a pure-function
  // bundle (no duplicated runtime bytes). Props strings live in
  // the main runtime's island scratch buffer — JS writes them
  // there before calling the chunk's `hydrate(ptr, len, root_id)`,
  // which then reads the bytes directly from shared memory.
  // Phase 13G — capture main runtime's exported indirect function
  // table so per-island chunks can import it. Once both modules share
  // the same table, a `*const fn () void` taken via `&handler` in a
  // chunk lands at an index the main runtime's `event_slots` can also
  // call via `verve_event_dispatch` / `call_indirect`. Without sharing
  // the table, chunk fn pointers would refer to indices in the chunk's
  // private table and crash when main dispatched them.
  const indirectFunctionTable = exp.__indirect_function_table;

  // Phase 19 — timer / storage / clipboard registry for chunk handlers.
  // Handlers cross as indirect-function-table indices (same convention
  // as `registerEvent`); `indirectFunctionTable.get(idx)` resolves the
  // funcref so JS can invoke it when the timer fires. Our own monotonic
  // ids decouple callers from the host's setTimeout/rAF handle types.
  let verveTimerSeq = 1;
  const verveTimers = new Map();
  const verveCallSlot = (idx) => {
    const fn = indirectFunctionTable.get(idx >>> 0);
    if (typeof fn === "function") {
      try {
        fn();
      } catch (err) {
        console.error("verve timer handler failed:", err);
      }
    }
  };

  // Phase 13F — assemble the chunk-side reactive-runtime import object
  // from the main client's matching exports. Built once after main
  // instantiation; reused for every island chunk. Missing entries pass
  // through as `undefined` so an older runtime + a newer chunk still
  // fails with a clear `LinkError` at instantiate time.
  const verveRuntime = {
    verve_register_i32: exp.verve_register_i32,
    verve_register_str: exp.verve_register_str,
    verve_register_bool: exp.verve_register_bool,
    verve_register_f32: exp.verve_register_f32,
    verve_signal_set_i32: exp.verve_signal_set_i32,
    verve_signal_set_str: exp.verve_signal_set_str,
    verve_signal_set_bool: exp.verve_signal_set_bool,
    verve_signal_set_f32: exp.verve_signal_set_f32,
    verve_signal_get_i32: exp.verve_signal_get_i32,
    verve_signal_get_bool: exp.verve_signal_get_bool,
    verve_signal_get_f32: exp.verve_signal_get_f32,
    verve_signal_get_str_len: exp.verve_signal_get_str_len,
    verve_signal_get_str: exp.verve_signal_get_str,
    verve_query_ref: exp.verve_query_ref,
    verve_ref_set_text: exp.verve_ref_set_text,
    verve_ref_set_text_i32: exp.verve_ref_set_text_i32,
    verve_ref_set_attr: exp.verve_ref_set_attr,
    verve_ref_set_value: exp.verve_ref_set_value,
    verve_ref_set_class: exp.verve_ref_set_class,
    verve_ref_focus: exp.verve_ref_focus,
    verve_ref_remove: exp.verve_ref_remove,
    verve_ref_get_value_i32: exp.verve_ref_get_value_i32,
    verve_ref_get_value_f32: exp.verve_ref_get_value_f32,
    verve_register_event: exp.verve_register_event,
    verve_dispatch_event: exp.verve_dispatch_event,
    verve_cleanup: exp.verve_cleanup,
    // Island resource-state blob access (chunk islandStateValue reads the
    // main client's staged blob from shared memory via these).
    verve_current_state_ptr: exp.verve_current_state_ptr,
    verve_current_state_len: exp.verve_current_state_len,
    // Phase 18 — current-event accessors for chunk handlers.
    verve_event_mods: exp.verve_event_mods,
    verve_event_coord_x: exp.verve_event_coord_x,
    verve_event_coord_y: exp.verve_event_coord_y,
    verve_event_key: exp.verve_event_key,
    verve_event_target_attr: exp.verve_event_target_attr,
    verve_event_prevent_default: exp.verve_event_prevent_default,
    verve_event_stop_propagation: exp.verve_event_stop_propagation,
    // Phase 19 — timers (handler crosses as a function-table index).
    verve_set_timeout: (ms, idx) => {
      const myId = verveTimerSeq++;
      const h = setTimeout(() => {
        verveTimers.delete(myId);
        verveCallSlot(idx);
      }, ms >>> 0);
      verveTimers.set(myId, { kind: "t", h });
      return myId >>> 0;
    },
    verve_set_interval: (ms, idx) => {
      const myId = verveTimerSeq++;
      const h = setInterval(() => verveCallSlot(idx), ms >>> 0);
      verveTimers.set(myId, { kind: "i", h });
      return myId >>> 0;
    },
    verve_request_animation_frame: (idx) => {
      const myId = verveTimerSeq++;
      const raf =
        typeof requestAnimationFrame === "function"
          ? requestAnimationFrame
          : (cb) => setTimeout(cb, 16);
      const h = raf(() => {
        verveTimers.delete(myId);
        verveCallSlot(idx);
      });
      verveTimers.set(myId, { kind: "r", h });
      return myId >>> 0;
    },
    verve_queue_microtask: (idx) => {
      queueMicrotask(() => verveCallSlot(idx));
    },
    verve_clear_timer: (id) => {
      const t = verveTimers.get(id >>> 0);
      if (!t) return;
      verveTimers.delete(id >>> 0);
      if (t.kind === "t") clearTimeout(t.h);
      else if (t.kind === "i") clearInterval(t.h);
      else if (t.kind === "r" && typeof cancelAnimationFrame === "function")
        cancelAnimationFrame(t.h);
    },
    // Phase 19 — localStorage (string values; len-probe then copy).
    verve_storage_len: (kp, kl) => {
      try {
        const v = localStorage.getItem(readStr(kp, kl));
        return v == null ? 0 : new TextEncoder().encode(v).length;
      } catch {
        return 0;
      }
    },
    verve_storage_get: (kp, kl, bp, bc) => {
      try {
        const v = localStorage.getItem(readStr(kp, kl));
        if (v == null) return 0;
        const b = new TextEncoder().encode(v);
        const n = Math.min(b.length, bc >>> 0);
        new Uint8Array(memory.buffer, bp, n).set(b.subarray(0, n));
        return n;
      } catch {
        return 0;
      }
    },
    verve_storage_set: (kp, kl, vp, vl) => {
      try {
        localStorage.setItem(readStr(kp, kl), readStr(vp, vl));
      } catch (err) {
        console.warn("verve storage set failed:", err);
      }
    },
    verve_storage_remove: (kp, kl) => {
      try {
        localStorage.removeItem(readStr(kp, kl));
      } catch {}
    },
    // Phase 20 — forms + DOM measurement (operate on `refHandles[h]`).
    verve_ref_get_value_str: (h, bp, bc) => {
      const el = refHandles[h];
      if (!el) return 0;
      const b = new TextEncoder().encode(String(el.value ?? ""));
      const n = Math.min(b.length, bc >>> 0);
      new Uint8Array(memory.buffer, bp, n).set(b.subarray(0, n));
      return n;
    },
    verve_ref_request_submit: (h) => {
      const el = refHandles[h];
      if (el && el.form && typeof el.form.requestSubmit === "function") {
        el.form.requestSubmit();
      } else if (el && typeof el.requestSubmit === "function") {
        el.requestSubmit();
      }
    },
    verve_ref_select: (h) => {
      const el = refHandles[h];
      if (el && typeof el.select === "function") el.select();
    },
    verve_ref_blur: (h) => {
      const el = refHandles[h];
      if (el && typeof el.blur === "function") el.blur();
    },
    verve_ref_rect: (h, out) => {
      const dv = new Float64Array(memory.buffer, out, 4);
      const el = refHandles[h];
      if (!el || typeof el.getBoundingClientRect !== "function") {
        dv[0] = dv[1] = dv[2] = dv[3] = 0;
        return;
      }
      const r = el.getBoundingClientRect();
      dv[0] = r.x;
      dv[1] = r.y;
      dv[2] = r.width;
      dv[3] = r.height;
    },
    verve_ref_scroll_into_view: (h) => {
      const el = refHandles[h];
      if (el && typeof el.scrollIntoView === "function") {
        el.scrollIntoView({ block: "nearest" });
      }
    },
    verve_viewport: (out) => {
      const dv = new Float64Array(memory.buffer, out, 2);
      dv[0] = window.innerWidth || 0;
      dv[1] = window.innerHeight || 0;
    },
    verve_match_media: (qp, ql) => {
      try {
        return window.matchMedia(readStr(qp, ql)).matches ? 1 : 0;
      } catch {
        return 0;
      }
    },
    verve_form_collect: (bp, bl, bufp, bufc) => {
      const bind = readStr(bp, bl);
      let form =
        document.querySelector(`[z-bind="${CSS.escape(bind)}"]`) ||
        document.querySelector(`[data-vh="${CSS.escape(bind)}"]`);
      if (form && form.tagName !== "FORM") {
        form = form.closest("form") || form.querySelector("form") || form;
      }
      const out = {};
      if (form && form.elements) {
        for (const el of form.elements) {
          if (!el.name) continue;
          if (el.type === "checkbox") out[el.name] = el.checked;
          else if (el.type === "radio") {
            if (el.checked) out[el.name] = el.value;
          } else out[el.name] = el.value;
        }
      }
      const b = new TextEncoder().encode(JSON.stringify(out));
      const n = Math.min(b.length, bufc >>> 0);
      new Uint8Array(memory.buffer, bufp, n).set(b.subarray(0, n));
      return n;
    },
    // Phase 21 — generic JS interop. `verve_host_call` is synchronous
    // (host fn must return a JSON-serializable value, not a Promise);
    // `verve_host_call_async` fans the resolved result back through the
    // response-handler path so it reads like a server-fn reply.
    verve_host_call: (np, nl, ap, al, op, oc) => {
      const fn = window.verveHost[readStr(np, nl)];
      if (typeof fn !== "function") return 0;
      let args;
      try {
        args = al ? JSON.parse(readStr(ap, al)) : undefined;
      } catch {
        return 0;
      }
      let out;
      try {
        const result = fn(args);
        out = JSON.stringify(result === undefined ? null : result);
      } catch (err) {
        console.error("verve host call failed:", err);
        return 0;
      }
      const b = new TextEncoder().encode(out);
      const n = Math.min(b.length, oc >>> 0);
      new Uint8Array(memory.buffer, op, n).set(b.subarray(0, n));
      return n;
    },
    verve_host_call_async: (np, nl, ap, al, rp, rl) => {
      const name = readStr(np, nl);
      const route = readStr(rp, rl);
      const fn = window.verveHost[name];
      if (typeof fn !== "function") return;
      let args;
      try {
        args = al ? JSON.parse(readStr(ap, al)) : undefined;
      } catch {
        return;
      }
      Promise.resolve()
        .then(() => fn(args))
        .then((result) => {
          if (
            typeof exp.verve_dispatch_response !== "function" ||
            typeof exp.verve_island_scratch_ptr !== "function"
          )
            return;
          const text = JSON.stringify(result === undefined ? null : result);
          const scratchPtr = exp.verve_island_scratch_ptr();
          const scratchCap = exp.verve_island_scratch_capacity();
          const enc = new TextEncoder();
          const routeBytes = enc.encode(route);
          const bodyBytes = enc.encode(text);
          if (routeBytes.length + bodyBytes.length > scratchCap) {
            console.warn("verve host async reply exceeds scratch", name);
            return;
          }
          const view = new Uint8Array(memory.buffer, scratchPtr, scratchCap);
          view.set(routeBytes, 0);
          view.set(bodyBytes, routeBytes.length);
          exp.verve_dispatch_response(
            scratchPtr,
            routeBytes.length,
            scratchPtr + routeBytes.length,
            bodyBytes.length,
          );
        })
        .catch((err) => console.error("verve host async failed:", name, err));
    },
    // Phase 19 — clipboard (async API, execCommand fallback for WKWebView).
    verve_clipboard_write: (tp, tl) => {
      const text = readStr(tp, tl);
      try {
        if (navigator.clipboard && navigator.clipboard.writeText) {
          navigator.clipboard.writeText(text).catch(() => {});
          return;
        }
      } catch {}
      try {
        const ta = document.createElement("textarea");
        ta.value = text;
        document.body.appendChild(ta);
        ta.select();
        document.execCommand("copy");
        ta.remove();
      } catch (err) {
        console.warn("verve clipboard write failed:", err);
      }
    },
    verve_list_diff: exp.verve_list_diff,
    verve_register_response_handler: exp.verve_register_response_handler,
    verve_dispatch_response: exp.verve_dispatch_response,
    // Phase 17 — outbound typed POST + shared JSON value service.
    verve_server_fn_post: exp.verve_server_fn_post,
    verve_json_parse: exp.verve_json_parse,
    verve_json_free: exp.verve_json_free,
    verve_json_get: exp.verve_json_get,
    verve_json_at: exp.verve_json_at,
    verve_json_len: exp.verve_json_len,
    verve_json_kind: exp.verve_json_kind,
    verve_json_i64: exp.verve_json_i64,
    verve_json_f64: exp.verve_json_f64,
    verve_json_bool: exp.verve_json_bool,
    verve_json_str_len: exp.verve_json_str_len,
    verve_json_str: exp.verve_json_str,
    // Phase 22 — chunk arena + drag-drop.
    verve_chunk_alloc: exp.verve_chunk_alloc,
    verve_chunk_arena_mark: exp.verve_chunk_arena_mark,
    verve_chunk_arena_reset: exp.verve_chunk_arena_reset,
    verve_drop_name: exp.verve_drop_name,
    verve_drop_name_len: exp.verve_drop_name_len,
    verve_drop_ptr: exp.verve_drop_ptr,
    verve_drop_len: exp.verve_drop_len,
    verve_register_drop: (bp, bl, idx) => {
      const bind = readStr(bp, bl);
      const target =
        document.querySelector(`[z-bind="${CSS.escape(bind)}"]`) ||
        document.querySelector(`[data-vh="${CSS.escape(bind)}"]`);
      if (!target) return;
      target.addEventListener("dragover", (e) => e.preventDefault());
      target.addEventListener("drop", async (e) => {
        e.preventDefault();
        const file =
          e.dataTransfer && e.dataTransfer.files && e.dataTransfer.files[0];
        if (!file || typeof exp.verve_chunk_alloc !== "function") return;
        let bytes;
        try {
          bytes = new Uint8Array(await file.arrayBuffer());
        } catch {
          return;
        }
        const dataPtr = exp.verve_chunk_alloc(bytes.length >>> 0, 1);
        if (!dataPtr) {
          console.warn("verve drop: arena full", file.name);
          return;
        }
        new Uint8Array(memory.buffer, dataPtr, bytes.length).set(bytes);
        const nameBytes = new TextEncoder().encode(file.name);
        const scratchPtr = exp.verve_island_scratch_ptr();
        const scratchCap = exp.verve_island_scratch_capacity();
        const nlen = Math.min(nameBytes.length, scratchCap);
        new Uint8Array(memory.buffer, scratchPtr, scratchCap).set(
          nameBytes.subarray(0, nlen),
        );
        exp.verve_drop_set(scratchPtr, nlen, dataPtr, bytes.length >>> 0);
        verveCallSlot(idx);
      });
    },
    verve_clone_template: exp.verve_clone_template,
    verve_slot_text: exp.verve_slot_text,
    verve_slot_attr: exp.verve_slot_attr,
    verve_append_to_bind: exp.verve_append_to_bind,
    verve_slot_count: exp.verve_slot_count,
    verve_slot_capacity: exp.verve_slot_capacity,
    verve_event_slot_count: exp.verve_event_slot_count,
    verve_event_slot_capacity: exp.verve_event_slot_capacity,
    verve_slot_name: exp.verve_slot_name,
    verve_slot_kind: exp.verve_slot_kind,
  };

  // Each `<verve-island>` carries a server-assigned `data-vid` — the
  // single per-instance id, passed to its chunk's
  // `hydrate(props_ptr, props_len, vid)` and used as the wasm per-island
  // owner-scope key.

  // `data-props` carries base64 of the binary props codec (serialize.zig).
  // Decode to raw bytes before staging into the wasm scratch; empty/invalid
  // props stage to zero bytes.
  const b64ToBytes = (s) => {
    if (!s) return new Uint8Array(0);
    try {
      const bin = atob(s);
      const bytes = new Uint8Array(bin.length);
      for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
      return bytes;
    } catch {
      return new Uint8Array(0);
    }
  };

  const islandChunks = new Map();
  // Exported handler fns from loaded island chunks, keyed by island `data-name`
  // then by export name, so `z-on-click="<name>"` on an island's markup reaches
  // *that* island's chunk handler. Nesting by island name prevents two
  // different components that export the same handler name from colliding
  // (dispatch scopes the lookup to the click target's enclosing island).
  const chunkExports = {};
  const loadIslandChunk = async (el, instanceId) => {
    const name = el.getAttribute("data-name") || "";
    if (!name) return;
    const url = `/islands/${name}.wasm`;
    if (!islandChunks.has(name)) {
      islandChunks.set(
        name,
        WebAssembly.instantiateStreaming(fetch(url), {
          env: {
            memory,
            __indirect_function_table: indirectFunctionTable,
          },
          verve_runtime: verveRuntime,
        }).catch((err) => {
          islandChunks.delete(name);
          console.warn("verve: island chunk fetch failed", name, err);
          return null;
        }),
      );
    }
    const chunk = await islandChunks.get(name);
    if (!chunk) return;
    const cexp = chunk.instance.exports;
    if (typeof cexp.hydrate !== "function") return;
    // Register this chunk's exported handlers (everything callable except the
    // hydrate entry) under this island's name so `z-on-click="<name>"` can
    // dispatch to them, scoped to this component.
    const handlers = chunkExports[name] || (chunkExports[name] = {});
    for (const k of Object.keys(cexp)) {
      if (k !== "hydrate" && typeof cexp[k] === "function") handlers[k] = cexp[k];
    }
    const props = el.getAttribute("data-props") || "";
    // Re-stage THIS island's resource-state blob now: chunk load is async, so
    // another island's hydrate may have overwritten the shared current blob
    // since hydrateIslandEl ran. `verve_current_state_ptr/_len` (read by the
    // chunk's islandStateValue) must reflect this island.
    stageIslandState(instanceId);
    // Scope the chunk's register*/registerEvent/cleanup under this island's vid
    // owner so per-island unmount disposes them.
    const scope = typeof exp.verve_enter_island === "function";
    if (scope) exp.verve_enter_island(instanceId);
    try {
      if (
        typeof exp.verve_island_scratch_ptr === "function" &&
        typeof exp.verve_island_scratch_capacity === "function"
      ) {
        const ptr = exp.verve_island_scratch_ptr();
        const cap = exp.verve_island_scratch_capacity();
        const propsBytes = b64ToBytes(props);
        if (propsBytes.length > cap) {
          console.warn("verve: island props exceed shared scratch", name);
          return;
        }
        new Uint8Array(memory.buffer, ptr, cap).set(propsBytes, 0);
        cexp.hydrate(ptr, propsBytes.length, instanceId);
      } else {
        cexp.hydrate(0, 0, instanceId);
      }
    } finally {
      if (scope && typeof exp.verve_exit_island === "function") exp.verve_exit_island();
    }
  };
  // ---- Per-island hydrate/dispose lifecycle ---------------------------
  // A MutationObserver hydrates each `<verve-island>` on insertion (initial
  // load, mid-page conditional mounts, and post-SPA-nav body swaps) and
  // disposes its wasm scope on removal, keyed by the server's `data-vid`.
  const hydratedIslands = new WeakSet();

  // Per-page island resource-state map: vid -> Uint8Array(blob). Parsed from
  // the `<script type="application/verve-state">` the server emits, re-parsed
  // after each SPA body swap (the new document carries its own state script).
  let islandState = {};
  const parseIslandState = () => {
    islandState = {};
    const tag = document.querySelector('script[type="application/verve-state"]');
    if (!tag || !tag.textContent.trim()) return;
    let map;
    try {
      map = JSON.parse(tag.textContent);
    } catch {
      return;
    }
    for (const k of Object.keys(map)) {
      try {
        const bin = atob(map[k]);
        const bytes = new Uint8Array(bin.length);
        for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
        islandState[k] = bytes;
      } catch {}
    }
  };

  // Copy the island's serialized state blob into the wasm side BEFORE staging
  // name/props (both use the same scratch buffer; the wasm copies the blob out
  // on `verve_set_island_state`, so a later props write can't corrupt it).
  const stageIslandState = (vid) => {
    if (typeof exp.verve_set_island_state !== "function") return;
    const bytes = islandState[String(vid)];
    if (!bytes) {
      exp.verve_set_island_state(0); // clear any stale blob
      return;
    }
    const sp = exp.verve_island_scratch_ptr();
    const cap = exp.verve_island_scratch_capacity();
    if (sp && bytes.length <= cap) {
      new Uint8Array(memory.buffer, sp, cap).set(bytes, 0);
      exp.verve_set_island_state(bytes.length);
    } else {
      exp.verve_set_island_state(0);
    }
  };

  const hydrateIslandEl = (el) => {
    if (hydratedIslands.has(el)) return;
    hydratedIslands.add(el);
    const vid = parseInt(el.getAttribute("data-vid"), 10) || 0;
    const name = el.getAttribute("data-name") || "";
    const props = el.getAttribute("data-props") || "";
    stageIslandState(vid);
    if (typeof exp.verve_island_dispatch_v === "function") {
      const scratchPtr = exp.verve_island_scratch_ptr();
      const scratchCap = exp.verve_island_scratch_capacity();
      if (scratchPtr && scratchCap) {
        const enc = new TextEncoder();
        const nameBytes = enc.encode(name);
        const propsBytes = b64ToBytes(props);
        if (nameBytes.length + propsBytes.length <= scratchCap) {
          const view = new Uint8Array(memory.buffer, scratchPtr, scratchCap);
          view.set(nameBytes, 0);
          view.set(propsBytes, nameBytes.length);
          exp.verve_island_dispatch_v(nameBytes.length, propsBytes.length, vid);
        } else {
          console.warn("verve: island payload exceeds scratch buffer", name);
        }
      }
    }
    loadIslandChunk(el, vid).catch(() => {});
  };

  const unmountIslandEl = (el) => {
    if (!hydratedIslands.has(el)) return;
    hydratedIslands.delete(el);
    const vid = parseInt(el.getAttribute("data-vid"), 10) || 0;
    if (vid && typeof exp.verve_unmount_island === "function") {
      exp.verve_unmount_island(vid);
    }
  };

  const eachIslandIn = (node, fn) => {
    if (!(node instanceof Element)) return;
    if (node.tagName === "VERVE-ISLAND") fn(node);
    if (node.querySelectorAll) node.querySelectorAll("verve-island").forEach(fn);
  };

  parseIslandState();
  document.querySelectorAll("verve-island").forEach(hydrateIslandEl);

  new MutationObserver((records) => {
    for (const rec of records) {
      rec.removedNodes.forEach((n) => eachIslandIn(n, unmountIslandEl));
      rec.addedNodes.forEach((n) => eachIslandIn(n, hydrateIslandEl));
    }
  }).observe(document.body, { childList: true, subtree: true });

  // ---- Phase 14: out-of-order Suspense swap ---------------------------
  // Each parked Suspense boundary renders as
  //   <div data-vs="N">{fallback}</div>
  // in the shell, and the server eventually emits
  //   <template id="verve-vs-N">{real content}</template>
  //   <script nonce=…>verveSwap(N)</script>
  // when the resource resolves. The helper here unwraps the template
  // and grafts its content in place of the fallback div. Reactive
  // state on surrounding nodes stays put — the swap only touches the
  // single placeholder element.
  window.verveSwap = (id) => {
    const placeholder = document.querySelector(`[data-vs="${id}"]`);
    if (!placeholder) return;
    const tpl = document.getElementById(`verve-vs-${id}`);
    if (!tpl || tpl.tagName !== "TEMPLATE") return;
    const frag = tpl.content.cloneNode(true);
    placeholder.replaceWith(frag);
    tpl.remove();
    // Pick up any new `data-vh` markers introduced by the swap so the
    // reactive runtime sees them on the next signal tick.
    if (typeof exp !== "undefined" && typeof exp.verve_hydrate === "function") {
      try { exp.verve_hydrate(); } catch (_) {}
    }
  };

  // ---- Server Functions ------------------------------------------------
  // Generic JS-side caller for app.Actions endpoints. `name` matches
  // the function declared in `app.Actions`; `args` is a plain object
  // serialized as JSON. The browser automatically sends the CSRF
  // cookie alongside same-origin requests; the form-CSRF check on
  // the server only applies to form posts, so JSON server-fn calls
  // bypass it (the threat model is XSS-injected forms, which the
  // SameSite=Strict cookie also defends against).
  window.verveServerFn = async (name, args) => {
    const resp = await fetch(`/api/${name}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(args || {}),
    });
    if (!resp.ok) {
      throw new Error(`verveServerFn ${name} ${resp.status}`);
    }
    const json = await resp.json();
    if (Object.prototype.hasOwnProperty.call(json, "value")) return json.value;
    if (Object.prototype.hasOwnProperty.call(json, "ok")) return json.ok;
    return json;
  };

  // ---- SPA router ------------------------------------------------------
  // Delegated click handler intercepts <a data-vlink="1"> anchors. The
  // target HTML is fetched, parsed, and grafted into the current
  // document: <head> merge (title + meta + link + script) plus body
  // replacement. History API integration keeps back/forward working.

  const isModifiedClick = (e) =>
    e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey;

  const sameOrigin = (url) => {
    try {
      return new URL(url, location.href).origin === location.origin;
    } catch {
      return false;
    }
  };

  const swapDocument = (html, targetUrl) => {
    const doc = new DOMParser().parseFromString(html, "text/html");
    if (doc.title) document.title = doc.title;
    // Merge <head>: replace meta/link nodes by name/property/rel.
    const headChildren = Array.from(doc.head.children);
    for (const node of headChildren) {
      if (node.tagName === "TITLE") continue; // handled above
      if (node.tagName === "META") {
        const key =
          node.getAttribute("name") || node.getAttribute("property");
        if (key) {
          const sel = node.getAttribute("name")
            ? `meta[name="${CSS.escape(key)}"]`
            : `meta[property="${CSS.escape(key)}"]`;
          const existing = document.head.querySelector(sel);
          if (existing) existing.replaceWith(node.cloneNode(true));
          else document.head.appendChild(node.cloneNode(true));
          continue;
        }
      }
      if (node.tagName === "LINK") {
        const rel = node.getAttribute("rel");
        if (rel) {
          const existing = document.head.querySelector(
            `link[rel="${CSS.escape(rel)}"]`
          );
          if (existing) existing.replaceWith(node.cloneNode(true));
          else document.head.appendChild(node.cloneNode(true));
          continue;
        }
      }
      // Fallback: append as-is (json-ld scripts, etc).
      document.head.appendChild(node.cloneNode(true));
    }
    // Dispose the outgoing route's reactive scope BEFORE its DOM is
    // dropped, so per-route signals/effects/refHandles are reclaimed and
    // DOM-touching cleanups still see live nodes. Guarded so older wasm
    // builds (no export) degrade gracefully.
    if (exp && typeof exp.verve_unmount_route === "function") {
      exp.verve_unmount_route();
    }
    // Body content swap (preserves outer <body> so scripts don't re-run).
    document.body.innerHTML = doc.body.innerHTML;
    // Re-parse the new document's island state script synchronously, before
    // the MutationObserver's async callback hydrates the swapped-in islands.
    parseIslandState();
  };

  const navigate = async (href, opts) => {
    opts = opts || {};
    try {
      const resp = await fetch(href, {
        headers: { "x-verve-spa": "1" },
        redirect: "follow",
      });
      if (!resp.ok && resp.status !== 304) {
        location.href = href;
        return;
      }
      const html = await resp.text();
      swapDocument(html, href);
      if (!opts.replace) history.pushState({ verve: true }, "", href);
      if (opts.scrollTop !== false) window.scrollTo({ top: 0, behavior: "instant" });
    } catch (err) {
      console.warn("verve: SPA fetch failed, falling back to full load:", err);
      location.href = href;
    }
  };

  document.addEventListener("click", (e) => {
    if (isModifiedClick(e)) return;
    const anchor = e.target.closest("a[data-vlink]");
    if (!anchor) return;
    const href = anchor.getAttribute("href");
    if (!href || href.startsWith("#")) return;
    if (anchor.target === "_blank") return;
    if (!sameOrigin(href)) return;
    e.preventDefault();
    navigate(href, {});
  });

  // Optional prefetch-on-hover for marked anchors. Hits the server once
  // per unique URL the user pauses on; results are simply discarded
  // (the browser cache picks them up on actual navigation).
  const prefetched = new Set();
  document.addEventListener(
    "mouseover",
    (e) => {
      const anchor = e.target.closest("a[data-vlink][data-vprefetch=\"hover\"]");
      if (!anchor) return;
      const href = anchor.getAttribute("href");
      if (!href || prefetched.has(href) || !sameOrigin(href)) return;
      prefetched.add(href);
      fetch(href, { method: "GET", headers: { "x-verve-prefetch": "1" } }).catch(() => {});
    },
    { passive: true }
  );

  window.addEventListener("popstate", () => {
    // Back/forward navigation. We can't replay history.pushState here
    // — the browser already restored the URL — so issue a fresh fetch
    // for the current location.
    navigate(location.pathname + location.search + location.hash, {
      replace: true,
      scrollTop: false,
    });
  });
})();
