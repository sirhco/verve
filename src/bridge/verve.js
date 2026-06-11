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

  // Table isolation: the main client IMPORTS its indirect function table
  // from JS (build.zig sets `import_table` on the client) so JS owns a
  // GROWABLE table. Island chunks no longer share it — each chunk gets a
  // private table (see the chunk loader), and any fn-pointer index a chunk
  // hands the main runtime is translated into a freshly grown slot here.
  // Before this, chunk element segments wrote into the shared table at the
  // same slots as the main client's own entries — "function signature
  // mismatch" crashes whenever a chunk's address-taken set grew.
  const indirectFunctionTable = new WebAssembly.Table({
    initial: 256,
    element: "anyfunc",
  });

  const env = {
    env: { __indirect_function_table: indirectFunctionTable },
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
        const SVG_NS = "http://www.w3.org/2000/svg";
        // Build the element in the parent's namespace. SVG fragments parsed via
        // `template.innerHTML` land in the HTML namespace and won't render —
        // parse them as SVG instead. Re-parse per parent so each bound parent
        // gets its own node.
        const make = (parent) => {
          const inSvg = parent.namespaceURI === SVG_NS || !!parent.closest("svg");
          let node;
          if (inSvg) {
            const doc = new DOMParser().parseFromString(
              '<svg xmlns="' + SVG_NS + '">' + html + "</svg>",
              "image/svg+xml",
            );
            const first =
              doc.documentElement && doc.documentElement.firstElementChild;
            if (!first || doc.querySelector("parsererror")) return null;
            node = document.importNode(first, true);
          } else {
            const tpl = document.createElement("template");
            tpl.innerHTML = html;
            const f = tpl.content.firstElementChild;
            if (!f) return null;
            node = f.cloneNode(true);
          }
          node.setAttribute("data-vkey", key);
          return node;
        };
        eachBind(parentName, (parent) => {
          const node = make(parent);
          if (!node) return;
          const anchor = anchorKey
            ? parent.querySelector(`[data-vkey="${CSS.escape(anchorKey)}"]`)
            : null;
          parent.insertBefore(node, anchor);
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
    (typeof exp.verve_island_scratch_ptr !== "function" ||
      typeof exp.verve_island_scratch_capacity !== "function")
  ) {
    console.warn(
      "verve: binding walker skipped — verve_island_scratch_ptr/" +
        "_capacity not exported; [data-vh] bindings will be inert",
    );
  }
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
    if (typeof e.deltaY === "number" && typeof exp.verve_event_set_scroll === "function") {
      exp.verve_event_set_scroll(e.deltaY);
    }
    if (typeof e.button === "number" && typeof exp.verve_event_set_button === "function") {
      exp.verve_event_set_button(e.button | 0);
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
    if (f & 4) {
      // Pointer capture: keep routing move/up to this target after the
      // pointer leaves it. Implicit release on pointerup per spec.
      try {
        e.target.setPointerCapture(e.pointerId);
      } catch {}
    }
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

  // Named-export dispatch for `z-on-<event>="<name>"` — the form island chunks
  // use (mirrors the click handler's named path). Resolves the export on the
  // main client first, then the enclosing island's chunk, scoping to its vid.
  const dispatchEventName = (e, attr, prevent) => {
    const target = e.target.closest(`[${attr}]`);
    if (!target) return false;
    const action = target.getAttribute(attr);
    const islandEl = target.closest("verve-island");
    const islandName = islandEl ? islandEl.getAttribute("data-name") || "" : "";
    const fn =
      typeof exp[action] === "function"
        ? exp[action]
        : islandName && chunkExports[islandName]
          ? chunkExports[islandName][action]
          : undefined;
    if (typeof fn !== "function") return false;
    stageEvent(e, target);
    if (prevent) e.preventDefault();
    const vid = islandEl ? parseInt(islandEl.getAttribute("data-vid"), 10) || 0 : 0;
    const scope = vid && typeof exp.verve_enter_island === "function";
    if (scope) exp.verve_enter_island(vid);
    try {
      fn();
    } finally {
      if (scope && typeof exp.verve_exit_island === "function") exp.verve_exit_island();
    }
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
      // Stage the event data (coords, modifiers, and the handler element's
      // dataset) so the wasm handler can read it via `verve_event_*` —
      // e.g. `eventTargetAttr("node")`. Pointer events stage via
      // dispatchEventName; this named-click path must too.
      stageEvent(e, target);
      const vid = islandEl ? parseInt(islandEl.getAttribute("data-vid"), 10) || 0 : 0;
      const scope = vid && typeof exp.verve_enter_island === "function";
      if (scope) exp.verve_enter_island(vid);
      try {
        fn();
      } finally {
        if (scope && typeof exp.verve_exit_island === "function") exp.verve_exit_island();
      }
      applyEventFlags(e);
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

  // Phase 2b — pointer + wheel for interactive viz. Each supports both the
  // closure-id and the named-export form; islands use the named form. Wheel is
  // non-passive so the handler's eventPreventDefault() can stop page scroll.
  document.addEventListener(
    "wheel",
    (e) => {
      if (dispatchEventId(e, "z-on-wheel-id", false)) return;
      dispatchEventName(e, "z-on-wheel", false);
    },
    { passive: false },
  );
  for (const [type, attr] of [
    ["pointerdown", "z-on-pointerdown"],
    ["pointermove", "z-on-pointermove"],
    ["pointerup", "z-on-pointerup"],
    ["pointerover", "z-on-pointerover"],
    ["pointerout", "z-on-pointerout"],
    ["pointercancel", "z-on-pointercancel"],
    ["dblclick", "z-on-dblclick"],
  ]) {
    document.addEventListener(type, (e) => {
      if (dispatchEventId(e, attr + "-id", false)) return;
      dispatchEventName(e, attr, false);
    });
  }

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
  // (The shared `indirectFunctionTable` is the JS-created growable table
  // the main client imported at instantiation — declared above `env`.)

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

  // ---- Verve Anim ------------------------------------------------------
  // Descriptor interpreter for verve.anim ("v":1 wire format — the Zig
  // serializer in src/core/anim/serialize.zig is the source of truth; its
  // golden tests are this code's conformance fixtures). Zig builds and
  // serializes tween/timeline descriptors; this section owns the rAF loop
  // and style writes. Wasm is re-entered per frame only for dynamic
  // values / fn modifiers (translated funcref slots called directly).

  // Easing — constants match src/core/anim/ease.zig exactly.
  const EASE = (() => {
    const { pow, sin, cos, sqrt, PI } = Math;
    const c1 = 1.70158;
    const c2 = c1 * 1.525;
    const c3 = c1 + 1;
    const c4 = (2 * PI) / 3;
    const c5 = (2 * PI) / 4.5;
    const bOut = (t) => {
      const n1 = 7.5625;
      const d1 = 2.75;
      if (t < 1 / d1) return n1 * t * t;
      if (t < 2 / d1) return n1 * (t -= 1.5 / d1) * t + 0.75;
      if (t < 2.5 / d1) return n1 * (t -= 2.25 / d1) * t + 0.9375;
      return n1 * (t -= 2.625 / d1) * t + 0.984375;
    };
    return {
      linear: (t) => t,
      inSine: (t) => 1 - cos((t * PI) / 2),
      outSine: (t) => sin((t * PI) / 2),
      inOutSine: (t) => -(cos(PI * t) - 1) / 2,
      inQuad: (t) => t * t,
      outQuad: (t) => 1 - (1 - t) * (1 - t),
      inOutQuad: (t) => (t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2),
      inCubic: (t) => t * t * t,
      outCubic: (t) => 1 - pow(1 - t, 3),
      inOutCubic: (t) => (t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2),
      inQuart: (t) => t * t * t * t,
      outQuart: (t) => 1 - pow(1 - t, 4),
      inOutQuart: (t) => (t < 0.5 ? 8 * t * t * t * t : 1 - pow(-2 * t + 2, 4) / 2),
      inQuint: (t) => t * t * t * t * t,
      outQuint: (t) => 1 - pow(1 - t, 5),
      inOutQuint: (t) => (t < 0.5 ? 16 * t * t * t * t * t : 1 - pow(-2 * t + 2, 5) / 2),
      inExpo: (t) => (t === 0 ? 0 : pow(2, 10 * t - 10)),
      outExpo: (t) => (t === 1 ? 1 : 1 - pow(2, -10 * t)),
      inOutExpo: (t) =>
        t === 0 ? 0 : t === 1 ? 1 : t < 0.5 ? pow(2, 20 * t - 10) / 2 : (2 - pow(2, -20 * t + 10)) / 2,
      inCirc: (t) => 1 - sqrt(1 - t * t),
      outCirc: (t) => sqrt(1 - (t - 1) * (t - 1)),
      inOutCirc: (t) =>
        t < 0.5 ? (1 - sqrt(1 - pow(2 * t, 2))) / 2 : (sqrt(1 - pow(-2 * t + 2, 2)) + 1) / 2,
      inBack: (t) => c3 * t * t * t - c1 * t * t,
      outBack: (t) => 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2),
      inOutBack: (t) =>
        t < 0.5
          ? (pow(2 * t, 2) * ((c2 + 1) * 2 * t - c2)) / 2
          : (pow(2 * t - 2, 2) * ((c2 + 1) * (t * 2 - 2) + c2) + 2) / 2,
      inElastic: (t) =>
        t === 0 ? 0 : t === 1 ? 1 : -pow(2, 10 * t - 10) * sin((t * 10 - 10.75) * c4),
      outElastic: (t) =>
        t === 0 ? 0 : t === 1 ? 1 : pow(2, -10 * t) * sin((t * 10 - 0.75) * c4) + 1,
      inOutElastic: (t) =>
        t === 0
          ? 0
          : t === 1
            ? 1
            : t < 0.5
              ? -(pow(2, 20 * t - 10) * sin((20 * t - 11.125) * c5)) / 2
              : (pow(2, -20 * t + 10) * sin((20 * t - 11.125) * c5)) / 2 + 1,
      inBounce: (t) => 1 - bOut(1 - t),
      outBounce: bOut,
      inOutBounce: (t) => (t < 0.5 ? (1 - bOut(1 - 2 * t)) / 2 : (1 + bOut(2 * t - 1)) / 2),
    };
  })();
  const easeFnOf = (name) => EASE[name] || EASE.linear;

  // Value parsing — numbers with units and computed-style rgb()/rgba().
  const ANIM_NUM_RE = /^(-?(?:\d+\.?\d*|\.\d+)(?:e[-+]?\d+)?)(.*)$/i;
  const animParseVal = (s) => {
    if (typeof s === "number") return { n: s, u: null };
    if (s == null) return null;
    s = String(s).trim();
    const cm = s.match(/^rgba?\(([^)]+)\)$/);
    if (cm) {
      const p = cm[1].split(",").map(parseFloat);
      return { rgb: [p[0] || 0, p[1] || 0, p[2] || 0, p.length > 3 ? p[3] : 1] };
    }
    const m = s.match(ANIM_NUM_RE);
    if (m) return { n: parseFloat(m[1]), u: m[2].trim() || null };
    return null;
  };

  // Transform composition — the engine owns `style.transform` for any
  // element it touches. x/y/scale/rotate/skew compose into ONE transform
  // write per element per frame. Pre-existing transforms are absorbed via
  // one-time 2D matrix decomposition (matrix3d → warn + identity).
  const XFORM = new Set(["x", "y", "scale", "scaleX", "scaleY", "rotate", "skewX", "skewY"]);
  const UNITLESS = new Set([
    "opacity", "scale", "scaleX", "scaleY", "z-index", "flex-grow", "flex-shrink",
    "font-weight", "order", "zoom",
  ]);
  const DEG_PROPS = new Set(["rotate", "skewX", "skewY"]);
  const xformCache = new WeakMap();
  const seedXform = (el) => {
    const st = { x: 0, y: 0, sx: 1, sy: 1, r: 0, kx: 0, ky: 0 };
    let tr = "";
    try {
      tr = getComputedStyle(el).transform || "";
    } catch {}
    if (tr && tr !== "none") {
      if (tr.startsWith("matrix3d")) {
        console.warn("verve anim: matrix3d transform absorbed as identity", el);
      } else {
        const m = tr.match(/matrix\(([^)]+)\)/);
        if (m) {
          const [a, b, c, d, e, f] = m[1].split(",").map(Number);
          st.x = e;
          st.y = f;
          const sx = Math.hypot(a, b);
          st.r = (Math.atan2(b, a) * 180) / Math.PI;
          st.sx = sx;
          st.sy = sx ? (a * d - b * c) / sx : 1;
          st.kx = (Math.atan2(a * c + b * d, a * a + b * b) * 180) / Math.PI;
        }
      }
    }
    return st;
  };
  const getXform = (el) => {
    let s = xformCache.get(el);
    if (!s) {
      s = seedXform(el);
      xformCache.set(el, s);
    }
    return s;
  };
  const xformGet = (s, prop) =>
    prop === "x" ? s.x
    : prop === "y" ? s.y
    : prop === "rotate" ? s.r
    : prop === "skewX" ? s.kx
    : prop === "skewY" ? s.ky
    : prop === "scaleY" ? s.sy
    : s.sx; // scale / scaleX
  const xformSet = (s, prop, v) => {
    if (prop === "x") s.x = v;
    else if (prop === "y") s.y = v;
    else if (prop === "rotate") s.r = v;
    else if (prop === "skewX") s.kx = v;
    else if (prop === "skewY") s.ky = v;
    else if (prop === "scaleX") s.sx = v;
    else if (prop === "scaleY") s.sy = v;
    else {
      s.sx = v;
      s.sy = v;
    }
  };
  const writeXform = (el) => {
    const s = xformCache.get(el);
    el.style.transform =
      `translate(${s.x}px, ${s.y}px) rotate(${s.r}deg) ` +
      `skew(${s.kx}deg, ${s.ky}deg) scale(${s.sx}, ${s.sy})`;
  };

  // Stagger delays — mirrors src/core/anim/stagger.zig.
  const staggerDelays = (n, st) => {
    const out = new Array(n).fill(0);
    if (!st || n <= 1) return out;
    const grid = st.grid || null;
    const cols = grid ? Math.max(grid[0], 1) : 0;
    const lastC = grid ? Math.max(grid[0], 1) - 1 : 0;
    const lastR = grid ? Math.max(grid[1], 1) - 1 : 0;
    const from = st.from == null ? "start" : st.from;
    const focal = (() => {
      if (grid) {
        if (from === "start") return [0, 0];
        if (from === "end") return [lastC, lastR];
        if (from === "center" || from === "edges") return [lastC / 2, lastR / 2];
        const k = Math.min(typeof from === "number" ? from : 0, n - 1);
        return [k % cols, Math.floor(k / cols)];
      }
      if (from === "start") return 0;
      if (from === "end") return n - 1;
      if (from === "center" || from === "edges") return (n - 1) / 2;
      return Math.min(typeof from === "number" ? from : 0, n - 1);
    })();
    const dist = (i) => {
      if (grid) {
        const dx = (i % cols) - focal[0];
        const dy = Math.floor(i / cols) - focal[1];
        if (st.axis === "x") return Math.abs(dx);
        if (st.axis === "y") return Math.abs(dy);
        return Math.hypot(dx, dy);
      }
      return Math.abs(i - focal);
    };
    let dmax = 0;
    for (let i = 0; i < n; i++) dmax = Math.max(dmax, dist(i));
    if (dmax === 0) return out;
    const eFn = st.e ? easeFnOf(st.e) : null;
    const spread = st.total != null ? st.total : (st.each || 0) * dmax;
    for (let i = 0; i < n; i++) {
      let d = dist(i);
      if (from === "edges") d = dmax - d;
      const norm = d / dmax;
      out[i] = (eFn ? eFn(norm) : norm) * spread;
    }
    return out;
  };

  // Funcref calls for dynamic values / fn modifiers. Slots arrive already
  // translated into the main table (verve_anim_register_dyn/_mod below).
  const animCallDyn = (slot, i, n) => {
    try {
      const fn = indirectFunctionTable.get(slot >>> 0);
      return typeof fn === "function" ? fn(i >>> 0, n >>> 0) : 0;
    } catch (err) {
      console.error("verve anim dyn failed:", err);
      return 0;
    }
  };
  const animCallMod = (slot, v) => {
    try {
      const fn = indirectFunctionTable.get(slot >>> 0);
      return typeof fn === "function" ? fn(v) : v;
    } catch (err) {
      console.error("verve anim mod failed:", err);
      return v;
    }
  };

  const buildMods = (mods) => {
    const byProp = {};
    for (const m of mods || []) {
      const fns = byProp[m.p] || (byProp[m.p] = []);
      if (m.snap) fns.push((v) => Math.round(v / m.snap) * m.snap);
      else if (m.clamp) fns.push((v) => Math.max(m.clamp[0], Math.min(m.clamp[1], v)));
      else if (m.wrap)
        fns.push((v) => {
          const r = m.wrap[1] - m.wrap[0];
          return r > 0 ? m.wrap[0] + ((((v - m.wrap[0]) % r) + r) % r) : m.wrap[0];
        });
      else if (m.dyn != null) fns.push((v) => animCallMod(m.dyn, v));
    }
    return byProp;
  };

  // Registry. Handle 0 = failure sentinel.
  const anims = new Map();
  const namedAnims = new Map();
  let animSeq = 1;
  let animTickerOn = false;
  let animLast = 0;

  let prefersReduced = false;
  try {
    const mq = window.matchMedia("(prefers-reduced-motion: reduce)");
    prefersReduced = mq.matches;
    const onChange = (ev) => {
      prefersReduced = ev.matches;
      if (ev.matches) {
        // Scroll triggers first: kill anim-bearing / pinned ones (their
        // anims jump below or here); class-toggle-only triggers stay.
        for (const t of [...stTriggers.values()]) {
          if (t.anim || t.pinEl) {
            const a = t.anim ? anims.get(t.anim) : null;
            stKill(t);
            if (a && a.rm !== "allow") animJumpToEnd(a);
          }
        }
        for (const a of [...anims.values()]) {
          if (a.rm !== "allow") animJumpToEnd(a);
        }
      }
    };
    if (typeof mq.addEventListener === "function") mq.addEventListener("change", onChange);
    else if (typeof mq.addListener === "function") mq.addListener(onChange);
  } catch {}

  // One tween instance inside an animation (a bare tween is a single
  // instance at start 0; timeline children carry their resolved starts).
  const buildTweenInst = (c, selfEl, start) => {
    let targets = [];
    if (c.t && c.t.h != null) {
      const el = refHandles[c.t.h];
      if (el) targets = [el];
    } else if (c.t && c.t.s) {
      const scope = selfEl || document;
      targets = Array.from(scope.querySelectorAll(c.t.s));
    } else if (selfEl) {
      targets = [selfEl];
    }
    const n = targets.length;
    const dur = typeof c.d === "number" ? c.d : 0.5;
    const del = c.del || 0;
    const rep = c.rep || 0;
    const rd = c.rd || 0;
    const delays = staggerDelays(n, c.st);
    const maxDelay = delays.reduce((m, v) => Math.max(m, v), 0);
    const cycleEnd = rep < 0 ? Infinity : (rep + 1) * (dur + rd) - rd;
    // from-tween (every prop authored as start-only): render its first
    // frame immediately so SSR entrance staggers don't flash unanimated.
    let immediate = false;
    if (c.p) {
      const specs = Object.values(c.p);
      immediate = specs.length > 0 && specs.every((s) => s.f !== undefined && s.to === undefined);
    }
    return {
      start, targets, n, dur, del, rep, rd, delays, maxDelay, immediate,
      yo: !!c.yo,
      easeFn: easeFnOf(c.e),
      props: c.p || null,
      kf: c.k || null,
      mods: buildMods(c.mod),
      cb: c.cb || null,
      // MotionPath polyline / morph point arrays (Zig pre-computed; mp
      // alongside keyframes is Zig-rejected — JS defends anyway).
      mp: c.k ? null : c.mp || null,
      mo: c.mo || null,
      firstEnd: del + maxDelay + dur,
      total: rep < 0 ? Infinity : del + maxDelay + cycleEnd,
      resolved: false,
      state: null,
      firedS: false,
      firedC: false,
      lastCycle: 0,
    };
  };

  // Tween-less descriptor (anim.reveal / standalone trigger): a scroll
  // trigger with NO animation carrier — no props, no keyframes, no
  // timeline children, no motion path, no morph. Anything carrying an
  // animation must build it (scrub needs a record to drive).
  // @verve-extract animIsTriggerOnly
  const animIsTriggerOnly = (desc) =>
    !!desc.sc && !desc.p && !desc.k && !desc.ch && !desc.mp && !desc.mo;
  // @verve-extract-end

  const animCreate = (desc, selfEl) => {
    if (!desc || desc.v !== 1) return 0;
    if (animIsTriggerOnly(desc)) {
      return stRegister(desc.sc, null, selfEl);
    }
    const rm = desc.rm || "jump";
    if (prefersReduced && rm === "skip") return 0;
    const a = {
      h: animSeq++,
      name: desc.id || null,
      rm,
      pos: 0,
      rate: 1,
      paused: desc.auto === 0,
      reversed: false,
      done: false,
      lab: desc.lab || null,
      cb: desc.cb || null,
      tweens: [],
      delay: 0,
      rep: 0,
      yo: false,
      content: 0,
    };
    if (desc.tl) {
      a.delay = desc.del || 0;
      a.rep = desc.rep || 0;
      a.yo = !!desc.yo;
      for (const c of desc.ch || []) {
        a.tweens.push(buildTweenInst(c, selfEl, c.pos || 0));
      }
    } else {
      a.tweens.push(buildTweenInst(desc, selfEl, 0));
    }
    if (!a.tweens.some((tw) => tw.n > 0)) return 0;
    a.content = a.tweens.reduce((m, tw) => Math.max(m, tw.start + tw.total), 0);
    a.total = a.rep < 0 || !isFinite(a.content)
      ? Infinity
      : a.delay + a.content * (a.rep + 1);
    a.firstEnd = a.delay + a.tweens.reduce((m, tw) => Math.max(m, tw.start + tw.firstEnd), 0);
    anims.set(a.h, a);
    if (a.name) namedAnims.set(a.name, a.h);
    if (desc.sc) {
      // Scroll-triggered: the trigger owns play-state ("auto" ignored).
      // Paint from-tween first frames so entrances don't flash, then
      // hand off; stRegister handles reduced motion (jump-to-end).
      a.paused = true;
      for (const tw of a.tweens) {
        if (tw.immediate) {
          animResolveTween(tw);
          animWriteTween(tw, 0, new Set());
        }
      }
      flushXform();
      stRegister(desc.sc, a, selfEl);
      return a.h;
    }
    if (prefersReduced && rm !== "allow") {
      animJumpToEnd(a);
      return a.h;
    }
    // Immediate first render for from-tweens (phase 0), even when delayed.
    for (const tw of a.tweens) {
      if (tw.immediate) {
        animResolveTween(tw);
        animWriteTween(tw, 0, new Set());
      }
    }
    flushXform();
    animStartTicker();
    return a.h;
  };

  const animResolveTween = (tw) => {
    if (tw.resolved) return;
    tw.resolved = true;
    const csCache = new Map();
    const readCurrent = (el, prop) => {
      if (XFORM.has(prop)) return { n: xformGet(getXform(el), prop) };
      if (prop.startsWith("attr:")) {
        return animParseVal(el.getAttribute(prop.slice(5))) || { n: 0 };
      }
      let cs = csCache.get(el);
      if (!cs) {
        try {
          cs = getComputedStyle(el);
        } catch {
          cs = null;
        }
        csCache.set(el, cs);
      }
      return (cs && animParseVal(cs.getPropertyValue(prop))) || { n: 0 };
    };
    const authored = (v, i) => {
      if (v === undefined || v === null) return null;
      if (typeof v === "number") return { n: v, u: null };
      if (typeof v === "string") return animParseVal(v);
      if (v.c) return { rgb: v.c };
      if (v.dyn != null) return { n: animCallDyn(v.dyn, i, tw.n) };
      return null;
    };
    tw.state = tw.targets.map((el, i) => {
      const per = {};
      if (tw.kf) {
        // keyframe mode: per-prop segment table across the steps
        const segs = {};
        for (const step of tw.kf) {
          for (const [name, spec] of Object.entries(step.p || {})) {
            const list = segs[name] || (segs[name] = { unit: null, pts: [] });
            const v = authored(spec.v, i) || { n: 0 };
            if (spec.u) list.unit = spec.u;
            list.pts.push({ o: step.o || 0, v, easeFn: step.e ? easeFnOf(step.e) : null });
          }
        }
        for (const [name, s] of Object.entries(segs)) {
          per[name] = {
            kind: "kf",
            pts: s.pts,
            unit: s.unit || (DEG_PROPS.has(name) ? "deg" : null),
          };
        }
        return per;
      }
      for (const [name, spec] of Object.entries(tw.props || {})) {
        let from = authored(spec.f, i);
        let to = authored(spec.to, i);
        if (!from) from = readCurrent(el, name);
        if (!to) to = readCurrent(el, name);
        const color = !!(from.rgb || to.rgb);
        if (color) {
          if (!from.rgb) from = { rgb: [0, 0, 0, 1] };
          if (!to.rgb) to = { rgb: [0, 0, 0, 1] };
        }
        per[name] = {
          kind: color ? "color" : "num",
          from: color ? from.rgb : from.n,
          to: color ? to.rgb : to.n,
          unit: spec.u || from.u || to.u || (DEG_PROPS.has(name) ? "deg" : null),
        };
      }
      if (tw.mo) {
        // reserved name — can never collide with a CSS prop or attr: name
        per["@morph"] = { kind: "morph", a: tw.mo.a, b: tw.mo.b, sp: tw.mo.sp, z: tw.mo.z || null };
      }
      return per;
    });
  };

  const animDirty = new Set();
  const flushXform = () => {
    for (const el of animDirty) writeXform(el);
    animDirty.clear();
  };

  // ---- MotionPath / MorphSVG (Zig pre-computed; JS lerps only) ---------

  // Lerp along the uniform-arc-length polyline. Index clamped, t NOT
  // clamped — back/elastic overshoot extrapolates along the end tangent
  // (intended). Angles arrive unwrapped from Zig so raw lerp is safe.
  // @verve-extract mpSample
  const mpSample = (pts, stride, e) => {
    const N = pts.length / stride;
    const f = e * (N - 1);
    let i = Math.floor(f);
    if (i < 0) i = 0;
    else if (i > N - 2) i = N - 2;
    const t = f - i;
    const k = i * stride;
    const lp = (o) => pts[k + o] + (pts[k + stride + o] - pts[k + o]) * t;
    return stride === 3 ? [lp(0), lp(1), lp(2)] : [lp(0), lp(1)];
  };
  // @verve-extract-end

  const animWriteMotionPath = (el, mp, phase, easeFn, mods) => {
    const rot = !!mp.rot;
    const v = mpSample(mp.pts, rot ? 3 : 2, easeFn(phase));
    let xv = v[0];
    let yv = v[1];
    const fx = mods["x"];
    if (fx) for (const f of fx) xv = f(xv);
    const fy = mods["y"];
    if (fy) for (const f of fy) yv = f(yv);
    const s = getXform(el);
    xformSet(s, "x", xv);
    xformSet(s, "y", yv);
    if (rot) xformSet(s, "rotate", v[2] + (mp.ro || 0));
    animDirty.add(el);
  };

  // Build the lerped d string. Math.round concat (no toFixed allocs);
  // M + C runs + Z per closed flag — mirrors path.zig's flat encoding.
  // @verve-extract buildMorphD
  const buildMorphD = (st, e) => {
    const a = st.a;
    const b = st.b;
    const L = (i) => Math.round((a[i] + (b[i] - a[i]) * e) * 100) / 100;
    let s = "";
    let p = 0;
    for (let si = 0; si < st.sp.length; si++) {
      s += "M" + L(p) + "," + L(p + 1);
      p += 2;
      for (let seg = 0; seg < st.sp[si]; seg++) {
        s += "C" + L(p) + "," + L(p + 1) + " " + L(p + 2) + "," + L(p + 3) +
          " " + L(p + 4) + "," + L(p + 5);
        p += 6;
      }
      if (st.z && st.z[si]) s += "Z";
    }
    return s;
  };
  // @verve-extract-end

  const animWriteProp = (el, name, st, phase, easeFn, mods) => {
    if (st.kind === "morph") {
      el.setAttribute("d", buildMorphD(st, easeFn(phase)));
      return;
    }
    let out;
    if (st.kind === "kf") {
      const pts = st.pts;
      if (!pts.length) return;
      let v;
      if (phase <= pts[0].o) v = pts[0].v;
      else if (phase >= pts[pts.length - 1].o) v = pts[pts.length - 1].v;
      else {
        let j = 1;
        while (j < pts.length && pts[j].o < phase) j++;
        const a = pts[j - 1];
        const b = pts[j];
        const span = b.o - a.o;
        const tt = span > 0 ? (phase - a.o) / span : 1;
        const e = (b.easeFn || easeFn)(tt);
        if (a.v.rgb && b.v.rgb) {
          v = { rgb: a.v.rgb.map((c, k) => c + (b.v.rgb[k] - c) * e) };
        } else {
          v = { n: (a.v.n || 0) + ((b.v.n || 0) - (a.v.n || 0)) * e };
        }
      }
      out = v.rgb ? v : { n: v.n };
    } else {
      const e = easeFn(phase);
      if (st.kind === "color") {
        out = { rgb: st.from.map((c, k) => c + (st.to[k] - c) * e) };
      } else {
        out = { n: st.from + (st.to - st.from) * e };
      }
    }
    if (out.rgb) {
      const [r, g, b, al] = out.rgb;
      el.style.setProperty(name, `rgba(${r}, ${g}, ${b}, ${al == null ? 1 : al})`);
      return;
    }
    let v = out.n;
    const fns = mods[name];
    if (fns) for (const f of fns) v = f(v);
    if (XFORM.has(name)) {
      xformSet(getXform(el), name, v);
      animDirty.add(el);
      return;
    }
    if (name.startsWith("attr:")) {
      el.setAttribute(name.slice(5), String(v));
      return;
    }
    const u = st.unit != null ? st.unit : UNITLESS.has(name) ? "" : "px";
    el.style.setProperty(name, v + u);
  };

  // Time → phase fold for one tween at one target, honoring delay,
  // stagger delay, repeat, repeatDelay, and yoyo. Returns null before
  // start, {phase, cycle, done} otherwise.
  const animFold = (tw, local, targetIdx) => {
    let t = local - tw.del - tw.delays[targetIdx];
    if (t < 0) return null;
    const cd = tw.dur + tw.rd;
    if (tw.dur <= 0) {
      return { phase: 1, cycle: 0, done: tw.rep >= 0 };
    }
    let cycle = cd > 0 ? Math.floor(t / cd) : 0;
    if (tw.rep >= 0 && cycle > tw.rep) {
      const lastOdd = tw.yo && tw.rep % 2 === 1;
      return { phase: lastOdd ? 0 : 1, cycle: tw.rep, done: true };
    }
    let lt = t - cycle * cd;
    if (lt > tw.dur) lt = tw.dur; // inside the repeatDelay gap
    let phase = lt / tw.dur;
    if (tw.yo && cycle % 2 === 1) phase = 1 - phase;
    return { phase, cycle, done: false };
  };

  const animWriteTween = (tw, local, completedSet) => {
    let anyActive = false;
    let allDone = tw.n > 0;
    let maxCycle = 0;
    for (let i = 0; i < tw.n; i++) {
      const el = tw.targets[i];
      if (!el || !el.isConnected) continue;
      const f = animFold(tw, local, i);
      if (!f) {
        if (tw.immediate && tw.state) {
          const per = tw.state[i];
          for (const name of Object.keys(per)) {
            animWriteProp(el, name, per[name], 0, tw.easeFn, tw.mods);
          }
        }
        allDone = false;
        continue;
      }
      anyActive = true;
      if (!f.done) allDone = false;
      if (f.cycle > maxCycle) maxCycle = f.cycle;
      const per = tw.state ? tw.state[i] : null;
      if (!per) continue;
      for (const name of Object.keys(per)) {
        animWriteProp(el, name, per[name], f.phase, tw.easeFn, tw.mods);
      }
      if (tw.mp) animWriteMotionPath(el, tw.mp, f.phase, tw.easeFn, tw.mods);
    }
    if (anyActive && !tw.firedS) {
      tw.firedS = true;
      if (tw.cb) animFireSlot(tw.cb.sS);
    }
    if (maxCycle > tw.lastCycle) {
      tw.lastCycle = maxCycle;
      if (tw.cb) animFireSlot(tw.cb.sR);
    }
    if (allDone && !tw.firedC) {
      tw.firedC = true;
      completedSet.add(tw);
    }
  };

  const animFireSlot = (slot) => {
    if (slot == null) return;
    if (typeof exp.verve_dispatch_event !== "function") return;
    try {
      exp.verve_dispatch_event(slot >>> 0);
    } catch (err) {
      console.error("verve anim callback failed:", err);
    }
  };

  const animFireCb = (a, cb) => {
    if (!cb) return;
    animFireSlot(cb.sC);
    if (cb.isl && cb.nC) {
      callIslandExport(cb.isl, cb.nC, JSON.stringify({ anim: a.name || a.h }));
    }
  };

  // Root-level repeat/yoyo fold (timeline cycles), then per-tween render.
  const animRenderAt = (a, pos) => {
    let t = pos - a.delay;
    if (t < 0) t = 0;
    const content = a.content;
    if (a.rep !== 0 && content > 0 && isFinite(content)) {
      let cycle = Math.floor(t / content);
      const maxC = a.rep < 0 ? Infinity : a.rep;
      if (cycle > maxC) cycle = maxC;
      let local = t - cycle * content;
      if (local > content || cycle === maxC && t >= content * (maxC + 1)) local = content;
      if (a.yo && cycle % 2 === 1) local = content - local;
      t = local;
    } else if (isFinite(content) && t > content) {
      t = content;
    }
    // Resolve newly-activated tweens (batched reads) before any writes.
    for (const tw of a.tweens) {
      if (!tw.resolved && t >= tw.start) animResolveTween(tw);
    }
    const completed = new Set();
    for (const tw of a.tweens) {
      if (!tw.resolved) continue;
      animWriteTween(tw, t - tw.start, completed);
    }
    flushXform();
    // Child completion callbacks in start order.
    for (const tw of [...completed].sort((x, y) => x.start - y.start)) {
      if (tw.cb) {
        animFireSlot(tw.cb.sC);
        if (tw.cb.isl && tw.cb.nC) {
          callIslandExport(tw.cb.isl, tw.cb.nC, JSON.stringify({ anim: a.name || a.h }));
        }
      }
    }
  };

  const animFinish = (a) => {
    a.pos = a.total;
    animRenderAt(a, a.total);
    a.done = true;
    a.paused = true;
    animFireCb(a, a.cb);
  };

  const animKill = (a) => {
    anims.delete(a.h);
    if (a.name && namedAnims.get(a.name) === a.h) namedAnims.delete(a.name);
  };

  const animJumpToEnd = (a) => {
    const end = isFinite(a.total) ? a.total : a.firstEnd;
    // Fire per-tween + root callbacks in order via a full seek render.
    for (const tw of a.tweens) {
      if (!tw.resolved) animResolveTween(tw);
    }
    animRenderAt(a, end);
    a.pos = end;
    a.done = true;
    a.paused = true;
    animFireCb(a, a.cb);
    animKill(a);
  };

  const animTick = (now) => {
    const dt = Math.min((now - animLast) / 1000, 0.1);
    animLast = now;
    // Scroll triggers first: edge actions / scrub seeks land before this
    // frame's time integration.
    if (stTriggers.size) stUpdate(dt);
    for (const a of [...anims.values()]) {
      if (a.paused || a.done) continue;
      // Self-kill animations whose targets all left the document
      // (SPA swaps, removed subtrees). Silent, like GSAP kill.
      if (!a.tweens.some((tw) => tw.targets.some((el) => el && el.isConnected))) {
        animKill(a);
        continue;
      }
      a.pos += dt * a.rate * (a.reversed ? -1 : 1);
      if (!a.reversed && a.pos >= a.total) {
        animFinish(a);
        continue;
      }
      if (a.reversed && a.pos <= 0) {
        a.pos = 0;
        a.paused = true;
        animRenderAt(a, 0);
        continue;
      }
      animRenderAt(a, a.pos);
    }
    // Keep ticking while time-driven anims run OR scroll work remains
    // (fresh scroll events / unsettled scrub smoothing set stDirty).
    if (stDirty || (anims.size && [...anims.values()].some((a) => !a.paused && !a.done))) {
      requestAnimationFrame(animTick);
    } else {
      animTickerOn = false;
    }
  };

  // Unconditional ticker start — the scroll listener must wake the loop
  // even when every animation is paused (scrub-driven seeks).
  const tickerKick = () => {
    if (animTickerOn) return;
    animTickerOn = true;
    animLast = performance.now();
    requestAnimationFrame(animTick);
  };

  const animStartTicker = () => {
    if (animTickerOn) return;
    if (![...anims.values()].some((a) => !a.paused && !a.done)) return;
    tickerKick();
  };

  // Control ops: 0=play 1=pause 2=reverse 3=restart 4=seek 5=timeScale 6=kill
  const animCtrl = (h, op, v) => {
    const a = anims.get(h);
    if (!a) return;
    switch (op) {
      case 0:
        if (a.done && a.pos >= a.total) break; // completed; use restart
        a.paused = false;
        a.done = false;
        animStartTicker();
        break;
      case 1:
        a.paused = true;
        break;
      case 2:
        a.reversed = !a.reversed;
        a.paused = false;
        a.done = false;
        if (a.reversed && !isFinite(a.total)) a.pos = Math.min(a.pos, a.firstEnd);
        animStartTicker();
        break;
      case 3:
        a.pos = 0;
        a.reversed = false;
        a.paused = false;
        a.done = false;
        for (const tw of a.tweens) {
          tw.firedS = false;
          tw.firedC = false;
          tw.lastCycle = 0;
        }
        animRenderAt(a, 0);
        animStartTicker();
        break;
      case 4: {
        const end = isFinite(a.total) ? a.total : Number.MAX_VALUE;
        a.pos = Math.max(0, Math.min(v, end));
        animRenderAt(a, a.pos);
        break;
      }
      case 5:
        a.rate = v > 0 ? v : 0;
        break;
      case 6:
        animKill(a);
        break;
    }
  };

  const animGet = (h, field) => {
    const a = anims.get(h);
    if (!a) return 0;
    switch (field) {
      case 0:
        return a.pos;
      case 1:
        return isFinite(a.total) && a.total > 0 ? Math.max(0, Math.min(a.pos / a.total, 1)) : 0;
      case 2:
        return isFinite(a.total) ? a.total : -1;
      case 3:
        return !a.paused && !a.done ? 1 : 0;
      case 4:
        return a.rate;
      case 5:
        return a.reversed ? 1 : 0;
      default:
        return 0;
    }
  };

  // Declarative SSR surface: scan `[data-anim]` stamped by Node.animate().
  // Runs after the initial hydrate pass, on observer-added subtrees
  // (Suspense swaps, template clones, SPA navigations), guarded by a
  // `data-anim-done` stamp against re-registration.
  const animScan = (root) => {
    const list = [];
    if (root instanceof Element) {
      if (root.hasAttribute("data-anim")) list.push(root);
      root.querySelectorAll("[data-anim]").forEach((el) => list.push(el));
    } else if (root && root.querySelectorAll) {
      root.querySelectorAll("[data-anim]").forEach((el) => list.push(el));
    }
    for (const el of list) {
      if (el.hasAttribute("data-anim-done")) continue;
      el.setAttribute("data-anim-done", "1");
      let desc;
      try {
        desc = JSON.parse(el.getAttribute("data-anim"));
      } catch (err) {
        console.warn("verve anim: bad data-anim payload", el, err);
        continue;
      }
      animCreate(desc, el);
    }
  };

  // ---- Verve Scroll ----------------------------------------------------
  // ScrollTrigger + Observer runtime ("sc" wire key — see
  // src/core/anim/scroll.zig + serialize.zig goldens for the contract).
  // Geometry model: trigger ranges cached as document-space startY/endY
  // px (no IntersectionObserver — async delivery is too sloppy for
  // scrub; two float compares per trigger per frame is exact and cheap).
  // v1 scope: vertical window scroll only.

  const stTriggers = new Map();
  let stSeq = 1;
  let stScrollY = 0;
  let stDir = 1;
  let stVel = 0;
  let stVelT = 0;
  let stDirty = false;
  let stListening = false;

  // Scroll velocity decays lazily on read — no ticker dependency.
  const stVelocity = () => {
    const dt = (performance.now() - stVelT) / 1000;
    return stVel * Math.pow(0.001, Math.max(0, dt));
  };

  const stInstall = () => {
    if (stListening) return;
    stListening = true;
    stScrollY = window.scrollY || 0;
    window.addEventListener(
      "scroll",
      () => {
        const y = window.scrollY || 0;
        const now = performance.now();
        if (stVelT) {
          const dt = (now - stVelT) / 1000;
          if (dt > 0) stVel = (y - stScrollY) / dt;
        }
        stVelT = now;
        if (y !== stScrollY) stDir = y > stScrollY ? 1 : -1;
        stScrollY = y;
        stDirty = true;
        // Pins applied synchronously here — rAF-applied position:fixed
        // lags scrolling by a frame and jitters visibly.
        for (const t of stTriggers.values()) if (t.pinEl) stApplyPin(t);
        tickerKick();
      },
      { passive: true },
    );
    let resizeRaf = 0;
    window.addEventListener("resize", () => {
      if (resizeRaf) return;
      resizeRaf = requestAnimationFrame(() => {
        resizeRaf = 0;
        stRefreshAll();
        stDirty = true;
        tickerKick();
      });
    });
    // Late images / webfonts shift layout — re-measure once each.
    window.addEventListener("load", () => {
      stRefreshAll();
      stDirty = true;
      tickerKick();
    });
    try {
      if (document.fonts && document.fonts.ready) {
        document.fonts.ready.then(() => {
          stRefreshAll();
          stDirty = true;
          tickerKick();
        });
      }
    } catch {}
  };

  // Register a trigger. `sc` = parsed wire object; `a` = owning anim
  // record or null (standalone reveal/callback trigger); `selfEl` = the
  // data-anim carrying element (selector scope + default trigger).
  // Returns the trigger handle (0 = nothing registered).
  const stRegister = (sc, a, selfEl) => {
    let el = null;
    if (sc.t && sc.t.h != null) el = refHandles[sc.t.h];
    else if (sc.t && sc.t.s) el = (selfEl || document).querySelector(sc.t.s);
    else if (selfEl) el = selfEl;
    else if (a) {
      const tw = a.tweens.find((x) => x.targets.length > 0);
      el = tw ? tw.targets[0] : null;
    }
    if (!el) {
      // No trigger element: degrade to plain playback so content isn't lost.
      if (a) {
        a.paused = false;
        animStartTicker();
      }
      return 0;
    }
    // Reduced motion: anim-bearing triggers jump to their end state
    // (content stays readable, incl. scrub); class toggles and
    // callback-only triggers remain (motion-free); pins disabled.
    if (prefersReduced && a && a.rm !== "allow") {
      animJumpToEnd(a);
      if (!sc.cls && !sc.cb) return 0;
      a = null;
    }
    let scrub = sc.scr === true ? 0 : typeof sc.scr === "number" ? sc.scr : null;
    if (scrub != null && a && !isFinite(a.total)) {
      console.warn("verve scroll: cannot scrub an infinite animation; falling back to toggle");
      scrub = null;
    }
    const t = {
      h: stSeq++,
      el,
      anim: a ? a.h : 0,
      s: sc.s || [0, 1],
      e: sc.e != null ? sc.e : null,
      scrub,
      smooth: scrub || 0,
      cur: 0,
      target: 0,
      ps: sc.ps !== 0,
      pinEl: null,
      spacer: null,
      pinState: -1,
      pinTop: 0,
      pinLeft: 0,
      pinW: 0,
      pinH: 0,
      pinSpan: 0,
      act: sc.act || [1, 0, 0, 0],
      once: !!sc.once,
      keepClsOnKill: false,
      cls: sc.cls || null,
      ct: sc.ct || null,
      cb: sc.cb || null,
      markers: null,
      mk: !!sc.mk,
      active: false,
      enabled: true,
      startY: 0,
      endY: 1,
    };
    if (sc.pin && !prefersReduced) {
      t.pinEl = sc.pin === 1 ? el : sc.pin.s ? (selfEl || document).querySelector(sc.pin.s) : null;
    }
    if (a) a.paused = true; // trigger owns play-state from here
    stTriggers.set(t.h, t);
    stInstall();
    stRefresh(t);
    if (t.mk) stMakeMarkers(t);
    stDirty = true;
    tickerKick();
    return t.h;
  };

  // Recompute one trigger's document-space range (and pin geometry) from
  // the element's UNPINNED layout state.
  const stRefresh = (t) => {
    const el = t.el;
    if (!el || !el.isConnected) return;
    if (t.pinEl) stClearPin(t);
    const r = el.getBoundingClientRect();
    const y0 = window.scrollY || 0;
    const absTop = r.top + y0;
    const vh = window.innerHeight || 0;
    const s = t.s;
    t.startY = absTop + s[0] * r.height - s[1] * vh + (s[2] || 0);
    const e = t.e;
    if (e == null) t.endY = absTop + r.height; // default "bottom top"
    else if (Array.isArray(e)) t.endY = absTop + e[0] * r.height - e[1] * vh + (e[2] || 0);
    else if (e.r != null) t.endY = t.startY + e.r;
    else if (e.rv != null) t.endY = t.startY + e.rv * vh;
    if (t.endY <= t.startY) t.endY = t.startY + 1;
    if (t.pinEl) {
      const pr = t.pinEl.getBoundingClientRect();
      t.pinTop = pr.top + y0 - t.startY; // fixed top = viewport y at engage
      t.pinLeft = pr.left;
      t.pinW = pr.width;
      t.pinH = pr.height;
      t.pinSpan = t.endY - t.startY;
      stEnsureSpacer(t);
      t.pinState = -1;
      stApplyPin(t);
    }
    if (t.markers) stPlaceMarkers(t);
  };

  // Document-order refresh: pin spacers pad layout, so triggers below a
  // pin must measure AFTER its spacer is sized.
  const stRefreshAll = () => {
    const list = [...stTriggers.values()].filter((t) => t.el && t.el.isConnected);
    list.sort((x, y) =>
      x.el === y.el
        ? 0
        : x.el.compareDocumentPosition(y.el) & Node.DOCUMENT_POSITION_FOLLOWING
          ? -1
          : 1,
    );
    for (const t of list) stRefresh(t);
  };

  const stEnsureSpacer = (t) => {
    if (!t.spacer) {
      const sp = document.createElement("div");
      sp.setAttribute("data-verve-pin-spacer", "");
      sp.style.position = "relative";
      t.pinEl.parentNode.insertBefore(sp, t.pinEl);
      sp.appendChild(t.pinEl);
      t.spacer = sp;
    }
    t.spacer.style.width = t.pinW + "px";
    t.spacer.style.height = t.pinH + (t.ps ? t.pinSpan : 0) + "px";
  };

  // 3-state pin: natural (before) / fixed (active) / absolute parked at
  // the bottom of the spacer's padded span (after). Clamped scrollY so
  // iOS rubber-banding doesn't wiggle the state machine at page edges.
  const stApplyPin = (t) => {
    if (!t.pinEl || !t.enabled) return;
    const y = Math.max(0, stScrollY);
    const state = y < t.startY ? 0 : y < t.endY ? 1 : 2;
    if (state === t.pinState) return;
    t.pinState = state;
    const st = t.pinEl.style;
    if (state === 0) {
      st.position = "";
      st.top = "";
      st.left = "";
      st.width = "";
    } else if (state === 1) {
      st.position = "fixed";
      st.top = t.pinTop + "px";
      st.left = t.pinLeft + "px";
      st.width = t.pinW + "px";
    } else {
      st.position = "absolute";
      st.top = t.pinSpan + "px";
      st.left = "0";
      st.width = t.pinW + "px";
    }
  };

  const stClearPin = (t) => {
    const st = t.pinEl.style;
    st.position = "";
    st.top = "";
    st.left = "";
    st.width = "";
    t.pinState = -1;
  };

  const stMakeMarkers = (t) => {
    const make = (label, color) => {
      const d = document.createElement("div");
      d.setAttribute("data-verve-marker", "");
      d.style.cssText =
        "position:absolute;left:0;right:0;height:0;border-top:1px dashed " +
        color +
        ";z-index:99999;pointer-events:none;font:10px monospace;color:" +
        color;
      d.textContent = label;
      document.body.appendChild(d);
      return d;
    };
    t.markers = {
      s: make("start " + t.h, "#0c6"),
      e: make("end " + t.h, "#e33"),
    };
    stPlaceMarkers(t);
  };

  const stPlaceMarkers = (t) => {
    if (!t.markers) return;
    t.markers.s.style.top = t.startY + "px";
    t.markers.e.style.top = t.endY + "px";
  };

  // Toggle actions poke the anim record directly — animCtrl's public op
  // semantics (toggle-reverse, refuse-play-when-done) don't fit boundary
  // actions, which need explicit direction.
  // 0 none 1 play 2 pause 3 resume 4 reverse 5 restart 6 complete 7 reset
  const stApplyAction = (a, act) => {
    if (!a || !act) return;
    switch (act) {
      case 1:
        a.reversed = false;
        a.paused = false;
        a.done = false;
        tickerKick();
        break;
      case 2:
        a.paused = true;
        break;
      case 3:
        a.paused = false;
        a.done = false;
        tickerKick();
        break;
      case 4:
        a.reversed = true;
        a.paused = false;
        a.done = false;
        tickerKick();
        break;
      case 5:
        animCtrl(a.h, 3, 0);
        break;
      case 6:
        animFinish(a);
        break;
      case 7:
        a.pos = 0;
        a.paused = true;
        a.done = false;
        a.reversed = false;
        animRenderAt(a, 0);
        break;
    }
  };

  const stFireScCb = (t, slotKey, exportKey) => {
    if (!t.cb) return;
    if (t.cb[slotKey] != null) animFireSlot(t.cb[slotKey]);
    if (exportKey && t.cb.isl && t.cb[exportKey]) {
      callIslandExport(
        t.cb.isl,
        t.cb[exportKey],
        JSON.stringify({ h: t.h, progress: t.target || 0, dir: stDir }),
      );
    }
  };

  const stKill = (t) => {
    stTriggers.delete(t.h);
    if (t.pinEl) {
      stClearPin(t);
      if (t.spacer) {
        if (t.spacer.contains(t.pinEl)) {
          try {
            t.spacer.replaceWith(t.pinEl);
          } catch {}
        } else {
          t.spacer.remove();
        }
      }
    }
    if (t.cls && !t.keepClsOnKill && t.el) {
      const targets = t.ct ? document.querySelectorAll(t.ct) : [t.el];
      targets.forEach((el2) => el2.classList.remove(t.cls));
    }
    if (t.markers) {
      t.markers.s.remove();
      t.markers.e.remove();
    }
  };

  // Per-frame trigger pass: boundary edges -> actions/class/callbacks,
  // scrub -> seek. Clears stDirty unless scrub smoothing is unsettled.
  const stUpdate = (dt) => {
    const y = stScrollY;
    let unsettled = false;
    for (const t of [...stTriggers.values()]) {
      const a = t.anim ? anims.get(t.anim) : null;
      if (t.anim && !a) {
        stKill(t); // owning animation was killed
        continue;
      }
      if (!t.el || !t.el.isConnected || (t.pinEl && !t.pinEl.isConnected)) {
        stKill(t);
        continue;
      }
      if (!t.enabled) continue;
      const wasActive = t.active;
      const active = y >= t.startY && y < t.endY;
      t.active = active;
      if (active !== wasActive) {
        if (active) {
          if (stDir >= 0) {
            stApplyAction(a, t.act[0]);
            stFireScCb(t, "sE", "nE");
          } else {
            stApplyAction(a, t.act[2]);
            stFireScCb(t, "sEB", null);
          }
        } else if (y >= t.endY) {
          stApplyAction(a, t.act[1]);
          stFireScCb(t, "sL", "nL");
        } else {
          stApplyAction(a, t.act[3]);
          stFireScCb(t, "sLB", null);
        }
        if (t.cls) {
          const targets = t.ct ? document.querySelectorAll(t.ct) : [t.el];
          targets.forEach((el2) => el2.classList.toggle(t.cls, active));
        }
        if (t.once && active) {
          t.keepClsOnKill = true;
          stKill(t);
          continue;
        }
      }
      if (t.scrub != null && a) {
        const raw = Math.max(0, Math.min((y - t.startY) / (t.endY - t.startY), 1));
        t.target = raw;
        if (t.smooth > 0) {
          t.cur += (t.target - t.cur) * Math.min(1, dt / t.smooth);
          if (Math.abs(t.target - t.cur) < 0.0005) t.cur = t.target;
          if (t.cur !== t.target) unsettled = true;
        } else {
          t.cur = t.target;
        }
        a.pos = t.cur * a.total;
        animRenderAt(a, a.pos);
      }
      if (active && t.cb && t.cb.sU != null) animFireSlot(t.cb.sU);
    }
    stDirty = unsettled;
  };

  // ---- Observer: unified wheel/touch/pointer/scroll input + velocity --
  // flags: 1 wheel, 2 touch, 4 pointer-drag, 8 window scroll,
  //        16 preventDefault, 32 lock dominant axis.
  const observers = new Map();
  let obsSeq = 1;

  const obsCreate = (flags, tol, sel, handlerSlot) => {
    const target = sel ? document.querySelector(sel) : null;
    if (sel && !target) return 0;
    const el = target || window;
    const o = {
      h: obsSeq++,
      el: target,
      pd: !!(flags & 16),
      lock: !!(flags & 32),
      slot: handlerSlot >>> 0,
      tol: tol || 0,
      dx: 0,
      dy: 0,
      vx: 0,
      vy: 0,
      dirX: 0,
      dirY: 0,
      dragging: false,
      kind: 0,
      accX: 0,
      accY: 0,
      axis: 0,
      sx: 0,
      sy: 0,
      samples: [],
      enabled: true,
      fns: [],
    };
    const pushSample = (x, y) => {
      const now = performance.now();
      o.samples.push({ t: now, x, y });
      while (
        o.samples.length > 6 ||
        (o.samples.length > 1 && now - o.samples[0].t > 100)
      ) {
        o.samples.shift();
      }
      if (o.samples.length > 1) {
        const s0 = o.samples[0];
        const s1 = o.samples[o.samples.length - 1];
        const sdt = (s1.t - s0.t) / 1000;
        if (sdt > 0) {
          o.vx = (s1.x - s0.x) / sdt;
          o.vy = (s1.y - s0.y) / sdt;
        }
      }
    };
    const move = (dx, dy, kind, ev) => {
      if (!o.enabled) return;
      if (o.pd && ev && ev.cancelable) ev.preventDefault();
      if (o.lock) {
        if (!o.axis && (dx || dy)) o.axis = Math.abs(dx) > Math.abs(dy) ? 1 : 2;
        if (o.axis === 1) dy = 0;
        else if (o.axis === 2) dx = 0;
      }
      o.accX += dx;
      o.accY += dy;
      if (Math.abs(o.accX) < o.tol && Math.abs(o.accY) < o.tol) return;
      o.dx = dx;
      o.dy = dy;
      if (dx) o.dirX = dx > 0 ? 1 : -1;
      if (dy) o.dirY = dy > 0 ? 1 : -1;
      o.kind = kind;
      o.sx += dx;
      o.sy += dy;
      pushSample(o.sx, o.sy);
      verveCallSlot(o.slot);
    };
    const on = (tgt, type, fn, opts) => {
      tgt.addEventListener(type, fn, opts);
      o.fns.push([tgt, type, fn, opts]);
    };
    if (flags & 1) {
      on(el, "wheel", (e) => move(e.deltaX, e.deltaY, 0, e), { passive: !o.pd });
    }
    if (flags & 2) {
      let tx = 0;
      let ty = 0;
      let touching = false;
      on(
        el,
        "touchstart",
        (e) => {
          const t0 = e.touches[0];
          if (!t0) return;
          touching = true;
          tx = t0.clientX;
          ty = t0.clientY;
          o.axis = 0;
          o.samples.length = 0;
        },
        { passive: true },
      );
      on(
        el,
        "touchmove",
        (e) => {
          const t0 = e.touches[0];
          if (!touching || !t0) return;
          // finger up = content scrolls down = positive deltaY (wheel parity)
          move(tx - t0.clientX, ty - t0.clientY, 1, e);
          tx = t0.clientX;
          ty = t0.clientY;
        },
        { passive: !o.pd },
      );
      on(el, "touchend", () => {
        touching = false;
      }, { passive: true });
    }
    if (flags & 4) {
      let px = 0;
      let py = 0;
      on(el, "pointerdown", (e) => {
        if (e.pointerType === "touch") return; // touch path handles it
        o.dragging = true;
        px = e.clientX;
        py = e.clientY;
        o.axis = 0;
        o.samples.length = 0;
        try {
          e.target.setPointerCapture(e.pointerId);
        } catch {}
      });
      on(el, "pointermove", (e) => {
        if (!o.dragging) return;
        move(px - e.clientX, py - e.clientY, 2, e);
        px = e.clientX;
        py = e.clientY;
      });
      on(el, "pointerup", () => {
        o.dragging = false;
      });
      on(el, "pointercancel", () => {
        o.dragging = false;
      });
    }
    if (flags & 8) {
      let ly = null;
      on(
        window,
        "scroll",
        () => {
          const y = window.scrollY || 0;
          move(0, ly == null ? 0 : y - ly, 3, null);
          ly = y;
        },
        { passive: true },
      );
    }
    observers.set(o.h, o);
    return o.h;
  };

  const obsKill = (o) => {
    for (const [tgt, type, fn, opts] of o.fns) tgt.removeEventListener(type, fn, opts);
    observers.delete(o.h);
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
    verve_event_delta_y: exp.verve_event_delta_y,
    verve_event_button: exp.verve_event_button,
    verve_event_key: exp.verve_event_key,
    verve_event_target_attr: exp.verve_event_target_attr,
    verve_event_prevent_default: exp.verve_event_prevent_default,
    verve_event_stop_propagation: exp.verve_event_stop_propagation,
    verve_event_capture_pointer: exp.verve_event_capture_pointer,
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
    verve_server_fn_post_rid: exp.verve_server_fn_post_rid,
    verve_next_req_id: exp.verve_next_req_id,
    verve_register_response_handler_once: exp.verve_register_response_handler_once,
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
    // ---- verve.anim ops (implemented JS-side, no main-client export) ----
    verve_anim_create: (dp, dl) => {
      let desc;
      try {
        desc = JSON.parse(readStr(dp, dl));
      } catch (err) {
        console.warn("verve anim: bad descriptor", err);
        return 0;
      }
      return animCreate(desc, null) >>> 0;
    },
    verve_anim_ctrl: (h, op, v) => animCtrl(h >>> 0, op >>> 0, v),
    verve_anim_get: (h, f) => animGet(h >>> 0, f >>> 0),
    verve_anim_lookup: (np, nl) => (namedAnims.get(readStr(np, nl)) || 0) >>> 0,
    verve_anim_seek_label: (h, np, nl) => {
      const a = anims.get(h >>> 0);
      if (!a || !a.lab) return;
      const t = a.lab[readStr(np, nl)];
      if (typeof t === "number") animCtrl(a.h, 4, a.delay + t);
    },
    // Dyn-value / fn-modifier slots: identity for the main client (its
    // indices already live in the shared table); makeChunkRuntime wraps
    // these with `translate` so chunk-private indices become main-table
    // slots before they're embedded in descriptor JSON.
    verve_anim_register_dyn: (idx) => idx >>> 0,
    verve_anim_register_mod: (idx) => idx >>> 0,
    // Generic per-handle style setter (gap-filler next to ref_set_attr).
    verve_ref_set_style: (h, np, nl, vp, vl) => {
      const el = refHandles[h];
      if (el) el.style.setProperty(readStr(np, nl), readStr(vp, vl));
    },
    // ---- ScrollTrigger / Observer ops -----------------------------------
    verve_sc_create: (dp, dl) => {
      let desc;
      try {
        desc = JSON.parse(readStr(dp, dl));
      } catch (err) {
        console.warn("verve scroll: bad trigger descriptor", err);
        return 0;
      }
      const sc = desc && desc.sc ? desc.sc : desc;
      return sc ? stRegister(sc, null, null) >>> 0 : 0;
    },
    // op: 0 kill, 1 refresh (handle 0 = refresh ALL), 2 disable, 3 enable
    verve_sc_ctrl: (h, op) => {
      h >>>= 0;
      op >>>= 0;
      if (h === 0 && op === 1) {
        stRefreshAll();
        stDirty = true;
        tickerKick();
        return;
      }
      const t = stTriggers.get(h);
      if (!t) return;
      if (op === 0) stKill(t);
      else if (op === 1) {
        stRefresh(t);
        stDirty = true;
        tickerKick();
      } else if (op === 2) t.enabled = false;
      else if (op === 3) {
        t.enabled = true;
        stDirty = true;
        tickerKick();
      }
    },
    // field: 0 progress, 1 active, 2 direction, 3 scroll velocity (px/s)
    verve_sc_get: (h, f) => {
      const t = stTriggers.get(h >>> 0);
      if (!t) return 0;
      switch (f >>> 0) {
        case 0: {
          const raw = (stScrollY - t.startY) / (t.endY - t.startY);
          return Math.max(0, Math.min(raw, 1));
        }
        case 1:
          return t.active ? 1 : 0;
        case 2:
          return stDir;
        case 3:
          return stVelocity();
        default:
          return 0;
      }
    },
    verve_scroll_pos: (axis) =>
      (axis >>> 0) === 0 ? window.scrollX || 0 : window.scrollY || 0,
    verve_obs_create: (flags, tol, sp, sl, handlerIdx) =>
      obsCreate(flags >>> 0, tol, sl ? readStr(sp, sl) : "", handlerIdx >>> 0) >>> 0,
    // op: 0 kill, 1 disable, 2 enable
    verve_obs_ctrl: (h, op) => {
      const o = observers.get(h >>> 0);
      if (!o) return;
      op >>>= 0;
      if (op === 0) obsKill(o);
      else if (op === 1) o.enabled = false;
      else o.enabled = true;
    },
    // field: 0 dx, 1 dy, 2 vx, 3 vy, 4 dirX, 5 dirY, 6 dragging,
    //        7 kind (0 wheel, 1 touch, 2 pointer, 3 scroll)
    verve_obs_get: (h, f) => {
      const o = observers.get(h >>> 0);
      if (!o) return 0;
      switch (f >>> 0) {
        case 0:
          return o.dx;
        case 1:
          return o.dy;
        case 2:
          return o.vx;
        case 3:
          return o.vy;
        case 4:
          return o.dirX;
        case 5:
          return o.dirY;
        case 6:
          return o.dragging ? 1 : 0;
        case 7:
          return o.kind;
        default:
          return 0;
      }
    },
  };

  // Table isolation, chunk side: each island chunk instantiates against a
  // PRIVATE function table, so its element segment (allocator vtables,
  // writer drains, `&handler` fns) can never clobber the main client's
  // entries. Chunk-internal `call_indirect` resolves through the private
  // table automatically. The only thing that needs care is a fn-pointer
  // index crossing INTO the main runtime (registerEvent, response/drop
  // handlers, timers): `translate` copies the chunk's funcref into a
  // freshly grown slot of the main table and forwards that index, so the
  // main runtime's registries and `call_indirect`/`verveCallSlot` dispatch
  // work unchanged. The chunk-idx → main-slot map is memoized so repeat
  // registrations and `cleanup(handler)` resolve to the same identity.
  const makeChunkRuntime = (chunkTable) => {
    const slotMap = new Map();
    const translate = (idx) => {
      idx = idx >>> 0;
      if (idx === 0) return 0;
      let slot = slotMap.get(idx);
      if (slot === undefined) {
        let fnref = null;
        try {
          fnref = chunkTable.get(idx);
        } catch {}
        // A chunk built without `import_table` keeps a self-defined table we
        // can't read — pass the index through untranslated (legacy behavior).
        if (!fnref) return idx;
        slot = indirectFunctionTable.grow(1);
        indirectFunctionTable.set(slot, fnref);
        slotMap.set(idx, slot);
      }
      return slot;
    };
    return {
      ...verveRuntime,
      verve_register_event: (idx) => exp.verve_register_event(translate(idx)),
      verve_cleanup: (idx) => exp.verve_cleanup(translate(idx)),
      verve_register_response_handler: (rp, rl, idx) =>
        exp.verve_register_response_handler(rp, rl, translate(idx)),
      verve_register_response_handler_once: (rp, rl, rid, idx) =>
        exp.verve_register_response_handler_once(rp, rl, rid, translate(idx)),
      verve_register_drop: (bp, bl, idx) =>
        verveRuntime.verve_register_drop(bp, bl, translate(idx)),
      verve_set_timeout: (ms, idx) => verveRuntime.verve_set_timeout(ms, translate(idx)),
      verve_set_interval: (ms, idx) => verveRuntime.verve_set_interval(ms, translate(idx)),
      verve_request_animation_frame: (idx) =>
        verveRuntime.verve_request_animation_frame(translate(idx)),
      verve_queue_microtask: (idx) => verveRuntime.verve_queue_microtask(translate(idx)),
      verve_anim_register_dyn: (idx) => translate(idx),
      verve_anim_register_mod: (idx) => translate(idx),
      // Observer handler crosses as a chunk-private fn-table index —
      // copy the funcref into the main table (timers precedent).
      verve_obs_create: (flags, tol, sp, sl, idx) =>
        verveRuntime.verve_obs_create(flags, tol, sp, sl, translate(idx)),
    };
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

  // Hand `text` to an island chunk's NAMED export `exportName(ptr, len)`:
  // stage the bytes in the island scratch buffer, scope to the island's vid,
  // call by name (never via the shared indirect function table — chunk fn
  // pointers would collide with the main client's table entries).
  const callIslandExport = (islandName, exportName, text) => {
    const chunk = chunkExports[islandName];
    if (
      !chunk ||
      typeof chunk[exportName] !== "function" ||
      typeof exp.verve_island_scratch_ptr !== "function"
    )
      return;
    const ptr = exp.verve_island_scratch_ptr();
    const cap = exp.verve_island_scratch_capacity();
    const bytes = new TextEncoder().encode(text);
    if (bytes.length > cap) return;
    new Uint8Array(memory.buffer, ptr, cap).set(bytes, 0);
    const el = document.querySelector(
      `verve-island[data-name="${islandName}"]`,
    );
    const vid = el ? parseInt(el.getAttribute("data-vid"), 10) || 0 : 0;
    if (vid && typeof exp.verve_enter_island === "function")
      exp.verve_enter_island(vid);
    try {
      chunk[exportName](ptr, bytes.length);
    } finally {
      if (vid && typeof exp.verve_exit_island === "function")
        exp.verve_exit_island();
    }
  };

  // Live-data poll loop for the viz interactive island, driven from JS so the
  // chunk needs no timer/response-handler function pointer. The chunk's
  // `viz_toggle_live` falls back to this via `host("verveVizPoll")` when
  // EventSource is unavailable; we POST `vizGraph` on an interval and hand the
  // reply to the chunk's NAMED `viz_apply_snapshot` export.
  let vizPollTimer = null;
  window.verveHost.verveVizPoll = (argsJson) => {
    let a = {};
    try {
      a = JSON.parse(argsJson || "{}");
    } catch {}
    if (vizPollTimer) {
      clearInterval(vizPollTimer);
      vizPollTimer = null;
    }
    if (!a.on) return "{}";
    const interval = a.interval || 2000;
    const tick = async () => {
      let text;
      try {
        const r = await fetch("/api/vizGraph", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: "{}",
        });
        text = await r.text();
      } catch {
        return;
      }
      callIslandExport("VizGraphInteractive", "viz_apply_snapshot", text);
    };
    vizPollTimer = setInterval(tick, interval);
    tick();
    return "{}";
  };

  // Generic server-push subscription: `{op:"sub"|"unsub", channel, island,
  // export}`. One refcounted EventSource per channel (`/push?channel=<c>`);
  // each SSE frame is delivered to the subscribed island's named export.
  // EventSource handles retry/Last-Event-ID resume natively. Returns
  // `{"err":"unsupported"}` when the host has no EventSource so the chunk can
  // fall back to polling.
  const pushChannels = new Map(); // channel → { es, subs: Map(island → export) }
  window.verveHost.vervePush = (argsJson) => {
    let a = {};
    try {
      a = JSON.parse(argsJson || "{}");
    } catch {}
    if (!a.channel || !a.island) return '{"err":"bad args"}';
    if (a.op === "unsub") {
      const entry = pushChannels.get(a.channel);
      if (entry) {
        entry.subs.delete(a.island);
        if (entry.subs.size === 0) {
          entry.es.close();
          pushChannels.delete(a.channel);
        }
      }
      return "{}";
    }
    if (typeof EventSource === "undefined") return '{"err":"unsupported"}';
    let entry = pushChannels.get(a.channel);
    if (!entry) {
      const es = new EventSource(`/push?channel=${encodeURIComponent(a.channel)}`);
      entry = { es, subs: new Map() };
      es.addEventListener(a.channel, (e) => {
        for (const [island, exportName] of entry.subs)
          callIslandExport(island, exportName, e.data);
      });
      pushChannels.set(a.channel, entry);
    }
    entry.subs.set(a.island, a.export);
    return "{}";
  };

  // Generic JS-driven animation loop for island chunks: `{island, export,
  // on}`. Each frame calls the chunk's NAMED export `fn () i32` (vid-scoped)
  // and continues while it returns nonzero — so a chunk can animate without
  // taking a function pointer (no indirect-function-table entry). One loop
  // per island|export key; re-calling with on:1 while running is a no-op;
  // `{on:0}` cancels.
  const rafLoops = new Set();
  window.verveHost.verveRafNamed = (argsJson) => {
    let a = {};
    try {
      a = JSON.parse(argsJson || "{}");
    } catch {}
    if (!a.island || !a.export) return '{"err":"bad args"}';
    const key = `${a.island}|${a.export}`;
    if (!a.on) {
      rafLoops.delete(key);
      return "{}";
    }
    if (rafLoops.has(key)) return "{}";
    rafLoops.add(key);
    const step = () => {
      if (!rafLoops.has(key)) return;
      const chunk = chunkExports[a.island];
      if (!chunk || typeof chunk[a.export] !== "function") {
        rafLoops.delete(key);
        return;
      }
      const el = document.querySelector(`verve-island[data-name="${a.island}"]`);
      const vid = el ? parseInt(el.getAttribute("data-vid"), 10) || 0 : 0;
      if (vid && typeof exp.verve_enter_island === "function")
        exp.verve_enter_island(vid);
      let cont = 0;
      try {
        cont = chunk[a.export]();
      } finally {
        if (vid && typeof exp.verve_exit_island === "function")
          exp.verve_exit_island();
      }
      if (cont) requestAnimationFrame(step);
      else rafLoops.delete(key);
    };
    requestAnimationFrame(step);
    return "{}";
  };

  // One-shot fetch routed to an island export: `{api, island, export}` POSTs
  // `/api/<api>` and delivers the reply text to the named export. This is the
  // push path's resync hook, reusable by any island.
  window.verveHost.verveFetchExport = (argsJson) => {
    let a = {};
    try {
      a = JSON.parse(argsJson || "{}");
    } catch {}
    if (!a.api || !a.island || !a.export) return '{"err":"bad args"}';
    fetch(`/api/${a.api}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{}",
    })
      .then((r) => r.text())
      .then((text) => callIslandExport(a.island, a.export, text))
      .catch(() => {});
    return "{}";
  };

  const loadIslandChunk = async (el, instanceId) => {
    const name = el.getAttribute("data-name") || "";
    if (!name) return;
    const url = `/islands/${name}.wasm`;
    if (!islandChunks.has(name)) {
      // PRIVATE table per chunk — see makeChunkRuntime. The chunk's element
      // segment writes here, never into the main client's table.
      const chunkTable = new WebAssembly.Table({
        initial: 256,
        element: "anyfunc",
      });
      islandChunks.set(
        name,
        WebAssembly.instantiateStreaming(fetch(url), {
          env: {
            memory,
            __indirect_function_table: chunkTable,
          },
          verve_runtime: makeChunkRuntime(chunkTable),
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
  // Declarative entrance animations stamped by Node.animate().
  animScan(document.body);

  new MutationObserver((records) => {
    for (const rec of records) {
      rec.removedNodes.forEach((n) => eachIslandIn(n, unmountIslandEl));
      rec.addedNodes.forEach((n) => {
        eachIslandIn(n, hydrateIslandEl);
        // New subtrees (Suspense swaps, SPA navigations, template
        // clones) may carry their own [data-anim] markers.
        if (n instanceof Element) animScan(n);
      });
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
