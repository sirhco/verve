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

  // P7 multi-instance gl: route a dispatch (frame / event / asset callback /
  // restore) to the right GlScene instance by its island vid. `glscene_select`
  // exists only on stateful gl chunks; the guard makes the call a no-op for
  // GlDemo and every non-gl island, leaving the generic island machinery
  // unchanged. `glHydratingVid` carries the in-flight hydrate's vid so async
  // `gl_load` callbacks can re-select the requesting instance.
  let glHydratingVid = 0;
  // Last instance selected for a frame/event dispatch — lets a gl_load issued from
  // a FRAME (e.g. streaming external textures) route its async callback back to the
  // right instance, since glHydratingVid is only set during hydrate.
  let glCurrentVid = 0;
  const glSelect = (exports, vid) => {
    glCurrentVid = vid >>> 0;
    if (vid && exports && typeof exports.glscene_select === "function")
      exports.glscene_select(vid >>> 0);
  };
  const vidOfEl = (el) => {
    const isl = el && el.closest && el.closest("verve-island");
    return isl ? parseInt(isl.getAttribute("data-vid"), 10) || 0 : 0;
  };

  // T3: Write per-frame frustum-cull stats into the [data-ref="glcull-hud"] element.
  // Encoding: glscene_cull_stats() returns drawn|(culled<<8)|(sdraw<<16)|(scull<<24).
  // Guard: no-op when the element is absent (every demo except /gl-cull).
  // glscene_select has already been called before the frame export, so `current`
  // in wasm is the right instance when this runs synchronously after the frame.
  const glCullHudUpdate = (exports) => {
    if (typeof exports.glscene_cull_stats !== "function") return;
    const hudEl = document.querySelector('[data-ref="glcull-hud"]');
    if (!hudEl) return;
    const packed = exports.glscene_cull_stats() >>> 0;
    const d  = packed & 0xff;
    const c  = (packed >>> 8) & 0xff;
    const sd = (packed >>> 16) & 0xff;
    const sc = (packed >>> 24) & 0xff;
    hudEl.textContent = `drawn ${d} / culled ${c} / ${d + c} · shadow ${sd}/${sc}`;
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
    // Route to the right gl instance (no-op unless this is a stateful gl chunk).
    if (islandName) glSelect(chunkExports[islandName], vid);
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
      if (islandName) glSelect(chunkExports[islandName], vid);
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
  // gl-target write: hand the eased value to the registered gl setter
  // `fn(target_id, value)` (verve_anim_register_setter). Slot arrives
  // already translated into the main table (same as dyn/mod).
  const animCallGlSetter = (slot, id, v) => {
    try {
      const fn = indirectFunctionTable.get(slot >>> 0);
      if (typeof fn === "function") fn(id >>> 0, v);
    } catch (e) {
      console.error("verve: anim gl setter failed:", e);
    }
  };
  // Page-default gl setter slot: last island to call verve_anim_register_setter wins.
  // Timelines parsed before the gl island hydrates use this at write time (P7: per-island).
  let defaultGlSlot = 0;
  // Page-default gl deferred-target resolver slot (SSR material:/node: tweens).
  let defaultGlResolver = 0;

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
        // smoother off first — page returns to native scrolling
        smootherKill();
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
        // finalize active FLIPs: snap to identity, fire callbacks
        for (const f of [...flips.values()]) {
          const cb = f.cb;
          flipKill(f, true);
          if (cb) animFireSlot(cb.sC);
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
    // gl-target tweens ("@gl:<id>" props) drive the gl engine through the
    // registered setter, NOT the DOM — they legitimately match zero DOM
    // elements. Run such a tween as ONE virtual instance (null element) so the
    // scrub/write pipeline still executes; animWriteProp's gl branch ignores
    // the element. Mixed gl+DOM tweens keep their real targets.
    const hasGl = tweenHasGl(c.p);
    if (targets.length === 0 && hasGl) targets = [null];
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
      hasGl,
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
      if (!el) return { n: 0 }; // gl-only virtual instance: no DOM to read
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
        // gl-target prop ("@gl:<target_id>"): the value lives in the gl
        // engine, not the DOM — no element read, no DOM write. Wire facts:
        // spec = {gl:<u32 target_id>, gls:<u32 setter_slot>, to:<num>, f?:<num>}.
        // from defaults to 0 (the engine value at tween start is unknowable
        // JS-side, so the contract is deterministic 0→to; authors set a
        // nonzero start via glTargetFrom which emits an explicit "f").
        if (name.startsWith("@gl")) {
          per[name] = glTweenState(spec);
          continue;
        }
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

  // gl-target tween state from a "@gl:<id>" prop spec. Wire facts: spec =
  // {gl:<u32 target_id>, gls:<u32 setter_slot>, to:<num>, f?:<num>}. The
  // engine value at tween start is unknowable JS-side, so from defaults to
  // a deterministic 0 (authors set a nonzero start via glTargetFrom, which
  // emits an explicit "f"). 0→to fits scrub usage (e.g. yaw 0→2π).
  // @verve-extract glTweenState
  const glTweenState = (spec) => ({
    kind: "gl",
    gl: spec.gl >>> 0,
    gls: spec.gls >>> 0,
    // Deferred SSR target: FNV name hash (0 = already resolved). Resolved once
    // on the first tick via the gl resolver, then cached back into `gl`.
    gh: spec.gh >>> 0,
    glr: 0, // per-instance resolver slot (0 = use page-default resolver)
    from: typeof spec.f === "number" ? spec.f : 0,
    to: typeof spec.to === "number" ? spec.to : 0,
    unit: null,
  });
  // @verve-extract-end

  // True when a tween's prop set contains any gl-target ("@gl:<id>") prop.
  // Such a tween drives the gl engine through the registered setter and has
  // NO DOM element to animate — it must survive zero-matched-target rejection
  // (animCreate) and the detached-target self-kill (the ticker liveness check),
  // running as a single virtual instance (null element) instead.
  // @verve-extract tweenHasGl
  const tweenHasGl = (props) =>
    !!props && Object.keys(props).some((k) => k.startsWith("@gl"));
  // @verve-extract-end

  const animWriteProp = (el, name, st, phase, easeFn, mods) => {
    // gl-target: interpolate from→to like the numeric path, apply this
    // prop's modifiers, then hand the value to the gl setter. MUST return
    // before any DOM write — `el` is the inert selfEl fallback (the island
    // host) and has no styles/attrs to touch for a gl tween.
    if (st.kind === "gl") {
      // Slot 0 = "page default" (SSR tweens). Unresolved (gl island not yet
      // hydrated) → drop the write; later ticks retry. A default slot that
      // outlives its island is benign: chunk instances and their statics
      // persist for the page life, and unmount stops the gl frame loop, so
      // a stale setter writes inert statics, never the GPU (P7: per-island).
      // Deferred SSR target (material:/node:): resolve name_hash → frozen id
      // once, via the registered gl resolver, then cache it. Unresolved (no
      // resolver yet, or mesh not loaded / name absent) → drop + retry next tick.
      if (st.gh !== 0) {
        const resolver = st.glr || defaultGlResolver;
        if (!resolver) return;
        const real =
          indirectFunctionTable.get(resolver >>> 0)(st.gl >>> 0, st.gh >>> 0) >>> 0;
        if (!real) return;
        st.gl = real;
        st.gh = 0;
      }
      const slot = st.gls || defaultGlSlot;
      if (!slot) return;
      let v = st.from + (st.to - st.from) * easeFn(phase);
      const fns = mods[name];
      if (fns) for (const f of fns) v = f(v);
      animCallGlSetter(slot, st.gl, v);
      return;
    }
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
      // null el = gl-only virtual instance (writes via the gl setter, no DOM);
      // a real-but-detached element is skipped as before.
      if (el && !el.isConnected) continue;
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
      if (tw.mp && el) animWriteMotionPath(el, tw.mp, f.phase, tw.easeFn, tw.mods);
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
    // Smoother first (triggers must see this frame's smoothed Y), then
    // scroll triggers, inertia throws, and FLIP plays — all before time
    // integration.
    if (smoother) smootherUpdate(dt);
    if (stTriggers.size) stUpdate(dt);
    if (dragThrowing > 0) dragUpdate(dt);
    if (flipActive > 0) flipUpdate(dt);
    for (const a of [...anims.values()]) {
      if (a.paused || a.done) continue;
      // Self-kill animations whose targets all left the document
      // (SPA swaps, removed subtrees). Silent, like GSAP kill. gl-only tweens
      // have no DOM target but stay live (the gl engine persists).
      if (!a.tweens.some((tw) => tw.hasGl || tw.targets.some((el) => el && el.isConnected))) {
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
    // gl canvases render AFTER the anim engine so gl-setter writes made
    // this frame are visible to the chunk's frame export this frame.
    // Iterate a copy: sinks delete themselves on stop paths mid-iteration.
    for (const s of [...glSinks]) s(now);
    // Keep ticking while time-driven anims run, scroll work remains
    // (fresh scroll events / unsettled scrub smoothing set stDirty), or
    // inertia throws are in flight — or any gl canvas loop is live.
    if (stDirty || smActive || dragThrowing > 0 || flipActive > 0 || glSinks.size > 0 || (anims.size && [...anims.values()].some((a) => !a.paused && !a.done))) {
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

  // ---- SplitText lines grouping ----------------------------------------
  // SSR emits word spans + data-split-lines (src/core/anim/split.zig);
  // line wrap depends on layout, so grouping happens here: consecutive
  // word spans sharing an offsetTop wrap into line elements. Runs ONCE at
  // scan (late fonts / resize can stale lines — documented, GSAP-parity).
  // MUST run BEFORE animScan on the same root: animations targeting
  // .st-line resolve their targets at create time.

  // Pure: offsetTop array -> [start, end) index runs (0.5px jitter).
  // @verve-extract splitLineRuns
  const splitLineRuns = (tops) => {
    const runs = [];
    let s = 0;
    for (let i = 1; i <= tops.length; i++) {
      if (i === tops.length || Math.abs(tops[i] - tops[s]) > 0.5) {
        runs.push([s, i]);
        s = i;
      }
    }
    return runs;
  };
  // @verve-extract-end

  const splitLinesApply = (el) => {
    const cls = el.getAttribute("data-split-lines") || "st-line";
    const wrap = el.querySelector("[data-split-wrap]");
    if (!wrap) return;
    const words = Array.from(wrap.children);
    if (!words.length) return;
    const tops = words.map((w) => w.offsetTop); // measure ALL before mutating
    const runs = splitLineRuns(tops);
    const nodes = Array.from(wrap.childNodes); // spans + whitespace text
    const frag = document.createDocumentFragment();
    let line = null;
    let run = 0;
    let wi = 0;
    for (const n of nodes) {
      if (n.nodeType === 1) {
        if (!line || wi === runs[run][1]) {
          if (line) run++;
          line = document.createElement("span");
          line.className = cls;
          line.style.display = "block"; // can't assume the stylesheet
          frag.appendChild(line);
        }
        line.appendChild(n);
        wi++;
      } else if (line) {
        line.appendChild(n); // whitespace rides its line
      }
    }
    wrap.textContent = "";
    wrap.appendChild(frag);
  };

  const splitLinesScan = (root) => {
    const list = [];
    if (root instanceof Element) {
      if (root.hasAttribute("data-split-lines")) list.push(root);
      root.querySelectorAll("[data-split-lines]").forEach((el) => list.push(el));
    } else if (root && root.querySelectorAll) {
      root.querySelectorAll("[data-split-lines]").forEach((el) => list.push(el));
    }
    for (const el of list) {
      if (el.hasAttribute("data-split-lines-done")) continue;
      el.setAttribute("data-split-lines-done", "1");
      splitLinesApply(el);
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
  // Per-scroller-element scroll listeners: Map<el, {count, listener, ro}>
  const stScrollerListeners = new Map();
  // ScrollSmoother singleton (installed by smootherScan; null = native).
  let smoother = null;
  let smActive = false; // smoother/lag unsettled — ticker keep-alive
  // Effective scroll for trigger/pin math: the SMOOTHED value when a
  // smoother is installed (visual sync), native scrollY otherwise. Snap
  // deliberately stays in native-Y space.
  const stEffY = () => (smoother ? smoother.y : stScrollY);

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
        // Under a smoother, pins follow the smoothed Y in the ticker —
        // sync-in-listener writes would lead the visual.
        if (!smoother) {
          for (const t of stTriggers.values()) if (t.pinEl) stApplyPin(t);
        }
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
    // Resolve container scroller: handle wins over selector; null = window.
    let scrollerEl = null;
    if (sc.slh != null) scrollerEl = refHandles[sc.slh] || null;
    else if (sc.sl) scrollerEl = document.querySelector(sc.sl) || null;
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
      // snap is programmatic motion — disabled under reduced motion
      snap: prefersReduced ? null : sc.snap != null ? sc.snap : null,
      snapd: sc.snapd || 0.4,
      snape: sc.snape || "outCubic",
      snapdir: !!sc.snapdir,
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
      scroller: scrollerEl,
    };
    if (sc.pin && !prefersReduced) {
      t.pinEl = sc.pin === 1 ? el : sc.pin.s ? (selfEl || document).querySelector(sc.pin.s) : null;
    }
    if (scrollerEl) {
      let entry = stScrollerListeners.get(scrollerEl);
      if (!entry) {
        const listener = () => { stDirty = true; tickerKick(); };
        let ro = null;
        try {
          ro = new ResizeObserver(() => {
            stRefreshAll();
            stDirty = true;
            tickerKick();
          });
          ro.observe(scrollerEl);
        } catch {}
        scrollerEl.addEventListener("scroll", listener, { passive: true });
        entry = { count: 0, listener, ro };
        stScrollerListeners.set(scrollerEl, entry);
      }
      entry.count++;
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
    // Window scroll offset, function-scoped: feeds the non-scroller absTop
    // AND the pin geometry below (t.pinTop). Must stay out here — the pin
    // block runs regardless of branch. (Pins don't compose with element
    // scrollers, a documented v1 limit; y0 is harmless/unused there.)
    const y0 = stEffY();
    let absTop, vh;
    if (t.scroller) {
      // Scroller-relative: trigger's offset into the scroller's scroll
      // content = (el.getBoundingClientRect().top - scroller.getBoundingClientRect().top)
      // + scroller.scrollTop. "viewport" height = scroller clientHeight.
      const sr = t.scroller.getBoundingClientRect();
      absTop = (r.top - sr.top) + t.scroller.scrollTop;
      vh = t.scroller.clientHeight || 1;
    } else {
      // Under a smoother, native scroll doesn't move the fixed subtree —
      // only the content translate does, so gBCR.top = naturalTop - sm.y
      // ALWAYS and adding stEffY() recovers the document offset EXACTLY
      // (even mid-settle). Without a smoother this is the classic formula.
      absTop = r.top + y0;
      vh = window.innerHeight || 0;
    }
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
      // transform-pin base: any pre-existing/tweened translate on the
      // pinned element, captured in the unpinned state (post-clear)
      t.pinBaseY = getXform(t.pinEl).y;
      stEnsureSpacer(t);
      t.pinState = -1;
      stApplyPin(t);
    }
    if (t.markers) stPlaceMarkers(t);
  };

  // Document-order refresh: pin spacers pad layout, so triggers below a
  // pin must measure AFTER its spacer is sized.
  const stRefreshAll = () => {
    // spacer/body height first — trigger geometry below depends on it
    if (smoother) smootherRefresh();
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
    if (smoother) {
      // Transform-pin: position:fixed breaks inside the smoother's
      // transformed content (the transform makes it the containing
      // block). Counter-translate instead — composes with scale/rotate
      // tweens via the shared composer. Before/active/after collapse
      // into one clamp.
      const off = Math.min(Math.max(stEffY() - t.startY, 0), t.pinSpan);
      const s = getXform(t.pinEl);
      const want = (t.pinBaseY || 0) + off;
      if (s.y !== want) {
        s.y = want;
        writeXform(t.pinEl);
      }
      return;
    }
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
    if (smoother) {
      const s = getXform(t.pinEl);
      s.y = t.pinBaseY || 0;
      writeXform(t.pinEl);
      t.pinState = -1;
      return;
    }
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
      // markers must live in the visually-moving space under a smoother
      (smoother ? smoother.content : document.body).appendChild(d);
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
    if (t.scroller) {
      const entry = stScrollerListeners.get(t.scroller);
      if (entry) {
        entry.count--;
        if (entry.count <= 0) {
          t.scroller.removeEventListener("scroll", entry.listener);
          if (entry.ro) try { entry.ro.disconnect(); } catch {}
          stScrollerListeners.delete(t.scroller);
        }
      }
    }
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

  // ---- ScrollTrigger snap ------------------------------------------------
  // When input goes idle near/inside a snap-enabled trigger's span, glide
  // the NATIVE scrollY so progress lands on the nearest snap point. All
  // snap math stays in native-Y space — under a smoother the visual
  // trails the glide and settles after (GSAP-like).

  let snapGlide = null; // { from, to, t, dur, lastY }
  let snapPending = false; // off-point candidate exists; keeps ticker alive
  const SNAP_VEL = 20; // px/s — "scrolling has stopped"
  const SNAP_IDLE_MS = 120;
  const SNAP_EPS = 2; // px — already on a point

  // Snap target in progress space. cfg = step (number) or sorted points
  // (array). dir breaks exact ties: >= 0 picks the higher point.
  // @verve-extract stSnapResolve
  const stSnapResolve = (cfg, p, dir, directional) => {
    if (typeof cfg === "number") {
      const lo = Math.max(0, Math.min(1, Math.floor(p / cfg) * cfg));
      const hi = Math.min(1, lo + cfg);
      const dLo = p - lo;
      const dHi = hi - p;
      if (directional && dir !== 0) {
        // prefer the candidate in the direction of travel
        if (dir > 0 && hi <= 1) return hi;
        if (dir < 0 && lo >= 0) return lo;
      }
      if (dLo === dHi) return dir >= 0 ? hi : lo;
      return dLo < dHi ? lo : hi;
    }
    // points form
    if (directional && dir !== 0) {
      // collect candidates in the direction of travel
      let dirBest = null;
      let dirBestD = Infinity;
      let nearBest = cfg[0];
      let nearBestD = Math.abs(p - cfg[0]);
      for (let i = 0; i < cfg.length; i++) {
        const d = Math.abs(p - cfg[i]);
        if (d < nearBestD || (d === nearBestD && dir >= 0)) { nearBest = cfg[i]; nearBestD = d; }
        const inDir = dir > 0 ? cfg[i] >= p : cfg[i] <= p;
        if (inDir && (d < dirBestD || (d === dirBestD && dir >= 0))) { dirBest = cfg[i]; dirBestD = d; }
      }
      return dirBest !== null ? dirBest : nearBest;
    }
    let best = cfg[0];
    let bd = Math.abs(p - cfg[0]);
    for (let i = 1; i < cfg.length; i++) {
      const d = Math.abs(p - cfg[i]);
      if (d < bd || (d === bd && dir >= 0)) {
        best = cfg[i];
        bd = d;
      }
    }
    return best;
  };
  // @verve-extract-end

  const stSnapCheck = (now) => {
    snapPending = false;
    if (snapGlide) return;
    let best = null;
    for (const t of stTriggers.values()) {
      if (t.snap == null || !t.enabled || !t.el || !t.el.isConnected) continue;
      if (t.scroller) continue; // snap is window-scoped; element scrollers silently misfire
      const span = t.endY - t.startY;
      const margin = Math.min(span * 0.25, (window.innerHeight || 0) * 0.25);
      if (stScrollY < t.startY - margin || stScrollY > t.endY + margin) continue;
      const p = Math.max(0, Math.min((stScrollY - t.startY) / span, 1));
      const target = t.startY + stSnapResolve(t.snap, p, stDir, t.snapdir) * span;
      const dist = Math.abs(target - stScrollY);
      if (dist <= SNAP_EPS) continue;
      snapPending = true; // keep ticker alive through the idle window
      if (!best || dist < best.dist) best = { y: target, dist, dur: t.snapd, ease: t.snape };
    }
    if (!best) return;
    if (Math.abs(stVelocity()) > SNAP_VEL) return;
    if (!stVelT || now - stVelT < SNAP_IDLE_MS) return;
    snapGlide = { from: stScrollY, to: best.y, t: 0, dur: best.dur, ease: best.ease, lastY: stScrollY };
  };

  const stSnapGlide = (dt) => {
    const g = snapGlide;
    // User intervened (wheel, touch momentum, anchor jump): native
    // scrollY deviated from our last write -> cancel. No extra listeners.
    if (Math.abs((window.scrollY || 0) - g.lastY) > SNAP_EPS) {
      snapGlide = null;
      return;
    }
    g.t += dt;
    const k = Math.min(1, g.t / g.dur);
    const e = easeFnOf(g.ease)(k);
    // behavior:"instant" defeats CSS scroll-behavior:smooth, which would
    // turn each per-frame write into its own competing animation.
    window.scrollTo({ top: g.from + (g.to - g.from) * e, behavior: "instant" });
    g.lastY = window.scrollY || 0; // browser may clamp/round
    if (k >= 1) snapGlide = null;
  };

  // Per-frame trigger pass: boundary edges -> actions/class/callbacks,
  // scrub -> seek. Clears stDirty unless scrub smoothing, a snap glide,
  // or a pending snap candidate remains.
  const stUpdate = (dt) => {
    const y = stEffY();
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
      // transform-pins follow the smoothed Y per frame (listener path
      // skips pins when a smoother is installed)
      if (t.pinEl && smoother) stApplyPin(t);
      // Container scroller triggers use the scroller's scrollTop;
      // window triggers use the effective (possibly smoothed) scrollY.
      const ty = t.scroller ? t.scroller.scrollTop : y;
      const wasActive = t.active;
      const active = ty >= t.startY && ty < t.endY;
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
        } else if (ty >= t.endY) {
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
        const raw = Math.max(0, Math.min((ty - t.startY) / (t.endY - t.startY), 1));
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
    if (snapGlide) stSnapGlide(dt);
    else stSnapCheck(performance.now());
    stDirty = unsettled || !!snapGlide || snapPending;
  };

  // ---- ScrollSmoother (phase 6) ------------------------------------------
  // Native-scroll-preserving smoothing: viewport-fixed wrapper + content
  // translated by -smoothedY + a body-height spacer keep the scrollbar,
  // keyboard, anchors, find-in-page, and a11y fully native — only the
  // visual position eases. One per page; config rides the
  // data-smooth-wrapper attribute (src/core/anim/smoother.zig).

  const smootherFx = (dt) => {
    const sm = smoother;
    if (!sm.fx.length) return false;
    const vh = window.innerHeight || 0;
    const effY = sm.y;
    let busy = false;
    for (const e of sm.fx) {
      if (!e.el.isConnected) continue;
      const targetOff = e.sp != null ? (effY + vh / 2 - e.center) * (1 - e.sp) : 0;
      // activity clamp: skip work beyond one viewport outside the band
      const visualTop = e.center - e.h / 2 - effY + e.cur;
      const active = visualTop < 2 * vh && visualTop + e.h > -vh;
      if (!active) {
        if (e.cur !== targetOff) {
          e.cur = targetOff; // snap so re-entry is seamless
          const s = getXform(e.el);
          s.y = e.base + e.cur;
          animDirty.add(e.el);
        }
        continue;
      }
      if (e.lag > 0) {
        e.cur += (targetOff - e.cur) * Math.min(1, dt / e.lag);
        if (Math.abs(targetOff - e.cur) < 0.05) e.cur = targetOff;
        if (e.cur !== targetOff) busy = true;
      } else {
        e.cur = targetOff;
      }
      const s = getXform(e.el);
      if (s.y !== e.base + e.cur) {
        s.y = e.base + e.cur;
        animDirty.add(e.el);
      }
    }
    flushXform(); // fx writes flush here — flushXform only auto-runs in animRenderAt
    return busy;
  };

  const smootherUpdate = (dt) => {
    const sm = smoother;
    if (!sm.content.isConnected) {
      smootherKill();
      return;
    }
    const target = Math.max(0, Math.min(stScrollY, sm.max));
    const prev = sm.y;
    if (sm.smooth > 0) {
      sm.y += (target - sm.y) * Math.min(1, dt / sm.smooth);
      if (Math.abs(target - sm.y) < 0.05) sm.y = target;
    } else {
      sm.y = target;
    }
    sm.vel = dt > 0 ? (sm.y - prev) / dt : 0;
    if (sm.y !== sm.lastWrite) {
      sm.content.style.transform = `translate3d(0px,${-sm.y}px,0px)`;
      sm.lastWrite = sm.y;
    }
    const lagBusy = smootherFx(dt);
    smActive = sm.y !== target || lagBusy;
  };

  const smootherRefresh = () => {
    const sm = smoother;
    if (!sm || !sm.content.isConnected) return;
    // revert fx so measurements see natural layout
    for (const e of sm.fx) {
      if (!e.el.isConnected) continue;
      const s = getXform(e.el);
      s.y = e.base;
      writeXform(e.el);
    }
    const h = sm.content.offsetHeight; // transform-immune
    sm.spacer.style.height = h + "px";
    sm.max = Math.max(0, h - (window.innerHeight || 0));
    if (sm.y > sm.max) sm.y = sm.max;
    for (const e of sm.fx) {
      if (!e.el.isConnected) continue;
      const r = e.el.getBoundingClientRect();
      e.center = r.top + r.height / 2 + sm.y;
      e.h = r.height;
      e.base = getXform(e.el).y;
      const s = getXform(e.el);
      s.y = e.base + e.cur;
      writeXform(e.el);
    }
  };

  const smootherKill = () => {
    const sm = smoother;
    if (!sm) return;
    smoother = null; // null FIRST so stClearPin/stRefresh take native paths
    smActive = false;
    if (sm.ro) sm.ro.disconnect();
    if (sm.spacer) sm.spacer.remove();
    if (sm.content.isConnected) {
      sm.content.style.transform = "";
      const ws = sm.wrap.style;
      ws.position = "";
      ws.top = "";
      ws.left = "";
      ws.width = "";
      ws.height = "";
      ws.overflow = "";
      for (const e of sm.fx) {
        if (!e.el.isConnected) continue;
        const s = getXform(e.el);
        s.y = e.base;
        writeXform(e.el);
      }
    }
    stRefreshAll();
  };

  const smootherScan = (root) => {
    // defensive: SPA swap followed by scan before any tick ran
    if (smoother && !smoother.content.isConnected) smootherKill();
    const list = [];
    if (root instanceof Element) {
      if (root.hasAttribute("data-smooth-wrapper")) list.push(root);
      root.querySelectorAll("[data-smooth-wrapper]").forEach((el) => list.push(el));
    } else if (root && root.querySelectorAll) {
      root.querySelectorAll("[data-smooth-wrapper]").forEach((el) => list.push(el));
    }
    for (const wrap of list) {
      if (wrap.hasAttribute("data-smooth-done")) continue;
      wrap.setAttribute("data-smooth-done", "1");
      if (smoother) {
        console.warn("verve smooth: one smoother per page");
        continue;
      }
      let cfg = {};
      try {
        cfg = JSON.parse(wrap.getAttribute("data-smooth-wrapper") || "{}") || {};
      } catch {}
      const content = wrap.querySelector("[data-smooth-content]");
      if (!content) continue;
      const isTouch = (() => {
        try {
          return window.matchMedia("(hover: none) and (pointer: coarse)").matches;
        } catch {
          return false;
        }
      })();
      const smooth = isTouch ? cfg.tch || 0 : cfg.sm != null ? cfg.sm : 1;
      const wantFx = cfg.px !== 0;
      const fxEls = wantFx
        ? Array.from(content.querySelectorAll("[data-speed],[data-lag]"))
        : [];
      // reduced motion, or nothing to smooth and no effects: stay native
      if (prefersReduced || (smooth === 0 && fxEls.length === 0)) continue;

      const ws = wrap.style;
      ws.position = "fixed";
      ws.top = "0";
      ws.left = "0";
      ws.width = "100%";
      ws.height = "100%";
      ws.overflow = "hidden";
      const spacer = document.createElement("div");
      spacer.setAttribute("data-verve-smooth-spacer", "");
      document.body.appendChild(spacer);

      smoother = {
        wrap,
        content,
        spacer,
        ro: null,
        smooth,
        y: window.scrollY || 0,
        lastWrite: -1,
        vel: 0,
        max: 0,
        fx: fxEls.map((el) => ({
          el,
          sp: el.hasAttribute("data-speed") ? parseFloat(el.getAttribute("data-speed")) : null,
          lag: el.hasAttribute("data-lag") ? parseFloat(el.getAttribute("data-lag")) || 0 : 0,
          center: 0,
          h: 0,
          base: 0,
          cur: 0,
        })),
      };
      // content growth (islands, images) without window events
      try {
        let roRaf = 0;
        smoother.ro = new ResizeObserver(() => {
          if (roRaf) return;
          roRaf = requestAnimationFrame(() => {
            roRaf = 0;
            stRefreshAll();
            stDirty = true;
            tickerKick();
          });
        });
        smoother.ro.observe(content);
      } catch {}
      smootherRefresh();
      smActive = true;
      tickerKick();
    }
  };

  // Shared velocity tracker: ~6-sample / 100ms ring buffer over any
  // record carrying { samples, vx, vy }. Used by Observer and Drag.
  const velPush = (o, x, y) => {
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
    const pushSample = (x, y) => velPush(o, x, y);
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

  // ---- Verve Drag ------------------------------------------------------
  // Draggable engine ("dr" wire key — src/core/anim/drag.zig +
  // serialize.zig goldens are the contract). Pointer capture + state
  // machine + analytic inertia. Position writes go through xformCache
  // (engine owns style.transform), so rotate/scale/opacity tweens compose
  // with an active drag; tweening x/y mid-drag is last-writer (documented).

  const drags = new Map();
  let dragSeq = 1;
  let dragThrowing = 0;
  const DRAG_DEFAULT_RETENTION = 0.05; // velocity kept per second
  const DRAG_MIN_THROW = 50; // px/s

  const dclamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));

  // Remaining travel of exponential friction v(t) = v * r^t, integrated
  // to rest: v / ln(1/r).
  // @verve-extract dragProject
  const dragProject = (v, r) => v / Math.log(1 / r);
  // @verve-extract-end

  // Drop-zone hit test: rects as [l, t, r, b] in page coords; first
  // match in DOM order wins on overlap; -1 on miss.
  // @verve-extract dragZoneHit
  const dragZoneHit = (rects, x, y) => {
    for (let i = 0; i < rects.length; i++) {
      const r = rects[i];
      if (x >= r[0] && x <= r[2] && y >= r[1] && y <= r[3]) return i;
    }
    return -1;
  };
  // @verve-extract-end

  // Elastic wall reflection for a single axis during inertia throw.
  // Returns updated {pos, endpoint} after reflecting off a wall.
  // bounce: elasticity 0..1 (0 = hard clamp, 1 = fully elastic).
  // The endpoint shifts symmetrically so the exponential-approach integrator
  // naturally decelerates toward the new reflected endpoint.
  // @verve-extract dragBounce
  const dragBounceReflect = (pos, endpoint, wall, bounce) => {
    // overshoot distance past the wall
    const over = pos - wall;
    // reflected position sits equally on the inside of the wall
    const rpos = wall - over * bounce;
    // new endpoint mirrors the old endpoint's overshoot, damped by bounce
    const endOver = endpoint - wall;
    const rendpoint = wall - endOver * bounce;
    return { pos: rpos, endpoint: rendpoint };
  };
  // @verve-extract-end

  // @verve-extract dragSnapResolve
  const dragSnapResolve = (sn, x, y) => {
    if (!sn) return [x, y];
    if (sn.g) {
      return [Math.round(x / sn.g[0]) * sn.g[0], Math.round(y / sn.g[1]) * sn.g[1]];
    }
    if (sn.p) {
      let bi = 0;
      let bd = Infinity;
      for (let i = 0; i < sn.p.length; i += 2) {
        const ddx = sn.p[i] - x;
        const ddy = sn.p[i + 1] - y;
        const d2 = ddx * ddx + ddy * ddy;
        if (d2 < bd) {
          bd = d2;
          bi = i;
        }
      }
      return [sn.p[bi], sn.p[bi + 1]];
    }
    return [x, y];
  };
  // @verve-extract-end

  // Convert a bounds spec into translate-space limits, measured ONCE per
  // gesture (both rects read in the same scroll context — the range is
  // scroll-invariant for the rest of the gesture).
  const dragResolveBounds = (d, s) => {
    d.minX = d.minY = -Infinity;
    d.maxX = d.maxY = Infinity;
    const b = d.boundsSpec;
    if (!b) return;
    if (Array.isArray(b)) {
      [d.minX, d.maxX, d.minY, d.maxY] = b;
      return;
    }
    const bel = b.h != null ? refHandles[b.h] : document.querySelector(b.s);
    if (!bel) return;
    const br = bel.getBoundingClientRect();
    const r = d.el.getBoundingClientRect(); // includes current translate
    d.minX = br.left - (r.left - s.x);
    d.maxX = br.right - (r.right - s.x);
    d.minY = br.top - (r.top - s.y);
    d.maxY = br.bottom - (r.bottom - s.y);
    if (d.maxX < d.minX) d.maxX = d.minX; // target wider than bounds
    if (d.maxY < d.minY) d.maxY = d.minY;
  };

  const dragStopThrow = (d) => {
    if (d.throwing) {
      d.throwing = false;
      dragThrowing--;
    }
  };

  const dragClearZoneHover = (d) => {
    if (d.zoneCls && d.hover >= 0 && d.zoneEls[d.hover]) {
      d.zoneEls[d.hover].classList.remove(d.zoneCls);
    }
    d.hover = -1;
  };

  const dragKill = (d) => {
    drags.delete(d.h);
    dragStopThrow(d);
    dragClearZoneHover(d);
    for (const [tgt, type, fn, opts] of d.fns) tgt.removeEventListener(type, fn, opts);
    if (d.cls && d.el) d.el.classList.remove(d.cls);
  };

  const dragDisable = (d) => {
    d.enabled = false;
    d.pid = null;
    dragStopThrow(d);
    dragClearZoneHover(d);
    if (d.engaged) {
      d.engaged = false;
      if (d.cls) d.el.classList.remove(d.cls);
      if (d.cur) d.grip.style.cursor = "grab";
    }
  };

  // Release: project the inertia endpoint analytically (clamp + snap the
  // ENDPOINT — the element decelerates into walls and lands exactly on
  // snap), then exponential-approach in the ticker. Velocity-continuous
  // at release; the same integrator handles zero-velocity snap-settles.
  const dragRelease = (d) => {
    const s = getXform(d.el);
    const r = d.hasInertia ? d.retention : DRAG_DEFAULT_RETENTION;
    d.k = Math.log(1 / r);
    const speed = Math.hypot(d.vx, d.vy);
    let ex = s.x;
    let ey = s.y;
    if (d.hasInertia && speed >= DRAG_MIN_THROW) {
      ex += dragProject(d.vx, r);
      ey += dragProject(d.vy, r);
    }
    // bounce > 0: skip hard clamp — the frame integrator bounces off walls
    if (!d.bounce) {
      ex = dclamp(ex, d.minX, d.maxX);
      ey = dclamp(ey, d.minY, d.maxY);
    }
    // snap runs on possibly-out-of-bounds ex/ey when bounce is active; a snap
    // target landing at/just outside a wall produces one extra bounce frame — acceptable
    // because snap grids are designed to land inside bounds.
    const snapped = dragSnapResolve(d.snap, ex, ey);
    // axis lock LAST: a locked axis never moves, even to snap
    ex = d.ax === 2 ? s.x : snapped[0];
    ey = d.ax === 1 ? s.y : snapped[1];
    if (ex === s.x && ey === s.y) {
      d.vx = d.vy = 0;
      return;
    }
    if (prefersReduced) {
      // direct manipulation stays; post-release coasting is decorative —
      // jump straight to the rest point
      xformSet(s, "x", ex);
      xformSet(s, "y", ey);
      animDirty.add(d.el);
      flushXform();
      d.vx = d.vy = 0;
      if (d.hasInertia && d.cb) animFireSlot(d.cb.sT);
      return;
    }
    d.ex = ex;
    d.ey = ey;
    if (!d.throwing) {
      d.throwing = true;
      dragThrowing++;
    }
    tickerKick();
  };

  // Per-frame throw integrator — called from animTick while
  // dragThrowing > 0. Exponential approach toward the projected endpoint.
  // When bounce > 0 and position crosses a wall, dragBounceReflect adjusts
  // both the current position and the target endpoint so the integrator
  // naturally decelerates toward the new reflected destination.
  const dragUpdate = (dt) => {
    for (const d of [...drags.values()]) {
      if (!d.el.isConnected) {
        dragKill(d);
        continue;
      }
      if (!d.throwing) continue;
      const s = getXform(d.el);
      const r = d.hasInertia ? d.retention : DRAG_DEFAULT_RETENTION;
      const f = 1 - Math.pow(r, dt);
      let nx = s.x + (d.ex - s.x) * f;
      let ny = s.y + (d.ey - s.y) * f;
      // bounce: reflect off walls when overshoot occurs during the throw
      if (d.bounce > 0) {
        if (nx < d.minX && d.minX !== -Infinity) {
          const rb = dragBounceReflect(nx, d.ex, d.minX, d.bounce);
          nx = rb.pos;
          d.ex = rb.endpoint;
        } else if (nx > d.maxX && d.maxX !== Infinity) {
          const rb = dragBounceReflect(nx, d.ex, d.maxX, d.bounce);
          nx = rb.pos;
          d.ex = rb.endpoint;
        }
        if (ny < d.minY && d.minY !== -Infinity) {
          const rb = dragBounceReflect(ny, d.ey, d.minY, d.bounce);
          ny = rb.pos;
          d.ey = rb.endpoint;
        } else if (ny > d.maxY && d.maxY !== Infinity) {
          const rb = dragBounceReflect(ny, d.ey, d.maxY, d.bounce);
          ny = rb.pos;
          d.ey = rb.endpoint;
        }
      }
      d.vx = (d.ex - nx) * d.k;
      d.vy = (d.ey - ny) * d.k;
      if (Math.abs(d.ex - nx) < 0.1 && Math.abs(d.ey - ny) < 0.1) {
        nx = d.ex;
        ny = d.ey;
        dragStopThrow(d);
        d.vx = d.vy = 0;
        if (d.hasInertia && d.cb) animFireSlot(d.cb.sT);
      }
      xformSet(s, "x", nx);
      xformSet(s, "y", ny);
      animDirty.add(d.el);
    }
    flushXform();
  };

  const dragAttach = (cfg, el) => {
    const grip = (cfg.hd ? el.querySelector(cfg.hd) : null) || el;
    const ax = cfg.ax || 0;
    const d = {
      h: dragSeq++,
      el,
      grip,
      ax,
      boundsSpec: cfg.b || null,
      hasInertia: cfg.in != null,
      retention: cfg.in == null || cfg.in === 1 ? DRAG_DEFAULT_RETENTION : cfg.in,
      bounce: cfg.bo != null ? cfg.bo : 0,
      snap: cfg.sn || null,
      th: cfg.th == null ? 3 : cfg.th,
      cur: cfg.cur !== 0,
      cls: cfg.cls || null,
      zoneSel: cfg.zn || null,
      zoneCls: cfg.znc || null,
      zoneEls: [],
      zoneRects: [],
      hover: -1,
      drop: -1, // persists from the last gesture until a new one starts
      cb: cfg.cb || null,
      enabled: cfg.dis !== 1,
      pid: null,
      engaged: false,
      sx: 0,
      sy: 0,
      bx: 0,
      by: 0,
      minX: -Infinity,
      maxX: Infinity,
      minY: -Infinity,
      maxY: Infinity,
      samples: [],
      vx: 0,
      vy: 0,
      lastT: 0,
      throwing: false,
      ex: 0,
      ey: 0,
      k: Math.log(1 / DRAG_DEFAULT_RETENTION),
      fns: [],
    };
    // touch-action/user-select MUST land at create — late assignment
    // causes iOS pointercancel mid-gesture.
    grip.style.touchAction = ax === 1 ? "pan-y" : ax === 2 ? "pan-x" : "none";
    grip.style.userSelect = "none";
    if (d.cur) grip.style.cursor = "grab";

    const on = (tgt, type, fn, opts) => {
      tgt.addEventListener(type, fn, opts);
      d.fns.push([tgt, type, fn, opts]);
    };
    on(grip, "pointerdown", (e) => {
      if (!d.enabled || d.pid != null) return;
      if (e.pointerType === "mouse" && e.button !== 0) return;
      e.stopPropagation(); // nested draggables: innermost wins
      dragStopThrow(d); // grabbing mid-throw takes over
      d.pid = e.pointerId;
      d.engaged = false;
      d.sx = e.clientX;
      d.sy = e.clientY;
      const s = getXform(d.el);
      d.bx = s.x;
      d.by = s.y;
      dragResolveBounds(d, s);
      // drop zones: PAGE-coord rects per gesture (mouse drags don't
      // block wheel scroll, so viewport coords would go stale; under a
      // smoother both the rects and the normalized pointer shift
      // identically, so the math cancels)
      d.hover = -1;
      d.drop = -1;
      d.zoneEls = [];
      d.zoneRects = [];
      if (d.zoneSel) {
        const zsx = window.scrollX || 0;
        const zsy = window.scrollY || 0;
        document.querySelectorAll(d.zoneSel).forEach((z) => {
          const zr = z.getBoundingClientRect();
          d.zoneEls.push(z);
          d.zoneRects.push([zr.left + zsx, zr.top + zsy, zr.right + zsx, zr.bottom + zsy]);
        });
      }
      d.samples.length = 0;
      d.vx = d.vy = 0;
      velPush(d, s.x, s.y);
      d.lastT = performance.now();
      try {
        grip.setPointerCapture(e.pointerId);
      } catch {}
    });
    on(grip, "pointermove", (e) => {
      if (e.pointerId !== d.pid) return;
      let dx = e.clientX - d.sx;
      let dy = e.clientY - d.sy;
      if (!d.engaged) {
        if (Math.hypot(dx, dy) < d.th) return; // clicks survive below threshold
        d.engaged = true;
        if (d.cls) d.el.classList.add(d.cls);
        if (d.cur) grip.style.cursor = "grabbing";
        if (d.cb) animFireSlot(d.cb.sS);
      }
      if (d.ax === 1) dy = 0;
      else if (d.ax === 2) dx = 0;
      const s = getXform(d.el);
      xformSet(s, "x", dclamp(d.bx + dx, d.minX, d.maxX));
      xformSet(s, "y", dclamp(d.by + dy, d.minY, d.maxY));
      animDirty.add(d.el);
      flushXform(); // sync — rAF-deferred position lags the pointer
      if (d.zoneRects.length) {
        const hit = dragZoneHit(
          d.zoneRects,
          e.clientX + (window.scrollX || 0),
          e.clientY + (window.scrollY || 0),
        );
        if (hit !== d.hover) {
          if (d.zoneCls) {
            if (d.hover >= 0) d.zoneEls[d.hover].classList.remove(d.zoneCls);
            if (hit >= 0) d.zoneEls[hit].classList.add(d.zoneCls);
          }
          d.hover = hit;
        }
      }
      d.lastT = performance.now();
      velPush(d, s.x, s.y);
      if (d.cb) animFireSlot(d.cb.sD);
    });
    const endGesture = (e, cancelled) => {
      if (e.pointerId !== d.pid) return;
      d.pid = null;
      if (!d.engaged) return; // plain click
      d.engaged = false;
      if (cancelled || performance.now() - d.lastT > 80) {
        d.vx = d.vy = 0; // browser stole the gesture / held still
      }
      if (d.cls) d.el.classList.remove(d.cls);
      if (d.cur) grip.style.cursor = "grab";
      // drop decision at the RELEASE point, before any throw
      if (d.zoneRects.length) {
        const hit = cancelled
          ? -1
          : dragZoneHit(
              d.zoneRects,
              e.clientX + (window.scrollX || 0),
              e.clientY + (window.scrollY || 0),
            );
        if (d.zoneCls && d.hover >= 0) d.zoneEls[d.hover].classList.remove(d.zoneCls);
        d.hover = -1;
        d.drop = hit;
      }
      if (d.cb) animFireSlot(d.cb.sE);
      if (d.drop >= 0 && d.cb) animFireSlot(d.cb.sZ);
      // a real drag happened — swallow the synthetic click before the
      // document-level bubble delegates see it
      grip.addEventListener(
        "click",
        (ce) => {
          ce.stopPropagation();
          ce.preventDefault();
        },
        { capture: true, once: true },
      );
      dragRelease(d);
    };
    on(grip, "pointerup", (e) => endGesture(e, false));
    on(grip, "pointercancel", (e) => endGesture(e, true));

    drags.set(d.h, d);
    return d.h;
  };

  const dragCreate = (desc, selfEl) => {
    if (!desc || desc.v !== 1 || !desc.dr) return 0;
    const cfg = desc.dr;
    let els = [];
    if (cfg.t && cfg.t.h != null) {
      const el = refHandles[cfg.t.h];
      if (el) els = [el];
    } else if (cfg.t && cfg.t.s) {
      els = Array.from((selfEl || document).querySelectorAll(cfg.t.s));
    } else if (selfEl) {
      els = [selfEl];
    }
    let first = 0;
    for (const el of els) {
      const h = dragAttach(cfg, el);
      if (!first) first = h;
    }
    return first;
  };

  // Declarative SSR surface: scan `[data-drag]` stamped by
  // Node.draggable(). Separate scanner from animScan — an element can
  // carry both attributes. Also sweeps disconnected records (SPA swaps).
  const dragScan = (root) => {
    if (drags.size) {
      for (const d of [...drags.values()]) {
        if (!d.el.isConnected) dragKill(d);
      }
    }
    const list = [];
    if (root instanceof Element) {
      if (root.hasAttribute("data-drag")) list.push(root);
      root.querySelectorAll("[data-drag]").forEach((el) => list.push(el));
    } else if (root && root.querySelectorAll) {
      root.querySelectorAll("[data-drag]").forEach((el) => list.push(el));
    }
    for (const el of list) {
      if (el.hasAttribute("data-drag-done")) continue;
      el.setAttribute("data-drag-done", "1");
      let desc;
      try {
        desc = JSON.parse(el.getAttribute("data-drag"));
      } catch (err) {
        console.warn("verve drag: bad data-drag payload", el, err);
        continue;
      }
      dragCreate(desc, el);
    }
  };

  // ---- Verve Sortable ----------------------------------------------------
  // Drag-to-reorder with cross-list group transfer + edge autoscroll.
  // Parses the `"so"` descriptor produced by serialize.sortableToJson.
  // Wire sub-keys: "it" items selector, "hd" handle selector,
  // "ax" axis (1=x,2=y,omit=y), "an" animate (0=off), "cls" toggle_class,
  // "dis" disabled (1), "grp" group name (cross-list transfer),
  // "as" autoscroll (0=off, omit=on), "ase" autoscroll edge px (omit=40),
  // "cb":{"sR" on_reorder_slot, "sG" on_enter_group_slot}.

  let sortableSeq = 1;
  const sortables = new Map(); // handle → sortable state
  // Group registry: groupName → Set of sortable state objects.
  const sortableGroups = new Map();

  const sortableAttach = (cfg, container) => {
    const itemSel = cfg.it;
    if (!itemSel) return 0;
    const ax = cfg.ax != null ? cfg.ax : 2; // default y
    const animate = cfg.an !== 0; // true unless "an":0
    const cls = cfg.cls || null;
    const cb = cfg.cb || null;
    const enabled = cfg.dis !== 1;
    const grp = cfg.grp || null; // group name for cross-list transfer
    const autoscroll = cfg.as !== 0; // true unless "as":0
    const edgePx = (cfg.ase != null && cfg.ase > 0) ? cfg.ase : 40;

    const reducedMotion = prefersReduced;
    const s = {
      h: sortableSeq++,
      container,
      itemSel,
      ax,
      animate,
      cls,
      cb,
      enabled,
      grp,
      autoscroll,
      edgePx,
      // last reorder result (-1 = never reordered)
      lastFrom: -1,
      lastTo: -1,
      // last container identity for cross-list (null = no cross-list yet)
      lastFromGroup: null,
      lastToGroup: null,
      // active drag state (null when idle)
      drag: null,
    };

    // Register in group registry.
    if (grp) {
      let grpSet = sortableGroups.get(grp);
      if (!grpSet) {
        grpSet = new Set();
        sortableGroups.set(grp, grpSet);
      }
      grpSet.add(s);
    }

    const getItems = () => Array.from(container.querySelectorAll(itemSel));

    // Capture natural (untransformed) bounding rects of all siblings,
    // excluding the dragged item (it moves with the pointer).
    const captureRects = (excludeEl) => {
      const items = getItems().filter((el) => el !== excludeEl);
      return items.map((el) => {
        const r = el.getBoundingClientRect();
        return { el, rect: { left: r.left, top: r.top, right: r.right, bottom: r.bottom } };
      });
    };

    // Clear any preview transforms on siblings.
    const clearSiblingShifts = (siblings) => {
      for (const sib of siblings) {
        sib.el.style.transform = "";
        sib.el.style.transition = "";
      }
    };

    // Apply FLIP-preview translate to siblings based on target slot.
    // The dragged item currently occupies `fromIndex` in the full list.
    // Siblings at or after `toIndex` (up to `fromIndex`) shift forward one
    // slot (or backward if dragging down).
    const previewSiblingShifts = (dragged, siblings, fromIndex, toIndex, itemH, itemW) => {
      // Transition only when animate=true AND reduced-motion is not set.
      // Position preview (transform) always updates — only the motion is suppressed.
      const useTransition = animate && !reducedMotion;
      const n = siblings.length;
      // siblings is the list EXCLUDING the dragged item; their original
      // indices in the full list are: 0..(fromIndex-1), (fromIndex+1)..n
      for (let i = 0; i < n; i++) {
        const origFull = i < fromIndex ? i : i + 1;
        // Does this sibling need to shift?
        let shift = 0;
        if (fromIndex < toIndex) {
          // dragging down: items between (fromIndex+1)..toIndex shift up one slot
          if (origFull > fromIndex && origFull <= toIndex) shift = -1;
        } else if (fromIndex > toIndex) {
          // dragging up: items between toIndex..(fromIndex-1) shift down one slot
          if (origFull >= toIndex && origFull < fromIndex) shift = 1;
        }
        const sib = siblings[i];
        if (shift !== 0) {
          sib.el.style.transition = useTransition ? "transform 0.18s ease" : "";
          if (ax === 1) {
            sib.el.style.transform = `translateX(${shift * itemW}px)`;
          } else {
            sib.el.style.transform = `translateY(${shift * itemH}px)`;
          }
        } else {
          sib.el.style.transition = useTransition ? "transform 0.18s ease" : "";
          sib.el.style.transform = "";
        }
      }
    };

    const onPointerDown = (e) => {
      if (!s.enabled || s.drag) return;
      if (e.pointerType === "mouse" && e.button !== 0) return;
      // Find which item was hit (or whose handle was hit).
      let targetEl = null;
      for (const item of getItems()) {
        const grip = (cfg.hd ? item.querySelector(cfg.hd) : null) || item;
        if (grip === e.target || grip.contains(e.target)) {
          targetEl = item;
          break;
        }
      }
      if (!targetEl) return;
      e.preventDefault();
      e.stopPropagation();

      const allItems = getItems();
      const fromIndex = allItems.indexOf(targetEl);
      if (fromIndex < 0) return;

      // Capture item size for shift calculation.
      const r = targetEl.getBoundingClientRect();
      const itemH = r.height;
      const itemW = r.width;

      // Capture starting pointer offset within the item.
      const offsetX = e.clientX - r.left;
      const offsetY = e.clientY - r.top;

      // Apply drag class.
      if (cls) targetEl.classList.add(cls);

      // Position dragged item absolutely under pointer.
      // Use inline translate so layout siblings keep their flow positions.
      // We'll translate relative to current position (no layout removal).
      const startX = e.clientX - offsetX - r.left; // = 0 initially
      const startY = e.clientY - offsetY - r.top;  // = 0 initially

      // Raise z-index so it overlaps siblings.
      targetEl.style.position = "relative";
      targetEl.style.zIndex = "1000";
      targetEl.style.pointerEvents = "none";

      let currentSlot = fromIndex;
      const siblings = captureRects(targetEl);

      s.drag = {
        el: targetEl,
        fromIndex,
        currentSlot,
        startClientX: e.clientX,
        startClientY: e.clientY,
        startTranslateX: 0,
        startTranslateY: 0,
        offsetX,
        offsetY,
        itemH,
        itemW,
        pid: e.pointerId,
        siblings,
        // Cross-list: track current live target sortable (may differ from `s`).
        // `liveTarget` is the sortable state object currently under the pointer.
        liveTarget: s,
        // Autoscroll rAF id (0 = not running).
        scrollRaf: 0,
      };

      try { targetEl.setPointerCapture(e.pointerId); } catch {}
    };

    const onPointerMove = (e) => {
      const d = s.drag;
      if (!d || e.pointerId !== d.pid) return;

      const dx = e.clientX - d.startClientX;
      const dy = e.clientY - d.startClientY;

      // Translate the dragged element under the pointer.
      if (ax === 1) {
        d.el.style.transform = `translateX(${dx}px)`;
      } else if (ax === 2) {
        d.el.style.transform = `translateY(${dy}px)`;
      } else {
        d.el.style.transform = `translate(${dx}px,${dy}px)`;
      }

      // Cross-list group hit-test: find the same-group container under pointer.
      let newTarget = s; // default: same container
      if (grp) {
        const grpSet = sortableGroups.get(grp);
        if (grpSet) {
          for (const peer of grpSet) {
            if (!peer.enabled) continue;
            const cr = peer.container.getBoundingClientRect();
            if (
              e.clientX >= cr.left && e.clientX <= cr.right &&
              e.clientY >= cr.top  && e.clientY <= cr.bottom
            ) {
              newTarget = peer;
              // Keep iterating — later entries win (deepest/last in DOM order).
            }
          }
        }
      }

      // If the live container changed, transfer the dragged node and fire
      // on_enter_group_slot.
      if (newTarget !== d.liveTarget) {
        const prevTarget = d.liveTarget;
        // Clear sibling shifts in the old container.
        clearSiblingShifts(d.siblings);
        // Move the dragged node into the new container (append to end as
        // placeholder; slot will be corrected below).
        newTarget.container.appendChild(d.el);
        // Recompute siblings in new container.
        d.siblings = Array.from(newTarget.container.querySelectorAll(newTarget.itemSel))
          .filter((el) => el !== d.el)
          .map((el) => {
            const r = el.getBoundingClientRect();
            return { el, rect: { left: r.left, top: r.top, right: r.right, bottom: r.bottom } };
          });
        // fromIndex in the new container = end (item just appended).
        d.fromIndex = newTarget.container.querySelectorAll(newTarget.itemSel).length - 1;
        d.currentSlot = d.fromIndex;
        d.liveTarget = newTarget;
        // Fire on_enter_group_slot via the NEW target's callback (cross-list).
        const enterCb = newTarget.cb;
        if (enterCb && enterCb.sG != null) {
          animFireSlot(enterCb.sG);
        }
        // Also check the source container's cb.
        const srcCb = prevTarget.cb;
        if (srcCb && srcCb.sG != null) {
          animFireSlot(srcCb.sG);
        }
      }

      const lt = d.liveTarget;
      const ltAx = lt.ax;

      // Recompute slot: gather live rects of siblings (they may be animating).
      const sibRects = d.siblings.map((sib) => {
        const r = sib.el.getBoundingClientRect();
        return { left: r.left, top: r.top, right: r.right, bottom: r.bottom };
      });

      // The target slot in the FULL list (including the dragged item's original slot).
      // sortableSlotIndex gives 0..n-1 (siblings only), map back to full-list slot.
      const rawSlot = sortableSlotIndex({ x: e.clientX, y: e.clientY }, sibRects, ltAx);
      let fullSlot;
      if (rawSlot <= d.fromIndex) {
        fullSlot = rawSlot;
      } else {
        fullSlot = rawSlot; // rawSlot already accounts for the gap
      }

      d.currentSlot = fullSlot;
      // previewSiblingShifts uses the closure vars (animate, reducedMotion, ax)
      // from sortableAttach. For cross-list, use liveTarget's props.
      const useTransitionLT = lt.animate && !reducedMotion;
      const ltN = d.siblings.length;
      for (let i = 0; i < ltN; i++) {
        const origFull = i < d.fromIndex ? i : i + 1;
        let shift = 0;
        if (d.fromIndex < fullSlot) {
          if (origFull > d.fromIndex && origFull <= fullSlot) shift = -1;
        } else if (d.fromIndex > fullSlot) {
          if (origFull >= fullSlot && origFull < d.fromIndex) shift = 1;
        }
        const sib = d.siblings[i];
        sib.el.style.transition = useTransitionLT ? "transform 0.18s ease" : "";
        sib.el.style.transform = shift !== 0
          ? (ltAx === 1 ? `translateX(${shift * d.itemW}px)` : `translateY(${shift * d.itemH}px)`)
          : "";
      }

      // Edge autoscroll: schedule rAF if pointer is in the edge band.
      if (autoscroll) {
        const cr = lt.container.getBoundingClientRect();
        // For horizontal lists (ax=1), project x/left/right onto the y/top/bottom
        // fields so sortableAutoscroll's fixed-axis math operates on the correct axis.
        const asPtr = ltAx === 1 ? { x: 0, y: e.clientX } : { x: e.clientX, y: e.clientY };
        const asRect = ltAx === 1 ? { top: cr.left, bottom: cr.right } : cr;
        const delta = sortableAutoscroll(asPtr, asRect, lt.edgePx);
        if (delta !== 0) {
          if (!d.scrollRaf) {
            const scrollStep = () => {
              const dd = s.drag;
              if (!dd || dd !== d) return; // drag ended
              const crr = dd.liveTarget.container.getBoundingClientRect();
              const ltAxCur = dd.liveTarget.ax;
              const asPtr2 = ltAxCur === 1 ? { x: 0, y: dd.lastPointerX } : { x: dd.lastPointerX, y: dd.lastPointerY };
              const asRect2 = ltAxCur === 1 ? { top: crr.left, bottom: crr.right } : crr;
              const spd = sortableAutoscroll(asPtr2, asRect2, dd.liveTarget.edgePx);
              if (spd !== 0) {
                if (ltAx === 1) {
                  dd.liveTarget.container.scrollLeft += spd;
                } else {
                  dd.liveTarget.container.scrollTop += spd;
                }
                dd.scrollRaf = requestAnimationFrame(scrollStep);
              } else {
                dd.scrollRaf = 0;
              }
            };
            d.scrollRaf = requestAnimationFrame(scrollStep);
          }
        } else if (d.scrollRaf) {
          cancelAnimationFrame(d.scrollRaf);
          d.scrollRaf = 0;
        }
        d.lastPointerX = e.clientX;
        d.lastPointerY = e.clientY;
      }
    };

    const onPointerUp = (e) => {
      const d = s.drag;
      if (!d || e.pointerId !== d.pid) return;
      s.drag = null;

      // Cancel any running autoscroll rAF.
      if (d.scrollRaf) {
        cancelAnimationFrame(d.scrollRaf);
        d.scrollRaf = 0;
      }

      const toIndex = d.currentSlot;
      const lt = d.liveTarget; // may differ from `s` for cross-list drops

      // Clear drag styles.
      d.el.style.transform = "";
      d.el.style.position = "";
      d.el.style.zIndex = "";
      d.el.style.pointerEvents = "";
      if (cls) d.el.classList.remove(cls);

      // Clear sibling preview shifts.
      clearSiblingShifts(d.siblings);

      // Reorder DOM: move dragged element to the target slot in liveTarget's container.
      const ltContainer = lt.container;
      const ltGetItems = () => Array.from(ltContainer.querySelectorAll(lt.itemSel));
      const itemEls = ltGetItems();
      if (toIndex >= itemEls.length) {
        ltContainer.appendChild(d.el);
      } else {
        const refEl = itemEls[toIndex];
        if (refEl !== d.el) {
          const refIdx = Array.from(ltContainer.children).indexOf(refEl);
          const dragIdx = Array.from(ltContainer.children).indexOf(d.el);
          if (dragIdx < refIdx) {
            ltContainer.insertBefore(d.el, refEl.nextSibling);
          } else {
            ltContainer.insertBefore(d.el, refEl);
          }
        }
      }

      // Store last reorder result on the SOURCE sortable (s) and fire on_reorder.
      // For cross-list: fromContainer = s.h, toContainer = lt.h.
      const isCrossGroup = lt !== s;
      s.lastFrom = d.fromIndex;
      s.lastTo = toIndex;
      // Group container handles: -1 when no group, otherwise the sortable handle id.
      s.lastFromGroup = grp ? s.h : -1;
      s.lastToGroup = grp ? lt.h : -1;
      if (cb && cb.sR != null) {
        animFireSlot(cb.sR);
      }
      // Also store on the target sortable so its handle can read lastTo.
      if (isCrossGroup) {
        lt.lastFrom = d.fromIndex;
        lt.lastTo = toIndex;
        lt.lastFromGroup = grp ? s.h : -1;
        lt.lastToGroup = grp ? lt.h : -1;
        if (lt.cb && lt.cb.sR != null) {
          animFireSlot(lt.cb.sR);
        }
      }
    };

    // Attach listeners to each item (on pointerdown, discover which item).
    container.addEventListener("pointerdown", onPointerDown);
    container.addEventListener("pointermove", onPointerMove);
    container.addEventListener("pointerup", onPointerUp);
    container.addEventListener("pointercancel", onPointerUp);

    // touch-action: prevent scroll interference during vertical sort.
    container.style.touchAction = ax === 1 ? "pan-y" : "pan-x";

    sortables.set(s.h, s);
    return s.h;
  };

  const sortableCreate = (desc, selfEl) => {
    if (!desc || desc.v !== 1 || !desc.so) return 0;
    const cfg = desc.so;
    // Container ref lives at the DESCRIPTOR top level (sibling of "so"),
    // spliced there by island_runtime.zig's sortable() — NOT inside "so"
    // (serialize.sortableToJson never emits a container key).
    const ct = desc.ct;
    let containers = [];
    if (ct && ct.h != null) {
      const el = refHandles[ct.h];
      if (el) containers = [el];
    } else if (ct && ct.s) {
      containers = Array.from((selfEl || document).querySelectorAll(ct.s));
    } else if (selfEl) {
      containers = [selfEl];
    } else {
      return 0;
    }
    let first = 0;
    for (const el of containers) {
      const h = sortableAttach(cfg, el);
      if (!first) first = h;
    }
    return first;
  };

  // ---- Verve Flip --------------------------------------------------------
  // FLIP layout animation (island-only, ops crossing — no wire root; play
  // options JSON from src/core/anim/flip.zig optsToJson). Capture stores
  // VISUAL doc-space rects; play matches by element identity (reorders)
  // then data-vkey (reconciler-recreated nodes), inverts via the shared
  // transform composer, and eases to identity in the ticker.

  const flipStates = new Map(); // capture handle -> { entries }
  const flips = new Map(); // flip handle -> active flip
  const flipByEl = new Map(); // el -> owning active flip (last-writer claim)
  let flipStateSeq = 1;
  let flipSeq = 1;
  let flipActive = 0;
  const FLIP_STATE_CAP = 16; // entries hold strong element refs

  // Visual rect minus the composer's translate, size divided by its
  // scale -> the element's natural (untransformed) center + size.
  // Assumes translate+scale only (rotate/skew callers fall back to
  // position-only).
  // @verve-extract flipNatural
  const flipNatural = (r, s) => ({
    cx: r.left + r.width / 2 - s.x,
    cy: r.top + r.height / 2 - s.y,
    w: s.sx ? r.width / s.sx : r.width,
    h: s.sy ? r.height / s.sy : r.height,
  });
  // @verve-extract-end

  // Center-based first-minus-last deltas; scale ratios pinned to 1 when
  // disabled or degenerate.
  // @verve-extract flipDelta
  const flipDelta = (first, last, useScale) => ({
    dx: first.cx - last.cx,
    dy: first.cy - last.cy,
    rx: useScale && last.w > 0 ? first.w / last.w : 1,
    ry: useScale && last.h > 0 ? first.h / last.h : 1,
  });
  // @verve-extract-end

  // Apply inverse scale to each immediate child of a FLIP element so their
  // content stays crisp while the parent is scaled. Called every tick when
  // `cs` is set; pass the parent's current scaleX/scaleY from the lerp.
  // @verve-extract flipCounterScale
  const flipCounterScale = (el, sx, sy) => {
    const inv_x = sx !== 0 ? 1 / sx : 1;
    const inv_y = sy !== 0 ? 1 / sy : 1;
    for (const child of el.children) {
      child.style.transform = `scale(${inv_x},${inv_y})`;
    }
  };
  const flipCounterScaleClear = (el) => {
    // This clears the child's transform unconditionally; a pre-existing style.transform is not restored (acceptable for layout containers).
    for (const child of el.children) {
      child.style.transform = "";
    }
  };
  // @verve-extract-end

  // Compute the drop-slot index for a pointer position given item rects.
  // Returns 0..n (inclusive): 0 = before first, n = after last.
  // axis: 1=x, 2=y (default), 0=both (uses y). Each item is examined at
  // its midpoint: pointer before mid → slot before that item, pointer
  // at/after mid → slot after that item. Works for above-first, between,
  // and below-last cases without special-casing.
  // @verve-extract sortableSlotIndex
  const sortableSlotIndex = (pos, rects, axis) => {
    if (!rects || rects.length === 0) return 0;
    const useX = axis === 1;
    for (let i = 0; i < rects.length; i++) {
      const r = rects[i];
      const mid = useX
        ? (r.left + r.right) / 2
        : (r.top + r.bottom) / 2;
      const coord = useX ? pos.x : pos.y;
      if (coord < mid) return i;
    }
    return rects.length;
  };
  // @verve-extract-end

  // Compute autoscroll velocity for a sortable container.
  // Returns a signed scroll delta (pixels/frame) when the pointer is within
  // `edgePx` of the container's start or end edge along the primary axis.
  // Positive = scroll toward end (down/right), negative = toward start (up/left).
  // Magnitude ramps linearly with proximity: 0 at the outer boundary of the
  // band, MAX_SPEED at the inner edge (container edge).
  // Returns 0 when the pointer is outside the edge band (or outside the container).
  // axis is not passed — caller selects the relevant edge pair from containerRect.
  // The rect is a DOMRect-compatible {left, top, right, bottom}.
  // @verve-extract sortableAutoscroll
  const sortableAutoscroll = (pointerPos, containerRect, edgePx) => {
    const MAX_SPEED = 16; // max pixels per frame at the inner edge
    // Operates on the y-axis (pointerPos.y vs containerRect.top/bottom).
    // For horizontal lists (ax=1), the call site projects x/left/right onto
    // y/top/bottom before calling so that this function stays axis-agnostic
    // and purely testable without an ax parameter.
    const top = containerRect.top;
    const bottom = containerRect.bottom;
    const py = pointerPos.y;
    // Outside the container entirely → 0.
    if (py < top || py > bottom) return 0;
    const fromTop = py - top;
    const fromBottom = bottom - py;
    if (fromTop < edgePx) {
      // Near the top edge → negative (scroll up).
      return -MAX_SPEED * (1 - fromTop / edgePx);
    }
    if (fromBottom < edgePx) {
      // Near the bottom edge → positive (scroll down).
      return MAX_SPEED * (1 - fromBottom / edgePx);
    }
    return 0;
  };
  // @verve-extract-end

  const flipCaptureImpl = (sel) => {
    let els;
    try {
      els = Array.from(document.querySelectorAll(sel));
    } catch {
      return 0;
    }
    if (!els.length) return 0;
    const sx = window.scrollX || 0;
    const sy = window.scrollY || 0;
    const entries = els.map((el) => {
      const r = el.getBoundingClientRect();
      return {
        el,
        vkey: el.getAttribute("data-vkey"),
        rect: { left: r.left + sx, top: r.top + sy, width: r.width, height: r.height },
        claimed: false,
      };
    });
    if (flipStates.size >= FLIP_STATE_CAP) {
      const oldest = flipStates.keys().next().value;
      flipStates.delete(oldest);
      console.warn("verve flip: state cap reached, evicting oldest capture", oldest);
    }
    const h = flipStateSeq++;
    flipStates.set(h, { sel, entries });
    return h;
  };

  const flipFinishItem = (it) => {
    it.done = true;
    if (it.fade) it.el.style.opacity = "";
    flipByEl.delete(it.el);
  };

  const flipKill = (f, snap) => {
    for (const it of f.items) {
      if (it.done) continue;
      if (snap && it.el.isConnected) {
        if (it.fade) {
          it.el.style.opacity = "";
        } else {
          const s = getXform(it.el);
          xformSet(s, "x", 0);
          xformSet(s, "y", 0);
          if (f.useScale) {
            xformSet(s, "scaleX", 1);
            xformSet(s, "scaleY", 1);
            if (f.counterScale) flipCounterScaleClear(it.el);
          }
          animDirty.add(it.el);
        }
      }
      flipFinishItem(it);
    }
    flushXform();
    if (flips.delete(f.h)) flipActive--;
  };

  const flipPlayImpl = (stateH, desc) => {
    const state = flipStates.get(stateH);
    flipStates.delete(stateH); // play ALWAYS consumes the state
    if (!state) return 0;
    const cb = desc.cb || null;
    // matcher shared by the live and reduced-motion paths (cheap; no gBCR)
    const matchEntry = (el) => {
      let entry = state.entries.find((e) => !e.claimed && e.el === el);
      if (!entry) {
        const vk = el.getAttribute("data-vkey");
        if (vk) entry = state.entries.find((e) => !e.claimed && e.vkey === vk);
      }
      return entry || null;
    };
    const fireEnterLeave = (enteredCount) => {
      if (!cb) return;
      // enter/leave fire synchronously inside the op (sC-on-RM precedent)
      if (enteredCount > 0) animFireSlot(cb.sE);
      if (state.entries.some((e) => !e.claimed)) animFireSlot(cb.sL);
    };
    let els;
    try {
      els = Array.from(document.querySelectorAll(state.sel));
    } catch {
      els = [];
    }
    if (prefersReduced) {
      // layout already final; FLIP motion is decorative — but enter/leave
      // are structural facts, so match cheaply and fire callbacks in the
      // jump-to-end order: sE/sL then sC.
      let entered = 0;
      for (const el of els) {
        const entry = matchEntry(el);
        if (entry) entry.claimed = true;
        else entered++;
      }
      fireEnterLeave(entered);
      if (cb) animFireSlot(cb.sC);
      return 0;
    }
    const useScale = desc.sc === 1;
    const fadeIn = desc.fade !== 0;
    const sx = window.scrollX || 0;
    const sy = window.scrollY || 0;
    const items = [];
    let entered = 0;
    for (const el of els) {
      // identity first, then unclaimed vkey (reconciler re-created node)
      const entry = matchEntry(el);
      if (!entry) {
        entered++;
        if (fadeIn) {
          el.style.opacity = "0";
          items.push({ el, fade: true, dx: 0, dy: 0, rx: 1, ry: 1, done: false, delay: 0 });
        }
        continue;
      }
      entry.claimed = true;
      const r = el.getBoundingClientRect();
      const s = getXform(el);
      const rotated = s.r !== 0 || s.kx !== 0 || s.ky !== 0;
      const last = flipNatural(
        { left: r.left + sx, top: r.top + sy, width: r.width, height: r.height },
        rotated ? { x: s.x, y: s.y, sx: 1, sy: 1 } : s,
      );
      const first = {
        cx: entry.rect.left + entry.rect.width / 2,
        cy: entry.rect.top + entry.rect.height / 2,
        w: entry.rect.width,
        h: entry.rect.height,
      };
      const d = flipDelta(first, last, useScale && !rotated);
      const moved = Math.abs(d.dx) > 0.5 || Math.abs(d.dy) > 0.5 ||
        Math.abs(d.rx - 1) > 0.001 || Math.abs(d.ry - 1) > 0.001;
      if (!moved) continue;
      items.push({ el, fade: false, dx: d.dx, dy: d.dy, rx: d.rx, ry: d.ry, done: false, delay: 0 });
    }
    // structural callbacks fire even when nothing ends up animating
    fireEnterLeave(entered);
    if (!items.length) {
      if (cb) animFireSlot(cb.sC);
      return 0;
    }
    // invert synchronously — same task as the layout change, no flash
    const stagger = desc.st || 0;
    items.forEach((it, i) => {
      it.delay = i * stagger;
      const prior = flipByEl.get(it.el);
      if (prior) prior.items = prior.items.filter((p) => p.el !== it.el); // steal
      flipByEl.set(it.el, null); // claimed below
      if (!it.fade) {
        const s = getXform(it.el);
        xformSet(s, "x", it.dx);
        xformSet(s, "y", it.dy);
        if (useScale) {
          xformSet(s, "scaleX", it.rx);
          xformSet(s, "scaleY", it.ry);
        }
        animDirty.add(it.el);
      }
    });
    flushXform();
    const f = {
      h: flipSeq++,
      items,
      t: 0,
      dur: typeof desc.d === "number" ? desc.d : 0.4,
      easeFn: easeFnOf(desc.e),
      cb,
      useScale,
      counterScale: useScale && desc.cs === 1,
    };
    for (const it of items) flipByEl.set(it.el, f);
    flips.set(f.h, f);
    flipActive++;
    tickerKick();
    return f.h;
  };

  // Per-frame integrator (dragUpdate model) — lerps inverted -> identity.
  const flipUpdate = (dt) => {
    for (const f of [...flips.values()]) {
      f.t += dt;
      let live = 0;
      for (const it of f.items) {
        if (it.done) continue;
        if (!it.el.isConnected) {
          flipFinishItem(it);
          continue;
        }
        const p = Math.max(0, Math.min((f.t - it.delay) / f.dur, 1));
        const e = f.easeFn(p);
        if (it.fade) {
          it.el.style.opacity = String(e);
        } else {
          const s = getXform(it.el);
          xformSet(s, "x", it.dx * (1 - e));
          xformSet(s, "y", it.dy * (1 - e));
          if (f.useScale) {
            const csx = it.rx + (1 - it.rx) * e;
            const csy = it.ry + (1 - it.ry) * e;
            xformSet(s, "scaleX", csx);
            xformSet(s, "scaleY", csy);
            if (f.counterScale) flipCounterScale(it.el, csx, csy);
          }
          animDirty.add(it.el);
        }
        if (p >= 1) {
          if (f.counterScale && !it.fade) flipCounterScaleClear(it.el);
          flipFinishItem(it);
        } else live++;
      }
      if (!live) {
        flips.delete(f.h);
        flipActive--;
        if (f.cb) animFireSlot(f.cb.sC);
      }
    }
    flushXform();
  };

  // viz canvas2d render path (phase 3). Batched: the chunk packs one draw buffer
  // (see core/viz/canvas_buf.zig) and calls this once per frame.
  const vizCanvasCtx = new Map(); // refHandle → { canvas, ctx }
  const vizColor = (u) => `rgba(${(u >>> 24) & 255},${(u >>> 16) & 255},${(u >>> 8) & 255},${(u & 255) / 255})`;
  const vizCanvasDraw = (h, ptr, len) => {
    let entry = vizCanvasCtx.get(h);
    if (!entry) {
      const canvas = refHandles[h];
      if (!canvas || typeof canvas.getContext !== "function") return;
      const ctx = canvas.getContext("2d");
      if (!ctx) return;
      entry = { canvas, ctx };
      vizCanvasCtx.set(h, entry);
    }
    const { canvas, ctx } = entry;
    const dpr = window.devicePixelRatio || 1;
    const cw = Math.min(4096, Math.max(1, Math.round(canvas.clientWidth * dpr)));
    const ch = Math.min(4096, Math.max(1, Math.round(canvas.clientHeight * dpr)));
    if (canvas.width !== cw) canvas.width = cw;
    if (canvas.height !== ch) canvas.height = ch;
    const dv = new DataView(memory.buffer);
    const cam_x = dv.getFloat32(ptr, true);
    const cam_y = dv.getFloat32(ptr + 4, true);
    const scale = dv.getFloat32(ptr + 8, true);
    const nc = dv.getUint32(ptr + 12, true);
    const ec = dv.getUint32(ptr + 16, true);
    const hover = dv.getInt32(ptr + 20, true);
    const select = dv.getInt32(ptr + 24, true);
    const r = dv.getFloat32(ptr + 28, true);
    const baseCol = vizColor(dv.getUint32(ptr + 32, true));
    const hoverCol = vizColor(dv.getUint32(ptr + 36, true));
    const selCol = vizColor(dv.getUint32(ptr + 40, true));
    const edgeCol = vizColor(dv.getUint32(ptr + 44, true));
    const nodesOff = ptr + 48;
    const edgesOff = nodesOff + nc * 8;
    const nx = (i) => dv.getFloat32(nodesOff + i * 8, true);
    const ny = (i) => dv.getFloat32(nodesOff + i * 8 + 4, true);
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, cw, ch);
    ctx.setTransform(scale * dpr, 0, 0, scale * dpr, cam_x * dpr, cam_y * dpr);
    ctx.strokeStyle = edgeCol;
    ctx.lineWidth = 1 / Math.max(scale, 0.0001);
    ctx.beginPath();
    for (let e = 0; e < ec; e++) {
      const a = dv.getUint32(edgesOff + e * 8, true);
      const b = dv.getUint32(edgesOff + e * 8 + 4, true);
      ctx.moveTo(nx(a), ny(a));
      ctx.lineTo(nx(b), ny(b));
    }
    ctx.stroke();
    ctx.fillStyle = baseCol;
    ctx.beginPath();
    for (let i = 0; i < nc; i++) {
      ctx.moveTo(nx(i) + r, ny(i));
      ctx.arc(nx(i), ny(i), r, 0, 6.283185307179586);
    }
    ctx.fill();
    const dot = (i, col) => { ctx.fillStyle = col; ctx.beginPath(); ctx.arc(nx(i), ny(i), r, 0, 6.283185307179586); ctx.fill(); };
    if (hover >= 0 && hover < nc) dot(hover, hoverCol);
    if (select >= 0 && select < nc) dot(select, selCol);
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
    viz_canvas_draw: (h, ptr, len) => vizCanvasDraw(h, ptr >>> 0, len >>> 0),
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
    // Phase 7 polish — read a live attribute (probe-then-copy pair, the
    // storage_len/get contract: 0 = missing attr | stale handle | empty).
    // Unlocks morph-from-current: read a <path>'s d, morph FROM it.
    verve_ref_attr_len: (h, np, nl) => {
      const el = refHandles[h];
      if (!el) return 0;
      const v = el.getAttribute(readStr(np, nl));
      return v == null ? 0 : new TextEncoder().encode(v).length;
    },
    verve_ref_get_attr: (h, np, nl, bp, bc) => {
      const el = refHandles[h];
      if (!el) return 0;
      const v = el.getAttribute(readStr(np, nl));
      if (v == null) return 0;
      const b = new TextEncoder().encode(v);
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
    // gl P3 — page-scoped asset region (.vmesh/.venv fetches).
    verve_asset_alloc: exp.verve_asset_alloc,
    verve_asset_reset: exp.verve_asset_reset,
    verve_asset_used: exp.verve_asset_used,
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
    verve_anim_register_setter: (idx) => idx >>> 0,
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
    // ScrollSmoother read-only access (page singleton — no create/kill
    // ops; lifecycle belongs to the page markup).
    // field: 0 smoothed y (native fallback), 1 smoothed velocity px/s,
    //        2 active (1 = smoother installed)
    verve_sm_get: (f) => {
      switch (f >>> 0) {
        case 0:
          return smoother ? smoother.y : window.scrollY || 0;
        case 1:
          return smoother ? smoother.vel : 0;
        case 2:
          return smoother ? 1 : 0;
        default:
          return 0;
      }
    },
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
    // ---- Draggable ops ---------------------------------------------------
    verve_drag_create: (dp, dl) => {
      let desc;
      try {
        desc = JSON.parse(readStr(dp, dl));
      } catch (err) {
        console.warn("verve drag: bad descriptor", err);
        return 0;
      }
      return dragCreate(desc, null) >>> 0;
    },
    // op: 0 kill, 1 disable (cancels active drag/throw), 2 enable,
    //     3 setPos (x/y args; unclamped — bounds resolve per-gesture;
    //     kills any throw first)
    verve_drag_ctrl: (h, op, x, y) => {
      const d = drags.get(h >>> 0);
      if (!d) return;
      op >>>= 0;
      if (op === 0) dragKill(d);
      else if (op === 1) dragDisable(d);
      else if (op === 2) d.enabled = true;
      else if (op === 3) {
        dragStopThrow(d);
        const s = getXform(d.el);
        xformSet(s, "x", x);
        xformSet(s, "y", y);
        animDirty.add(d.el);
        flushXform();
      }
    },
    // field: 0 x, 1 y, 2 vx, 3 vy, 4 dragging, 5 throwing,
    //        6 last drop zone index (-1 none), 7 hover zone index (-1 none)
    // (dead-handle returns 0, ambiguous with zone 0 — existing ABI wart)
    verve_drag_get: (h, f) => {
      const d = drags.get(h >>> 0);
      if (!d) return 0;
      switch (f >>> 0) {
        case 0:
          return getXform(d.el).x;
        case 1:
          return getXform(d.el).y;
        case 2:
          return d.vx;
        case 3:
          return d.vy;
        case 4:
          return d.engaged ? 1 : 0;
        case 5:
          return d.throwing ? 1 : 0;
        case 6:
          return d.drop;
        case 7:
          return d.hover;
        default:
          return 0;
      }
    },
    // ---- Sortable ops ------------------------------------------------------
    // op: 0 kill, 1 disable, 2 enable
    verve_sortable_create: (dp, dl) => {
      let desc;
      try {
        desc = JSON.parse(readStr(dp, dl));
      } catch (err) {
        console.warn("verve sortable: bad descriptor", err);
        return 0;
      }
      return sortableCreate(desc, null) >>> 0;
    },
    verve_sortable_ctrl: (h, op) => {
      const s = sortables.get(h >>> 0);
      if (!s) return;
      if ((op >>> 0) === 0) {
        sortables.delete(h >>> 0);
        // Remove from group registry.
        if (s.grp) {
          const grpSet = sortableGroups.get(s.grp);
          if (grpSet) {
            grpSet.delete(s);
            if (grpSet.size === 0) sortableGroups.delete(s.grp);
          }
        }
      } else if ((op >>> 0) === 1) s.enabled = false;
      else if ((op >>> 0) === 2) s.enabled = true;
    },
    // field: 0 lastFrom, 1 lastTo (-1 = never reordered),
    //        2 lastFromGroup handle (-1 = no group / same-list),
    //        3 lastToGroup handle (-1 = no group / same-list)
    verve_sortable_get: (h, f) => {
      const s = sortables.get(h >>> 0);
      if (!s) return -1;
      switch (f >>> 0) {
        case 0: return s.lastFrom;
        case 1: return s.lastTo;
        case 2: return s.lastFromGroup != null ? s.lastFromGroup : -1;
        case 3: return s.lastToGroup != null ? s.lastToGroup : -1;
        default: return -1;
      }
    },
    // ---- FLIP ops ----------------------------------------------------------
    verve_flip_capture: (sp, sl) => flipCaptureImpl(readStr(sp, sl)) >>> 0,
    verve_flip_play: (state, dp, dl) => {
      let desc;
      try {
        desc = JSON.parse(readStr(dp, dl));
      } catch (err) {
        console.warn("verve flip: bad opts", err);
        flipStates.delete(state >>> 0); // play always consumes
        return 0;
      }
      return flipPlayImpl(state >>> 0, desc) >>> 0;
    },
    verve_flip_discard: (state) => {
      flipStates.delete(state >>> 0);
    },
    // op: 0 kill (snap to identity, NO callback)
    verve_flip_ctrl: (h, op) => {
      const f = flips.get(h >>> 0);
      if (!f) return;
      if ((op >>> 0) === 0) flipKill(f, true);
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
      verve_anim_register_setter: (idx) => {
        const slot = translate(idx);
        // last-registered gl setter is the page default for SSR gl tweens (P7: per-island)
        defaultGlSlot = slot;
        return slot;
      },
      verve_anim_register_gl_resolver: (idx) => {
        const slot = translate(idx);
        // page-default resolver for SSR deferred material:/node: gl tweens
        defaultGlResolver = slot;
        return slot;
      },
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
  const callIslandExport = (islandName, exportName, text, wantVid) => {
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
    // Prefer the caller-supplied instance vid (the one that registered the
    // subscription / request); fall back to the first DOM match only when no
    // vid is threaded through. Selecting the wrong instance leaves its name-
    // keyed signals unresolved → silent no-repaint.
    let vid = (wantVid >>> 0) || 0;
    if (!vid) {
      const el = document.querySelector(`verve-island[data-name="${islandName}"]`);
      vid = el ? parseInt(el.getAttribute("data-vid"), 10) || 0 : 0;
    }
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
      // `verve_host_call` hands these a parsed object; a JS caller may pass a
      // JSON string. Tolerate both — JSON.parse on an object throws.
      a = typeof argsJson === "string" ? JSON.parse(argsJson || "{}") : argsJson || {};
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
  // channel → { es, subs: Map(subKey → {island, export, vid}) }. subKey is the
  // subscriber's vid (so two same-name island instances are DISTINCT subs);
  // falls back to the island name when no vid is threaded (legacy single-sub).
  const pushChannels = new Map();
  const pushSubKey = (a) => (a.vid >>> 0) || a.island;
  window.verveHost.vervePush = (argsJson) => {
    let a = {};
    try {
      // `verve_host_call` hands these a parsed object; a JS caller may pass a
      // JSON string. Tolerate both — JSON.parse on an object throws.
      a = typeof argsJson === "string" ? JSON.parse(argsJson || "{}") : argsJson || {};
    } catch {}
    if (!a.channel || !a.island) return '{"err":"bad args"}';
    if (a.op === "unsub") {
      const entry = pushChannels.get(a.channel);
      if (entry) {
        entry.subs.delete(pushSubKey(a));
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
        // Deliver to EACH subscribed instance under ITS OWN vid, so two
        // same-name islands on one page each update their own state.
        for (const [, sub] of entry.subs)
          callIslandExport(sub.island, sub.export, e.data, sub.vid);
      });
      pushChannels.set(a.channel, entry);
    }
    entry.subs.set(pushSubKey(a), {
      island: a.island,
      export: a.export,
      vid: (a.vid >>> 0) || 0,
    });
    return "{}";
  };

  // WebSocket hub binding (full-duplex push over /push-ws).
  const verveWsSockets = new Map(); // channel → { ws, queue: string[], sub }
  window.verveHost.verveWsConnect = (argsJson) => {
    // verve_host_call hands a parsed object; a JS caller may pass a string.
    const a = typeof argsJson === "string" ? JSON.parse(argsJson || "{}") : argsJson || {}; // { channel, island, export }
    if (!a.channel || verveWsSockets.has(a.channel)) return; // idempotent
    const entry = { ws: null, queue: [], sub: a };
    verveWsSockets.set(a.channel, entry);
    const wsBase = location.origin.replace(/^http/, "ws");
    let backoff = 1000;
    const open = () => {
      const ws = new WebSocket(wsBase + "/push-ws?channel=" + encodeURIComponent(a.channel));
      entry.ws = ws;
      ws.onopen = () => { backoff = 1000; const q = entry.queue; entry.queue = []; for (const m of q) ws.send(m); };
      ws.onmessage = (e) => { callIslandExport(a.island, a.export, typeof e.data === "string" ? e.data : ""); };
      ws.onclose = () => { entry.ws = null; setTimeout(open, backoff); backoff = Math.min(backoff * 2, 15000); };
      ws.onerror = () => { try { ws.close(); } catch (_) {} };
    };
    open();
  };
  window.verveHost.verveWsSend = (argsJson) => {
    const a = typeof argsJson === "string" ? JSON.parse(argsJson || "{}") : argsJson || {}; // { channel, text }
    const entry = verveWsSockets.get(a.channel);
    if (!entry) return;
    if (entry.ws && entry.ws.readyState === 1) entry.ws.send(a.text);
    else entry.queue.push(a.text);
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
      // `verve_host_call` hands these a parsed object; a JS caller may pass a
      // JSON string. Tolerate both — JSON.parse on an object throws.
      a = typeof argsJson === "string" ? JSON.parse(argsJson || "{}") : argsJson || {};
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

  // ---- verve.gl: binary command-stream interpreter (WebGL2 backend) ----
  // Zig encodes a length-prefixed tagged stream (layout frozen by the
  // golden tests in src/core/gl/command.zig); this walks it and issues
  // GL calls. Stream: [len u32 LE][records]. Record: [tag u16][size u16]
  // [payload]. Unknown tags skip via size. Bulk data arrives as
  // (ptr, len) into wasm memory — typed-array views, zero copies.
  let glActiveChunkExports = null;
  const glSetActiveChunk = (exports) => {
    glActiveChunkExports = exports;
  };

  // Per-canvas frame callbacks driven by the master anim rAF (animTick).
  // Membership == "this canvas's loop is running": sinks delete themselves
  // on stop paths instead of skipping a self-reschedule. Shared tick means
  // anim gl-setter writes land the SAME frame the canvas renders (no 1-frame
  // lag — closes the P5 deviation).
  const glSinks = new Set();

  const glCompile = (gl, vsSrc, fsSrc) => {
    const mk = (type, src) => {
      const s = gl.createShader(type);
      gl.shaderSource(s, src);
      gl.compileShader(s);
      if (!gl.getShaderParameter(s, gl.COMPILE_STATUS))
        console.error("verve.gl shader:", gl.getShaderInfoLog(s));
      return s;
    };
    const p = gl.createProgram();
    gl.attachShader(p, mk(gl.VERTEX_SHADER, vsSrc));
    gl.attachShader(p, mk(gl.FRAGMENT_SHADER, fsSrc));
    gl.linkProgram(p);
    if (!gl.getProgramParameter(p, gl.LINK_STATUS))
      console.error("verve.gl link:", gl.getProgramInfoLog(p));
    return p;
  };

  // Bind (or create+cache) the VAO for a given vbuf/ibuf pair, using the
  // active shader's variant to select the correct attribute layout.
  // variant & 1 (variant_vertex_color): loc0 vec3 s24 o0, loc1 vec3 s24 o12
  // variant & 2 (variant_lit_uv):       loc0 vec3 s32 o0, loc1 vec3 s32 o12, loc2 vec2 s32 o24
  // S3 LTC LUTs (WebGL2): a 1×1 rgba16f dummy bound to units 10/11 by default so
  // every PBR draw has complete textures at the LTC samplers even before the real
  // LUTs load (or when no area light is active — the shader skips sampling then).
  // RGBA16F needs EXT_color_buffer_float for render targets but plain sampling of
  // a half-float texture works in WebGL2 core; texImage2D with HALF_FLOAT is fine.
  const glEnsureLtcDummy = (st) => {
    if (st.ltcDummy) return st.ltcDummy;
    const gl = st.gl;
    const tex = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, tex);
    // 1×1 RGBA16F, all-zero (4 halfs = 0x0000). Content irrelevant (never sampled
    // when area_count=0). NEAREST min, LINEAR mag, CLAMP_TO_EDGE — matches real LUTs.
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA16F, 1, 1, 0, gl.RGBA, gl.HALF_FLOAT, new Uint16Array([0, 0, 0, 0]));
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    st.ltcDummy = tex;
    return tex;
  };
  // Bind the LTC dummy (or, if already loaded, the real LUTs) to units 10/11.
  const glBindLtcDummy = (st) => {
    const gl = st.gl;
    if (!gl) return;
    const mat = st.ltcMat || glEnsureLtcDummy(st);
    const mag = st.ltcMag || glEnsureLtcDummy(st);
    gl.activeTexture(gl.TEXTURE10);
    gl.bindTexture(gl.TEXTURE_2D, mat);
    gl.activeTexture(gl.TEXTURE11);
    gl.bindTexture(gl.TEXTURE_2D, mag);
  };
  // Lazily fetch /gl/ltc.bin (65536B) ONCE, split into two 64×64 rgba16f textures
  // (bytes 0..32767 → ltc_mat, 32768..65535 → ltc_mag; already little-endian f16).
  // CLAMP_TO_EDGE, mag=LINEAR, min=NEAREST. Cached on st.ltcMat/st.ltcMag. The
  // fetch is guarded by st.ltcLoading so it fires exactly once.
  const glEnsureLtc = (st) => {
    if (st.ltcMat || st.ltcLoading) return; // loaded or in-flight
    st.ltcLoading = true;
    fetch("/gl/ltc.bin")
      .then((r) => r.arrayBuffer())
      .then((buf) => {
        const gl = st.gl;
        if (!gl) return;
        const make = (byteOffset) => {
          const tex = gl.createTexture();
          gl.bindTexture(gl.TEXTURE_2D, tex);
          // 64×64 RGBA16F. The 32768 bytes = 16384 halfs = 64×64×4. HALF_FLOAT
          // expects a Uint16Array view over the f16 bytes.
          gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA16F, 64, 64, 0, gl.RGBA, gl.HALF_FLOAT,
            new Uint16Array(buf, byteOffset, 16384));
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
          return tex;
        };
        st.ltcMat = make(0);      // bytes 0..32767
        st.ltcMag = make(32768);  // bytes 32768..65535
        // Bind the freshly-loaded LUTs to units 10/11 right away.
        glBindLtcDummy(st);
      })
      .catch(() => { st.ltcLoading = false; }); // allow a later retry on failure
  };

  const bindVaoFor = (st, vh, ih) => {
    const gl = st.gl;
    const vb = st.buffers[vh];
    const ib = st.buffers[ih];
    if (!vb || !ib) return false; // defense-in-depth; callers also guard
    const variant = st.active ? st.active.variant : 1;
    const key = `${vh}:${ih}:${variant}`;
    let vao = st.vaos.get(key);
    if (!vao) {
      vao = gl.createVertexArray();
      gl.bindVertexArray(vao);
      gl.bindBuffer(gl.ARRAY_BUFFER, vb.buf);
      if (variant & 64) {
        // depth-only (shadow pass): PBR-layout buffer, position attrib only.
        gl.enableVertexAttribArray(0);
        gl.vertexAttribPointer(0, 3, gl.FLOAT, false, 48, 0);
      } else if (variant & 4) {
        // PBR: pos f32x3 @0, normal f32x3 @12, tangent f32x4 @24, uv f32x2 @40.
        // Skinned (variant & 0x80) widens the vertex to stride 56, appending
        // joints (u8x4 @48) + weights (u8x4 @52); attribs 0-3 then re-stride to
        // 56. Non-skinned keeps stride 48 / attribs 0-3 only. The VAO cache key
        // already carries `variant`, so skinned + non-skinned uses of the same
        // buffers get distinct VAOs (no attrib 4/5 leakage onto the 48 path).
        const stride = (variant & 128) ? 56 : 48;
        gl.enableVertexAttribArray(0);
        gl.vertexAttribPointer(0, 3, gl.FLOAT, false, stride, 0);
        gl.enableVertexAttribArray(1);
        gl.vertexAttribPointer(1, 3, gl.FLOAT, false, stride, 12);
        gl.enableVertexAttribArray(2);
        gl.vertexAttribPointer(2, 4, gl.FLOAT, false, stride, 24);
        gl.enableVertexAttribArray(3);
        gl.vertexAttribPointer(3, 2, gl.FLOAT, false, stride, 40);
        if (variant & 128) {
          // joints: uvec4 a_joints — integer attrib, NOT normalized
          gl.enableVertexAttribArray(4);
          gl.vertexAttribIPointer(4, 4, gl.UNSIGNED_BYTE, 56, 48);
          // weights: vec4 a_weights — u8 normalized to [0,1]
          gl.enableVertexAttribArray(5);
          gl.vertexAttribPointer(5, 4, gl.UNSIGNED_BYTE, true, 56, 52);
        }
      } else if (variant & 2) {
        // lit/textured: pos f32x3 @0, normal f32x3 @12, uv f32x2 @24, stride 32
        gl.enableVertexAttribArray(0);
        gl.vertexAttribPointer(0, 3, gl.FLOAT, false, 32, 0);
        gl.enableVertexAttribArray(1);
        gl.vertexAttribPointer(1, 3, gl.FLOAT, false, 32, 12);
        gl.enableVertexAttribArray(2);
        gl.vertexAttribPointer(2, 2, gl.FLOAT, false, 32, 24);
      } else {
        // unlit/vertex-color: pos f32x3 @0, color f32x3 @12, stride 24
        gl.enableVertexAttribArray(0);
        gl.vertexAttribPointer(0, 3, gl.FLOAT, false, 24, 0);
        gl.enableVertexAttribArray(1);
        gl.vertexAttribPointer(1, 3, gl.FLOAT, false, 24, 12);
      }
      gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, ib.buf);
      st.vaos.set(key, vao);
    }
    gl.bindVertexArray(vao);
    return true;
  };

  // Post-process param upload: maps the f32 param array to whichever uniforms
  // exist on the program. Unused locations are null and silently skipped.
  // bright: p[0]=threshold; blur: p[0..1]=texel, p[2..3]=dir;
  // composite: p[0]=intensity; fxaa: p[0..1]=texel.
  const applyPostParams = (gl, sh, dv, ptr, count) => {
    const p = [];
    for (let i = 0; i < count; i++) p.push(dv.getFloat32(ptr + i * 4, true));
    if (sh.uThreshold && count >= 1) gl.uniform1f(sh.uThreshold, p[0]);
    if (sh.uIntensity && count >= 1) gl.uniform1f(sh.uIntensity, p[0]);
    if (sh.uTexel && count >= 2) gl.uniform2f(sh.uTexel, p[0], p[1]);
    if (sh.uDir && count >= 4) gl.uniform2f(sh.uDir, p[2], p[3]);
  };

  const glInterpret = (st, ptr) => {
    // Fresh DataView every frame: memory.buffer detaches on wasm growth.
    const dv = new DataView(memory.buffer);
    const total = dv.getUint32(ptr, true);
    let off = ptr + 4;
    const end = off + total;
    const gl = st.gl;
    while (off < end) {
      const tag = dv.getUint16(off, true);
      const size = dv.getUint16(off + 2, true);
      off += 4;
      switch (tag) {
        case 1: { // BEGIN_FRAME
          gl.viewport(0, 0, dv.getUint32(off + 16, true), dv.getUint32(off + 20, true));
          gl.clearColor(
            dv.getFloat32(off, true),
            dv.getFloat32(off + 4, true),
            dv.getFloat32(off + 8, true),
            dv.getFloat32(off + 12, true),
          );
          // Re-enable depth test each frame: draw_fullscreen_quad (case 25) disables
          // it for the post pass, and WebGL state persists across frames.
          gl.enable(gl.DEPTH_TEST);
          // Restore depth mask: transparent SET_PIPELINE sets depthMask(false) and
          // WebGL state persists across frames — gl.clear(DEPTH_BUFFER_BIT) no-ops
          // when the mask is false, breaking depth each frame after a blend pass.
          gl.depthMask(true);
          gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
          // Default CSM off each frame; set_csm (tag 36) re-enables when a CSM caster
          // is active, so a non-CSM frame never carries stale cascade data.
          st.frameCascadeCount = 0;
          // Default no area lights each frame; set_area_lights (tag 37) re-enables.
          st.frameAreaCount = 0;
          st.frameAreaLights = null;
          // Ensure the 1×1 rgba16f LTC dummy is bound to units 10/11 by default so
          // every PBR draw has valid (incomplete-free) textures at those samplers
          // even before /gl/ltc.bin loads. Real LUTs (tag 38) override these binds.
          glBindLtcDummy(st);
          break;
        }
        case 2: { // CREATE_BUFFER
          const handle = dv.getUint32(off, true);
          const kind = dv.getUint32(off + 4, true);
          const p = dv.getUint32(off + 8, true);
          const len = dv.getUint32(off + 12, true);
          const target = kind === 1 ? gl.ELEMENT_ARRAY_BUFFER : gl.ARRAY_BUFFER;
          const buf = gl.createBuffer();
          gl.bindBuffer(target, buf);
          gl.bufferData(target, new Uint8Array(memory.buffer, p, len), gl.STATIC_DRAW);
          st.buffers[handle] = { buf, target };
          break;
        }
        case 3: { // CREATE_SHADER — variant (word 1) selects layout + uniforms
          const handle = dv.getUint32(off, true);
          const variant = dv.getUint32(off + 4, true);
          const vs = readStr(dv.getUint32(off + 8, true), dv.getUint32(off + 12, true));
          const fs = readStr(dv.getUint32(off + 16, true), dv.getUint32(off + 20, true));
          const prog = glCompile(gl, vs, fs);
          const sh = {
            prog,
            variant,
            mvp: gl.getUniformLocation(prog, "u_mvp"),
            color: (variant & 2) ? gl.getUniformLocation(prog, "u_color") : null,
            tex: (variant & 2) ? gl.getUniformLocation(prog, "u_tex") : null,
          };
          if (variant & 4) { // PBR über-shader: cache extra locations + preset samplers
            sh.model = gl.getUniformLocation(prog, "u_model");
            sh.normalMat = gl.getUniformLocation(prog, "u_normal_mat");
            sh.cameraPos = gl.getUniformLocation(prog, "u_camera_pos");
            sh.material = gl.getUniformLocation(prog, "u_material");
            sh.lights = gl.getUniformLocation(prog, "u_lights");
            sh.lightCount = gl.getUniformLocation(prog, "u_light_count");
            sh.prefMips = gl.getUniformLocation(prog, "u_prefiltered_mips");
            // S3 area lights (LTC): count + the area_lights[] vec4 array base.
            sh.areaCount = gl.getUniformLocation(prog, "u_area_count");
            sh.areaLights = gl.getUniformLocation(prog, "u_area_lights[0]");
            // Sampler units are fixed at link time. Only set the ones that exist
            // in this variant's compiled program (variant-stripped samplers
            // return a null location). useProgram is required before uniform1i;
            // SET_PIPELINE re-useProgram's every frame, so this stray bind is
            // harmless to the active-program state machine.
            gl.useProgram(prog);
            const setSampler = (name, unit) => {
              const loc = gl.getUniformLocation(prog, name);
              if (loc) gl.uniform1i(loc, unit);
            };
            setSampler("u_base_tex", 0);
            setSampler("u_mr_tex", 1);
            setSampler("u_normal_tex", 2); // only when variant & 8
            setSampler("u_emissive_tex", 3); // only when variant & 16
            setSampler("u_occlusion_tex", 4);
            setSampler("u_irradiance", 5);
            setSampler("u_prefiltered", 6);
            setSampler("u_brdf_lut", 7);
            // S3 LTC LUT samplers — fixed units 10/11 (ALWAYS declared; a 1×1
            // dummy is bound until /gl/ltc.bin loads / when area_count=0).
            setSampler("u_ltc_mat", 10);
            setSampler("u_ltc_mag", 11);
            if (variant & 32) { // shadow receiver: shadow_vp[] array + atlas depth sampler (unit 8)
              sh.shadowVp = gl.getUniformLocation(prog, "u_shadow_vp[0]");
              setSampler("u_shadow_map", 8);
              // CSM frame-globals (only present in CSM-capable receivers; no-op on others).
              sh.cascadeCount = gl.getUniformLocation(prog, "u_cascade_count");
              sh.cascadeSplits = gl.getUniformLocation(prog, "u_cascade_splits");
              sh.viewForward = gl.getUniformLocation(prog, "u_view_forward");
            }
            // Skinned variant: cache the bone-palette array base location.
            // Querying "u_bones[0]" yields the array's base location, which
            // uniformMatrix4fv uploads the whole mat4[] against (case 21).
            sh.skinned = (variant & 128) !== 0;
            sh.bones = sh.skinned ? gl.getUniformLocation(prog, "u_bones[0]") : null;
          }
          if (variant & 0x100) { // variant_post: cache post-process uniform locations
            sh.tex0 = gl.getUniformLocation(prog, "u_tex0");
            sh.tex1 = gl.getUniformLocation(prog, "u_tex1");
            sh.uThreshold = gl.getUniformLocation(prog, "u_threshold");
            sh.uTexel = gl.getUniformLocation(prog, "u_texel");
            sh.uDir = gl.getUniformLocation(prog, "u_dir");
            sh.uIntensity = gl.getUniformLocation(prog, "u_intensity");
          }
          if (variant & 0x1000) { // variant_instanced: u_vp replaces u_mvp/u_model
            sh.vp = gl.getUniformLocation(prog, "u_vp");
          }
          if (variant & 0x2000) { // variant_fog: distance fog uniforms
            sh.fog0 = gl.getUniformLocation(prog, "u_fog0");
            sh.fog1 = gl.getUniformLocation(prog, "u_fog1");
          }
          if (variant & 0x4000) { // variant_morph: morph-target sampler + weight uniforms
            // u_morph_tex is bound to a fixed unit (9); set it once at link time.
            const morphLoc = gl.getUniformLocation(prog, "u_morph_tex");
            if (morphLoc) gl.uniform1i(morphLoc, 9);
            sh.morphIdx   = gl.getUniformLocation(prog, "u_morph_idx[0]");
            sh.morphWt    = gl.getUniformLocation(prog, "u_morph_wt[0]");
            sh.morphCount = gl.getUniformLocation(prog, "u_morph_count");
          }
          if (variant & 0x8000) { // variant_shadow_point: RGBA8 atlas + light uniforms
            // u_point_atlas is bound to slot 9 (tex_slot_point_shadow); set once at link time.
            const atlasLoc = gl.getUniformLocation(prog, "u_point_atlas");
            if (atlasLoc) gl.uniform1i(atlasLoc, 9);
            sh.pointAtlas    = atlasLoc; // cached for bind_point_shadow (slot bind confirm)
            // Multi-caster: u_point_light_pos/u_point_far removed (Task 1) — the
            // receiver reads each caster's lpos/far from the per-light loop vars.
          }
          st.shaders[handle] = sh;
          break;
        }
        case 4: { // SET_PIPELINE
          const sh = st.shaders[dv.getUint32(off, true)];
          if (!sh) break;
          const state = dv.getUint32(off + 4, true);
          gl.useProgram(sh.prog);
          st.active = sh;
          if (state & 1) gl.enable(gl.DEPTH_TEST);
          else gl.disable(gl.DEPTH_TEST);
          if (state & 8) { // state_cull_front
            gl.enable(gl.CULL_FACE);
            gl.cullFace(gl.FRONT);
          } else if (state & 2) { // state_cull_back
            gl.enable(gl.CULL_FACE);
            gl.cullFace(gl.BACK);
          } else gl.disable(gl.CULL_FACE);
          if (state & 4) { // state_blend: src-alpha over; depth-write off
            gl.enable(gl.BLEND);
            gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
            gl.depthMask(false);
          } else {
            gl.disable(gl.BLEND);
            gl.depthMask(true);
          }
          break;
        }
        case 5: { // DRAW — P1 unlit path; byte offset always 0, no color uniform
          const vh = dv.getUint32(off, true);
          const ih = dv.getUint32(off + 4, true);
          const count = dv.getUint32(off + 8, true);
          const mvpPtr = dv.getUint32(off + 12, true);
          if (!st.buffers[vh] || !st.buffers[ih] || !st.active) break;
          bindVaoFor(st, vh, ih);
          gl.uniformMatrix4fv(st.active.mvp, false, new Float32Array(memory.buffer, mvpPtr, 16));
          gl.drawElements(gl.TRIANGLES, count, gl.UNSIGNED_SHORT, 0);
          break;
        }
        case 6: // END_FRAME
          break;
        case 7: { // CREATE_TEXTURE — raw RGBA8 + generated mips
          const handle = dv.getUint32(off, true);
          const w = dv.getUint32(off + 4, true);
          const h = dv.getUint32(off + 8, true);
          const p = dv.getUint32(off + 12, true);
          const len = dv.getUint32(off + 16, true);
          const tex = gl.createTexture();
          gl.bindTexture(gl.TEXTURE_2D, tex);
          gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, w, h, 0, gl.RGBA,
            gl.UNSIGNED_BYTE, new Uint8Array(memory.buffer, p, len));
          gl.generateMipmap(gl.TEXTURE_2D);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
          st.textures[handle] = { tex, target: gl.TEXTURE_2D };
          break;
        }
        case 15: { // CREATE_TEXTURE_SRGB — like tag 7 but SRGB8_ALPHA8 internal
          // (hardware sRGB→linear on sample; for base-color + emissive maps).
          const handle = dv.getUint32(off, true);
          const w = dv.getUint32(off + 4, true);
          const h = dv.getUint32(off + 8, true);
          const p = dv.getUint32(off + 12, true);
          const len = dv.getUint32(off + 16, true);
          const tex = gl.createTexture();
          gl.bindTexture(gl.TEXTURE_2D, tex);
          gl.texImage2D(gl.TEXTURE_2D, 0, gl.SRGB8_ALPHA8, w, h, 0, gl.RGBA,
            gl.UNSIGNED_BYTE, new Uint8Array(memory.buffer, p, len));
          gl.generateMipmap(gl.TEXTURE_2D);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
          st.textures[handle] = { tex, target: gl.TEXTURE_2D };
          break;
        }
        case 8: { // BIND_TEXTURE
          const slot = dv.getUint32(off, true);
          const entry = st.textures[dv.getUint32(off + 4, true)];
          if (!entry) break;
          gl.activeTexture(gl.TEXTURE0 + slot);
          gl.bindTexture(entry.target, entry.tex);
          if (st.active && st.active.tex) gl.uniform1i(st.active.tex, slot);
          break;
        }
        case 9: { // DRAW_SUB — byte-offset submesh draw with color uniform
          const vh = dv.getUint32(off, true);
          const ih = dv.getUint32(off + 4, true);
          const byteOff = dv.getUint32(off + 8, true);
          const count = dv.getUint32(off + 12, true);
          const mvpPtr = dv.getUint32(off + 16, true);
          const colorPtr = dv.getUint32(off + 20, true);
          if (!st.buffers[vh] || !st.buffers[ih] || !st.active) break;
          bindVaoFor(st, vh, ih);
          gl.uniformMatrix4fv(st.active.mvp, false, new Float32Array(memory.buffer, mvpPtr, 16));
          if (st.active.color)
            gl.uniform4fv(st.active.color, new Float32Array(memory.buffer, colorPtr, 4));
          gl.drawElements(gl.TRIANGLES, count, gl.UNSIGNED_SHORT, byteOff);
          break;
        }
        case 10: { // CREATE_TEXTURE_EX — explicit-mip 2D/cube, RGBA8 or RGBA16F, no auto-mip
          const handle = dv.getUint32(off, true);
          const target = dv.getUint32(off + 4, true);
          const format = dv.getUint32(off + 8, true);
          const w = dv.getUint32(off + 12, true);
          const h = dv.getUint32(off + 16, true);
          const mips = dv.getUint32(off + 20, true);
          const p = dv.getUint32(off + 24, true);
          // off + 28 = byte_len (informational; views derive size per mip/face)
          const cube = target === 1;
          const glTarget = cube ? gl.TEXTURE_CUBE_MAP : gl.TEXTURE_2D;
          const f16 = format === 1;
          const internal = f16 ? gl.RGBA16F : gl.RGBA8;
          const type = f16 ? gl.HALF_FLOAT : gl.UNSIGNED_BYTE;
          const bpt = f16 ? 8 : 4; // bytes per texel (RGBA)
          const tex = gl.createTexture();
          gl.bindTexture(glTarget, tex);
          const faces = cube ? 6 : 1;
          let cursor = p;
          // Layout: mip-major then face-major (cube: +X,-X,+Y,-Y,+Z,-Z).
          for (let m = 0; m < mips; m++) {
            const mw = Math.max(1, w >> m);
            const mh = Math.max(1, h >> m);
            for (let face = 0; face < faces; face++) {
              const count = mw * mh * 4;
              const view = f16
                ? new Uint16Array(memory.buffer, cursor, count)
                : new Uint8Array(memory.buffer, cursor, count);
              const dst = cube ? gl.TEXTURE_CUBE_MAP_POSITIVE_X + face : gl.TEXTURE_2D;
              gl.texImage2D(dst, m, internal, mw, mh, 0, gl.RGBA, type, view);
              cursor += mw * mh * bpt;
            }
          }
          gl.texParameteri(glTarget, gl.TEXTURE_MAX_LEVEL, mips - 1);
          gl.texParameteri(glTarget, gl.TEXTURE_MIN_FILTER,
            mips > 1 ? gl.LINEAR_MIPMAP_LINEAR : gl.LINEAR);
          gl.texParameteri(glTarget, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
          gl.texParameteri(glTarget, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
          gl.texParameteri(glTarget, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
          st.textures[handle] = { tex, target: glTarget };
          break;
        }
        case 11: { // SET_LIGHTS — uniform4fv on the active PBR program (defensive skip)
          const count = dv.getUint32(off, true);
          const p = dv.getUint32(off + 4, true);
          if (st.active && st.active.lights) {
            // u_lights is vec4[16] (64 floats); count*16 floats (4 vec4/light):
            // v0=[type,intensity,pos.x,pos.y], v1=[pos.z,dir.x,dir.y,dir.z],
            // v2=[color.r,color.g,color.b,range], v3=[cosIn,cosOut,__,__].
            gl.uniform4fv(st.active.lights, new Float32Array(memory.buffer, p, count * 16));
            if (st.active.lightCount) gl.uniform1i(st.active.lightCount, count);
          }
          break;
        }
        case 36: { // SET_CSM — cache CSM frame-globals (cascade_count, splits, view_forward).
          // Payload (command.zig Encoder.setCsm, 12B): count | splits_ptr | view_forward_ptr.
          // splits_ptr → 4 f32 (view-space FAR per cascade); view_forward_ptr → 3 f32 look dir.
          // Frame-global, like set_lights; written into the receiver in bind_shadow_map (20).
          st.frameCascadeCount = dv.getUint32(off, true);
          st.frameCascadeSplits = new Float32Array(memory.buffer, dv.getUint32(off + 4, true), 4).slice();
          st.frameViewForward = new Float32Array(memory.buffer, dv.getUint32(off + 8, true), 3).slice();
          break;
        }
        case 12: { // BIND_IBL — irradiance(5)/prefiltered(6)/brdf_lut(7) on active program
          const irr = st.textures[dv.getUint32(off, true)];
          const spec = st.textures[dv.getUint32(off + 4, true)];
          const lut = st.textures[dv.getUint32(off + 8, true)];
          const specMips = dv.getUint32(off + 12, true);
          if (irr) {
            gl.activeTexture(gl.TEXTURE5);
            gl.bindTexture(irr.target, irr.tex);
          }
          if (spec) {
            gl.activeTexture(gl.TEXTURE6);
            gl.bindTexture(spec.target, spec.tex);
          }
          if (lut) {
            gl.activeTexture(gl.TEXTURE7);
            gl.bindTexture(lut.target, lut.tex);
          }
          if (st.active && st.active.prefMips) gl.uniform1f(st.active.prefMips, specMips);
          break;
        }
        case 37: { // SET_AREA_LIGHTS — cache the per-frame area-light array (LTC).
          // Payload (command.zig Encoder.setAreaLights, 8B): count | ptr. Each area
          // light = 16 f32 (4 vec4): a0=[pos,intensity] a1=[ex,two_sided]
          // a2=[ey,shadow_slot] a3=[color,shadow_kind]. Cached like set_csm; each
          // DRAW_PBR writes u_area_count/u_area_lights on its active program. Max 16.
          const count = dv.getUint32(off, true);
          const p = dv.getUint32(off + 4, true);
          const n = Math.min(count, 16);
          st.frameAreaCount = n;
          st.frameAreaLights = (n > 0) ? new Float32Array(memory.buffer, p, n * 16).slice() : null;
          break;
        }
        case 38: { // BIND_LTC_LUT — ensure the LTC LUTs are loaded; bind to units 10/11.
          // Payload (command.zig Encoder.bindLtcLut, 8B): mat_handle | mag_handle.
          // Handles are ADVISORY — the bridge OWNS the LUTs (global) and fetches
          // them by fixed URL (/gl/ltc.bin) ONCE. Until loaded, the 1×1 dummy stays
          // bound at units 10/11 (set per-draw). On load, bind the real LUTs here.
          glEnsureLtc(st);
          if (st.ltcMat && st.ltcMag) {
            gl.activeTexture(gl.TEXTURE10);
            gl.bindTexture(gl.TEXTURE_2D, st.ltcMat);
            gl.activeTexture(gl.TEXTURE11);
            gl.bindTexture(gl.TEXTURE_2D, st.ltcMag);
          }
          break;
        }
        case 13: { // DRAW_PBR — full PBR submesh draw
          const vh = dv.getUint32(off, true);
          const ih = dv.getUint32(off + 4, true);
          const byteOff = dv.getUint32(off + 8, true);
          const count = dv.getUint32(off + 12, true);
          const mvpPtr = dv.getUint32(off + 16, true);
          const modelPtr = dv.getUint32(off + 20, true);
          const normalPtr = dv.getUint32(off + 24, true);
          const materialPtr = dv.getUint32(off + 28, true);
          const cameraPtr = dv.getUint32(off + 32, true);
          if (!st.buffers[vh] || !st.buffers[ih] || !st.active) break;
          bindVaoFor(st, vh, ih);
          gl.uniformMatrix4fv(st.active.mvp, false, new Float32Array(memory.buffer, mvpPtr, 16));
          if (st.active.model)
            gl.uniformMatrix4fv(st.active.model, false, new Float32Array(memory.buffer, modelPtr, 16));
          if (st.active.normalMat)
            gl.uniformMatrix3fv(st.active.normalMat, false, new Float32Array(memory.buffer, normalPtr, 9));
          if (st.active.material)
            gl.uniform4fv(st.active.material, new Float32Array(memory.buffer, materialPtr, 12));
          if (st.active.cameraPos)
            gl.uniform3fv(st.active.cameraPos, new Float32Array(memory.buffer, cameraPtr, 3));
          // S3 area lights: write the cached per-frame array on the active program.
          // The shader ALWAYS samples u_ltc_mat/u_ltc_mag (units 10/11) — the dummy
          // (or real LUTs, bound by tag 38) covers them; area_count=0 → loop skipped.
          if (st.active.areaCount)
            gl.uniform1i(st.active.areaCount, st.frameAreaCount | 0);
          if (st.active.areaLights && st.frameAreaCount > 0 && st.frameAreaLights)
            gl.uniform4fv(st.active.areaLights, st.frameAreaLights);
          gl.drawElements(gl.TRIANGLES, count, gl.UNSIGNED_SHORT, byteOff);
          break;
        }
        case 27: { // DRAW_PBR_INSTANCED — N instances via per-instance attr mat4+color
          const vh = dv.getUint32(off, true);
          const ih = dv.getUint32(off + 4, true);
          const byteOff = dv.getUint32(off + 8, true);
          const count = dv.getUint32(off + 12, true);
          const instancePtr = dv.getUint32(off + 16, true);
          const instanceCount = dv.getUint32(off + 20, true);
          const vpPtr = dv.getUint32(off + 24, true);
          const materialPtr = dv.getUint32(off + 28, true);
          const cameraPtr = dv.getUint32(off + 32, true);
          if (!st.buffers[vh] || !st.buffers[ih] || !st.active) break;
          // Ensure a persistent ARRAY_BUFFER for per-instance data (80 B/instance:
          // 16 f32 mat4 col-major + 4 f32 color rgba). Lazy-create, then stream.
          if (!st.instanceBuf) st.instanceBuf = gl.createBuffer();
          gl.bindBuffer(gl.ARRAY_BUFFER, st.instanceBuf);
          gl.bufferData(gl.ARRAY_BUFFER, new Uint8Array(memory.buffer, instancePtr, instanceCount * 80), gl.DYNAMIC_DRAW);
          // bindVaoFor uses st.active.variant as the cache key; variant_instanced
          // (0x1000) produces a distinct key from non-instanced PBR, so existing
          // VAOs are untouched. After binding the keyed VAO we layer the instance
          // attribs (4-8) on top: they are stored in the VAO as part of creation.
          const gl2 = st.gl;
          const vb = st.buffers[vh];
          const ib = st.buffers[ih];
          const iVariant = st.active.variant;
          const iKey = `${vh}:${ih}:${iVariant}`;
          let iVao = st.vaos.get(iKey);
          if (!iVao) {
            iVao = gl2.createVertexArray();
            gl2.bindVertexArray(iVao);
            // Core mesh attribs 0-3: PBR layout stride 48 (non-skinned instanced only)
            gl2.bindBuffer(gl2.ARRAY_BUFFER, vb.buf);
            gl2.enableVertexAttribArray(0);
            gl2.vertexAttribPointer(0, 3, gl2.FLOAT, false, 48, 0);   // pos
            gl2.enableVertexAttribArray(1);
            gl2.vertexAttribPointer(1, 3, gl2.FLOAT, false, 48, 12);  // normal
            gl2.enableVertexAttribArray(2);
            gl2.vertexAttribPointer(2, 4, gl2.FLOAT, false, 48, 24);  // tangent
            gl2.enableVertexAttribArray(3);
            gl2.vertexAttribPointer(3, 2, gl2.FLOAT, false, 48, 40);  // uv
            gl2.bindBuffer(gl2.ELEMENT_ARRAY_BUFFER, ib.buf);
            // Per-instance attribs from instanceBuf: mat4 columns at loc 4-7,
            // color rgba at loc 8. stride=80, divisor=1 for all.
            gl2.bindBuffer(gl2.ARRAY_BUFFER, st.instanceBuf);
            for (let i = 0; i < 4; i++) {
              gl2.enableVertexAttribArray(4 + i);
              gl2.vertexAttribPointer(4 + i, 4, gl2.FLOAT, false, 80, i * 16);
              gl2.vertexAttribDivisor(4 + i, 1);
            }
            gl2.enableVertexAttribArray(8);
            gl2.vertexAttribPointer(8, 4, gl2.FLOAT, false, 80, 64);
            gl2.vertexAttribDivisor(8, 1);
            st.vaos.set(iKey, iVao);
          }
          gl2.bindVertexArray(iVao);
          // Per-draw uniforms: u_vp (view·proj), material, cameraPos — no u_mvp/u_model.
          if (st.active.vp)
            gl2.uniformMatrix4fv(st.active.vp, false, new Float32Array(memory.buffer, vpPtr, 16));
          if (st.active.material)
            gl2.uniform4fv(st.active.material, new Float32Array(memory.buffer, materialPtr, 12));
          if (st.active.cameraPos)
            gl2.uniform3fv(st.active.cameraPos, new Float32Array(memory.buffer, cameraPtr, 3));
          // Instanced is non-area: zero area_count so the shader skips the LTC loop.
          if (st.active.areaCount) gl2.uniform1i(st.active.areaCount, 0);
          gl2.drawElementsInstanced(gl2.TRIANGLES, count, gl2.UNSIGNED_SHORT, byteOff, instanceCount);
          break;
        }
        case 14: { // DELETE_RESOURCE — frees one GPU object; slot may be reused after
          const kind = dv.getUint32(off, true);
          const handle = dv.getUint32(off + 4, true);
          if (kind === 0) { // buffer
            const entry = st.buffers[handle];
            if (entry) {
              gl.deleteBuffer(entry.buf);
              st.buffers[handle] = null;
              // Cached VAOs reference vbuf/ibuf in their `${vh}:${ih}:${variant}`
              // key; a freed buffer makes them dangling. Drop + delete any match.
              for (const [key, vao] of st.vaos) {
                const [vh, ih] = key.split(":");
                if (vh === String(handle) || ih === String(handle)) {
                  gl.deleteVertexArray(vao);
                  st.vaos.delete(key);
                }
              }
            }
          } else if (kind === 1) { // texture
            const entry = st.textures[handle];
            if (entry) {
              gl.deleteTexture(entry.tex);
              st.textures[handle] = null;
            }
          } else if (kind === 2) { // shader
            const sh = st.shaders[handle];
            if (sh) {
              gl.deleteProgram(sh.prog);
              if (st.active === sh) st.active = null;
              st.shaders[handle] = null;
            }
          } else if (kind === 3) { // shadow map (FBO + depth texture)
            const sm = st.shadowMaps[handle];
            if (sm) {
              gl.deleteFramebuffer(sm.fbo);
              gl.deleteTexture(sm.tex);
              st.shadowMaps[handle] = null;
            }
          } else if (kind === 4) { // render_target (FBO + color + optional depth tex)
            const rt = st.renderTargets[handle];
            if (rt) {
              gl.deleteFramebuffer(rt.fbo);
              gl.deleteTexture(rt.colorTex);
              if (rt.depthTex) gl.deleteTexture(rt.depthTex);
              st.renderTargets[handle] = null;
            }
          }
          break;
        }
        case 16: { // CREATE_SHADOW_MAP — FBO + depth texture; now a 2D shadow ATLAS (4096²)
          // Multi-caster: T3 passes size=4096; up to 4 casters each render into a
          // 1024² tile (col=slot%4, row=slot/4) of this single shared atlas texture.
          const handle = dv.getUint32(off, true);
          const size = dv.getUint32(off + 4, true);
          const tex = gl.createTexture();
          gl.bindTexture(gl.TEXTURE_2D, tex);
          gl.texImage2D(gl.TEXTURE_2D, 0, gl.DEPTH_COMPONENT24, size, size, 0,
            gl.DEPTH_COMPONENT, gl.UNSIGNED_INT, null);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
          // Hardware depth comparison → sampler2DShadow PCF (2×2 per tap).
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_COMPARE_MODE, gl.COMPARE_REF_TO_TEXTURE);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_COMPARE_FUNC, gl.LEQUAL);
          const fbo = gl.createFramebuffer();
          gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
          gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.TEXTURE_2D, tex, 0);
          gl.drawBuffers([gl.NONE]); // depth-only: no color attachment
          gl.readBuffer(gl.NONE);
          gl.bindFramebuffer(gl.FRAMEBUFFER, null);
          st.shadowMaps[handle] = { fbo, tex, size };
          break;
        }
        case 17: { // BEGIN_SHADOW_PASS — render depth into one ATLAS TILE from the light's POV
          // NEW payload {atlas_handle, depth_shader_handle, col, row, tile} (20B).
          const sm = st.shadowMaps[dv.getUint32(off, true)];
          const sh = st.shaders[dv.getUint32(off + 4, true)];
          const col = dv.getUint32(off + 8, true);
          const row = dv.getUint32(off + 12, true);
          const tile = dv.getUint32(off + 16, true);
          if (!sm || !sh) break;
          gl.bindFramebuffer(gl.FRAMEBUFFER, sm.fbo);
          const x = col * tile, y = row * tile;
          gl.viewport(x, y, tile, tile);
          // Scissor restricts both viewport and the depth clear to this tile so
          // multiple casters rendering into the same atlas don't wipe each other.
          gl.enable(gl.SCISSOR_TEST);
          gl.scissor(x, y, tile, tile);
          // Restore depth mask so the depth-only clear actually writes.
          gl.depthMask(true);
          gl.clear(gl.DEPTH_BUFFER_BIT);
          gl.useProgram(sh.prog);
          st.active = sh;
          gl.enable(gl.DEPTH_TEST);
          // Front-face culling during the depth pass pushes self-shadow acne
          // behind the geometry instead of onto its lit faces.
          gl.enable(gl.CULL_FACE);
          gl.cullFace(gl.FRONT);
          break;
        }
        case 18: { // END_SHADOW_PASS — back to the canvas framebuffer
          gl.disable(gl.SCISSOR_TEST);
          gl.bindFramebuffer(gl.FRAMEBUFFER, null);
          gl.viewport(0, 0, dv.getUint32(off, true), dv.getUint32(off + 4, true));
          gl.cullFace(gl.BACK); // restore the color-pass winding
          break;
        }
        case 19: { // DRAW_DEPTH — position-only submesh draw into the shadow map
          const vh = dv.getUint32(off, true);
          const ih = dv.getUint32(off + 4, true);
          const byteOff = dv.getUint32(off + 8, true);
          const count = dv.getUint32(off + 12, true);
          const mvpPtr = dv.getUint32(off + 16, true);
          if (!st.buffers[vh] || !st.buffers[ih] || !st.active) break;
          bindVaoFor(st, vh, ih);
          gl.uniformMatrix4fv(st.active.mvp, false, new Float32Array(memory.buffer, mvpPtr, 16));
          gl.drawElements(gl.TRIANGLES, count, gl.UNSIGNED_SHORT, byteOff);
          break;
        }
        case 20: { // BIND_SHADOW_MAP — atlas depth tex + shadow_vp[] array on active program
          // NEW payload {slot, atlas_handle, vp_ptr, count} (16B): bind the 2D atlas
          // to texture unit `slot`, upload `count` consecutive mat4 to u_shadow_vp[0..count].
          const slot = dv.getUint32(off, true);
          const sm = st.shadowMaps[dv.getUint32(off + 4, true)];
          const vpPtr = dv.getUint32(off + 8, true);
          const count = dv.getUint32(off + 12, true);
          if (sm) {
            gl.activeTexture(gl.TEXTURE0 + slot);
            gl.bindTexture(gl.TEXTURE_2D, sm.tex);
          }
          if (st.active && st.active.shadowVp && count > 0)
            gl.uniformMatrix4fv(st.active.shadowVp, false, new Float32Array(memory.buffer, vpPtr, count * 16));
          // CSM frame-globals: the active program here is the receiver. Set them when a
          // CSM frame is active (set_csm, tag 36) and the program has the locations.
          if (st.active && st.frameCascadeCount > 0) {
            if (st.active.cascadeCount) gl.uniform1i(st.active.cascadeCount, st.frameCascadeCount);
            if (st.active.cascadeSplits) gl.uniform4fv(st.active.cascadeSplits, st.frameCascadeSplits);
            if (st.active.viewForward) gl.uniform3fv(st.active.viewForward, st.frameViewForward);
          }
          break;
        }
        case 21: { // SET_BONES — upload the bone palette to u_bones[] (skinned program)
          const count = dv.getUint32(off, true);
          const p = dv.getUint32(off + 4, true);
          if (st.active && st.active.bones)
            gl.uniformMatrix4fv(st.active.bones, false, new Float32Array(memory.buffer, p, count * 16));
          break;
        }
        case 22: { // CREATE_RENDER_TARGET {handle,width,height,format,flags}
          const handle = dv.getUint32(off, true);
          const w = dv.getUint32(off + 4, true);
          const h = dv.getUint32(off + 8, true);
          const fmt = dv.getUint32(off + 12, true);   // 0=rgba8, 1=rgba16f
          const flags = dv.getUint32(off + 16, true); // bit0 = with_depth
          const fbo = gl.createFramebuffer();
          gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
          const colorTex = gl.createTexture();
          gl.bindTexture(gl.TEXTURE_2D, colorTex);
          let internal, type;
          if (fmt === 1) {
            // rgba16f: requires EXT_color_buffer_float in WebGL2
            if (!st.extColorBufferFloat) {
              st.extColorBufferFloat = gl.getExtension("EXT_color_buffer_float");
              if (!st.extColorBufferFloat)
                console.warn("verve.gl: EXT_color_buffer_float unavailable — render target falling back to RGBA8");
            }
            if (st.extColorBufferFloat) {
              internal = gl.RGBA16F;
              type = gl.HALF_FLOAT;
            } else {
              internal = gl.RGBA8;
              type = gl.UNSIGNED_BYTE;
            }
          } else {
            internal = gl.RGBA8;
            type = gl.UNSIGNED_BYTE;
          }
          gl.texImage2D(gl.TEXTURE_2D, 0, internal, w, h, 0, gl.RGBA, type, null);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
          gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, colorTex, 0);
          let depthTex = null;
          if (flags & 1) {
            depthTex = gl.createTexture();
            gl.bindTexture(gl.TEXTURE_2D, depthTex);
            gl.texImage2D(gl.TEXTURE_2D, 0, gl.DEPTH_COMPONENT24, w, h, 0, gl.DEPTH_COMPONENT, gl.UNSIGNED_INT, null);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
            gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.TEXTURE_2D, depthTex, 0);
          }
          gl.drawBuffers([gl.COLOR_ATTACHMENT0]);
          gl.bindFramebuffer(gl.FRAMEBUFFER, null);
          st.renderTargets[handle] = { fbo, colorTex, depthTex, w, h };
          break;
        }
        case 23: { // BEGIN_OFFSCREEN_PASS {target, clear_rgba(4×f32), clear_flags}
          const target = dv.getUint32(off, true);
          const r = dv.getFloat32(off + 4, true);
          const g = dv.getFloat32(off + 8, true);
          const b = dv.getFloat32(off + 12, true);
          const a = dv.getFloat32(off + 16, true);
          const cf = dv.getUint32(off + 20, true);
          const rt = st.renderTargets[target];
          if (!rt) break;
          gl.bindFramebuffer(gl.FRAMEBUFFER, rt.fbo);
          gl.viewport(0, 0, rt.w, rt.h);
          // Re-enable depth test for 3D scene passes rendered into a target
          if (rt.depthTex) gl.enable(gl.DEPTH_TEST);
          gl.clearColor(r, g, b, a);
          // Restore depth mask so DEPTH_BUFFER_BIT clear actually writes.
          gl.depthMask(true);
          let mask = 0;
          if (cf & 1) mask |= gl.COLOR_BUFFER_BIT;
          if (cf & 2) mask |= gl.DEPTH_BUFFER_BIT;
          if (mask) gl.clear(mask);
          st.active = null; // force re-bind of pipeline for draws in this pass
          break;
        }
        case 24: { // END_OFFSCREEN_PASS {} — rebind canvas framebuffer
          gl.bindFramebuffer(gl.FRAMEBUFFER, null);
          break;
        }
        case 25: { // DRAW_FULLSCREEN_QUAD {shader, tex0, tex1, params_ptr, param_count}
          const shHandle = dv.getUint32(off, true);
          const t0 = dv.getUint32(off + 4, true);
          const t1 = dv.getUint32(off + 8, true);
          const pPtr = dv.getUint32(off + 12, true);
          const pCount = dv.getUint32(off + 16, true);
          const sh = st.shaders[shHandle];
          if (!sh) break;
          gl.useProgram(sh.prog);
          gl.disable(gl.DEPTH_TEST);
          gl.activeTexture(gl.TEXTURE0);
          gl.bindTexture(gl.TEXTURE_2D, st.renderTargets[t0] ? st.renderTargets[t0].colorTex : null);
          if (sh.tex0) gl.uniform1i(sh.tex0, 0);
          if (t1 !== 0 && st.renderTargets[t1]) {
            gl.activeTexture(gl.TEXTURE1);
            gl.bindTexture(gl.TEXTURE_2D, st.renderTargets[t1].colorTex);
            if (sh.tex1) gl.uniform1i(sh.tex1, 1);
          }
          applyPostParams(gl, sh, dv, pPtr, pCount);
          if (!st.emptyVao) st.emptyVao = gl.createVertexArray();
          gl.bindVertexArray(st.emptyVao);
          gl.drawArrays(gl.TRIANGLES, 0, 3);
          break;
        }
        case 26: { // DRAW_DEPTH_AT — alpha-tested depth draw (MASK cutout shadows)
          // Payload (command.zig Encoder.drawDepthAt, 28B / 7 u32):
          //   shader | vbuf | ibuf | idx_byte_off | count | mvp_ptr | material_ptr.
          // The depth-at program (created as shader handle 10 by the chunk) samples
          // u_base_tex (unit 0 — bound by the preceding bind_texture(0,…)) and
          // discards holes via u_material before writing depth. Self-contained
          // attribute layout: pos=loc 0 @0, uv=loc 1 @40 over the stride-48 buffer.
          const shHandle = dv.getUint32(off, true);
          const vh = dv.getUint32(off + 4, true);
          const ih = dv.getUint32(off + 8, true);
          const byteOff = dv.getUint32(off + 12, true);
          const count = dv.getUint32(off + 16, true);
          const mvpPtr = dv.getUint32(off + 20, true);
          const materialPtr = dv.getUint32(off + 24, true);
          const sh = st.shaders[shHandle];
          const vb = st.buffers[vh];
          const ib = st.buffers[ih];
          if (!sh || !vb || !ib) break;
          gl.useProgram(sh.prog);
          st.active = sh;
          // Cache the depth-at uniform locations on first use (createShader only
          // pre-resolves u_mvp for this variant; material + sampler are queried here).
          if (sh.material === undefined) {
            sh.material = gl.getUniformLocation(sh.prog, "u_material");
            sh.baseTex = gl.getUniformLocation(sh.prog, "u_base_tex");
          }
          if (sh.baseTex) gl.uniform1i(sh.baseTex, 0); // sample bind_texture(0,…) at unit 0
          gl.uniformMatrix4fv(sh.mvp, false, new Float32Array(memory.buffer, mvpPtr, 16));
          if (sh.material)
            gl.uniform4fv(sh.material, new Float32Array(memory.buffer, materialPtr, 12));
          // Dedicated VAO: pos (loc 0 @0) + uv (loc 1 @40) over stride 48. Keyed
          // distinctly ("dat") so it never collides with the PBR/depth VAOs.
          const datKey = `${vh}:${ih}:dat`;
          let datVao = st.vaos.get(datKey);
          if (!datVao) {
            datVao = gl.createVertexArray();
            gl.bindVertexArray(datVao);
            gl.bindBuffer(gl.ARRAY_BUFFER, vb.buf);
            gl.enableVertexAttribArray(0);
            gl.vertexAttribPointer(0, 3, gl.FLOAT, false, 48, 0);
            gl.enableVertexAttribArray(1);
            gl.vertexAttribPointer(1, 2, gl.FLOAT, false, 48, 40);
            gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, ib.buf);
            st.vaos.set(datKey, datVao);
          }
          gl.bindVertexArray(datVao);
          gl.drawElements(gl.TRIANGLES, count, gl.UNSIGNED_SHORT, byteOff);
          break;
        }
        case 28: { // SET_FOG — set fog uniforms on the active program (per-program; follows SET_PIPELINE)
          const ptr = dv.getUint32(off, true);
          const f = new Float32Array(memory.buffer, ptr, 8);
          if (st.active && st.active.fog0) gl.uniform4f(st.active.fog0, f[0], f[1], f[2], f[3]);
          if (st.active && st.active.fog1) gl.uniform4f(st.active.fog1, f[4], f[5], f[6], 0);
          break;
        }
        case 29: { // SET_MORPH_WEIGHTS — upload idx/wt/count uniforms + bind morph texture (unit 9)
          // Payload (command.zig Encoder.setMorphWeights, 12B): count | idx_ptr | wt_ptr.
          // idx_ptr → count u32 indices; wt_ptr → count f32 weights.  Pad both to 8
          // entries before uploading (the GLSL arrays are fixed-size 8).
          const count   = dv.getUint32(off, true);
          const idxPtr  = dv.getUint32(off + 4, true);
          const wtPtr   = dv.getUint32(off + 8, true);
          const sh = st.active;
          if (!sh) break;
          if (sh.morphIdx) {
            const idx = new Int32Array(8);
            const src = new Uint32Array(memory.buffer, idxPtr, count);
            for (let i = 0; i < count; i++) idx[i] = src[i];
            gl.uniform1iv(sh.morphIdx, idx);
          }
          if (sh.morphWt) {
            const wt = new Float32Array(8);
            const src = new Float32Array(memory.buffer, wtPtr, count);
            for (let i = 0; i < count; i++) wt[i] = src[i];
            gl.uniform1fv(sh.morphWt, wt);
          }
          if (sh.morphCount) gl.uniform1i(sh.morphCount, count);
          // Bind the morph texture for this scene handle (stored by the active
          // shader's morphHandle, set in CREATE_MORPH_TEX via st.morphTex).
          if (st.morphTex) {
            gl.activeTexture(gl.TEXTURE9);
            gl.bindTexture(gl.TEXTURE_2D, st.morphTex);
          }
          break;
        }
        case 30: { // CREATE_MORPH_TEX — build float morph-target texture (RGBA16F).
          // Payload (command.zig Encoder.createMorphTex, 20B):
          //   handle | width (=vertex_count) | height (=target_count*2) | ptr | byte_len.
          // Source blob (M2 layout, f16): target-major then vertex-major.
          // Per (t, v): 3 f16 POSITION then 3 f16 NORMAL (6 u16 per record).
          // Texture row layout: row 2t = POSITION deltas, row 2t+1 = NORMAL deltas.
          // Repack: texel(v, 2t)   = blob[(t*vertCount + v)*6 + 0..2] (+ 0 alpha)
          //         texel(v, 2t+1) = blob[(t*vertCount + v)*6 + 3..5] (+ 0 alpha)
          const handle   = dv.getUint32(off, true);
          const vertCount = dv.getUint32(off + 4, true);  // width
          const height    = dv.getUint32(off + 8, true);  // target_count * 2
          const blobPtr   = dv.getUint32(off + 12, true);
          // byte_len at off+16 — informational; we derive sizes from w/h.
          const targCount = height >>> 1; // height = target_count * 2
          // Source: u16 halves (f16). 6 u16 per (t,v) record.
          const blob = new Uint16Array(memory.buffer, blobPtr, targCount * vertCount * 6);
          // Destination: RGBA16F → 4 u16 per texel. Width=vertCount, Height=height.
          const pixels = new Uint16Array(vertCount * height * 4);
          for (let t = 0; t < targCount; t++) {
            for (let v = 0; v < vertCount; v++) {
              const srcBase = (t * vertCount + v) * 6;
              // POSITION row (row = 2*t)
              const posRow = t * 2;
              const posDst = (posRow * vertCount + v) * 4;
              pixels[posDst + 0] = blob[srcBase + 0];
              pixels[posDst + 1] = blob[srcBase + 1];
              pixels[posDst + 2] = blob[srcBase + 2];
              pixels[posDst + 3] = 0; // alpha pad
              // NORMAL row (row = 2*t+1)
              const nrmRow = t * 2 + 1;
              const nrmDst = (nrmRow * vertCount + v) * 4;
              pixels[nrmDst + 0] = blob[srcBase + 3];
              pixels[nrmDst + 1] = blob[srcBase + 4];
              pixels[nrmDst + 2] = blob[srcBase + 5];
              pixels[nrmDst + 3] = 0; // alpha pad
            }
          }
          const tex = gl.createTexture();
          gl.bindTexture(gl.TEXTURE_2D, tex);
          gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA16F, vertCount, height, 0,
            gl.RGBA, gl.HALF_FLOAT, pixels);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
          gl.bindTexture(gl.TEXTURE_2D, null);
          // Store by handle so SET_MORPH_WEIGHTS can bind it at unit 9.
          st.morphTextures[handle] = tex;
          st.morphTex = tex; // active morph texture (most recently created)
          break;
        }

        // ── Point-light shadow atlas (T2) ──────────────────────────────────
        case 31: { // CREATE_POINT_SHADOW — RGBA8 atlas + DEPTH_COMPONENT16 renderbuffer.
          // Payload (12B): handle | w | h.
          // Atlas: RGBA8 colour texture (w×h) — the 6 cube-face tiles are rendered
          // into sub-regions via scissor/viewport. A shared DEPTH_COMPONENT16
          // renderbuffer provides per-face depth testing.
          const handle = dv.getUint32(off, true);
          const w = dv.getUint32(off + 4, true);
          const h = dv.getUint32(off + 8, true);
          // Lazily compile the point-depth program (once per GL context).
          if (!st.pointDepthProg) {
            const pdVs = [
              "#version 300 es",
              "layout(location=0) in vec3 a_pos;",
              "uniform mat4 u_face_vp;",
              "uniform mat4 u_model;",
              "out vec3 v_world;",
              "void main(){",
              "  vec4 w=u_model*vec4(a_pos,1.0);",
              "  v_world=w.xyz;",
              "  gl_Position=u_face_vp*w;",
              "}",
            ].join("\n");
            const pdFs = [
              "#version 300 es",
              "precision highp float;",
              "in vec3 v_world;",
              "uniform vec3 u_light_pos;",
              "uniform float u_far;",
              "out vec4 frag_color;",
              "vec4 packDist(float v){vec4 e=fract(v*vec4(1.0,255.0,65025.0,16581375.0));e-=e.yzww*vec4(1.0/255.0,1.0/255.0,1.0/255.0,0.0);return e;}",
              "void main(){",
              "  frag_color=packDist(clamp(length(v_world-u_light_pos)/u_far,0.0,1.0));",
              "}",
            ].join("\n");
            const prog = glCompile(gl, pdVs, pdFs);
            st.pointDepthProg = {
              prog,
              faceVp:   gl.getUniformLocation(prog, "u_face_vp"),
              model:    gl.getUniformLocation(prog, "u_model"),
              lightPos: gl.getUniformLocation(prog, "u_light_pos"),
              far:      gl.getUniformLocation(prog, "u_far"),
            };
          }
          // RGBA8 colour atlas.
          const tex = gl.createTexture();
          gl.bindTexture(gl.TEXTURE_2D, tex);
          gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
          gl.bindTexture(gl.TEXTURE_2D, null);
          // Shared depth renderbuffer (same w×h as the atlas).
          const depth = gl.createRenderbuffer();
          gl.bindRenderbuffer(gl.RENDERBUFFER, depth);
          gl.renderbufferStorage(gl.RENDERBUFFER, gl.DEPTH_COMPONENT16, w, h);
          gl.bindRenderbuffer(gl.RENDERBUFFER, null);
          // FBO: colour0 = atlas, depth = renderbuffer.
          const fbo = gl.createFramebuffer();
          gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
          gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex, 0);
          gl.framebufferRenderbuffer(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.RENDERBUFFER, depth);
          gl.bindFramebuffer(gl.FRAMEBUFFER, null);
          st.pointShadows[handle] = { fbo, tex, depth, w, h };
          break;
        }
        case 32: { // BEGIN_POINT_SHADOW_FACE — bind FBO, set per-face viewport+scissor+uniforms.
          // Payload (28B): handle | col | row | tile | face_vp_ptr | light_pos_ptr | far_bits.
          const ps = st.pointShadows[dv.getUint32(off, true)];
          const col  = dv.getUint32(off + 4, true);
          const row  = dv.getUint32(off + 8, true);
          const tile = dv.getUint32(off + 12, true);
          const faceVpPtr   = dv.getUint32(off + 16, true);
          const lightPosPtr = dv.getUint32(off + 20, true);
          const far = dv.getFloat32(off + 24, true); // far_bits reinterpreted as f32
          if (!ps || !st.pointDepthProg) break;
          gl.bindFramebuffer(gl.FRAMEBUFFER, ps.fbo);
          gl.viewport(col * tile, row * tile, tile, tile);
          gl.enable(gl.SCISSOR_TEST);
          gl.scissor(col * tile, row * tile, tile, tile);
          // Clear colour to (1,1,1,1) = maximum encoded distance (= far).
          gl.clearColor(1, 1, 1, 1);
          gl.depthMask(true);
          gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
          gl.useProgram(st.pointDepthProg.prog);
          st.active = st.pointDepthProg;
          gl.enable(gl.DEPTH_TEST);
          gl.enable(gl.CULL_FACE);
          gl.cullFace(gl.BACK); // normal back-face cull for point-light depth
          // Per-face uniforms: face VP matrix (16 f32), light position (3 f32), far (1 f32).
          gl.uniformMatrix4fv(st.pointDepthProg.faceVp, false,
            new Float32Array(memory.buffer, faceVpPtr, 16));
          gl.uniform3fv(st.pointDepthProg.lightPos,
            new Float32Array(memory.buffer, lightPosPtr, 3));
          gl.uniform1f(st.pointDepthProg.far, far);
          break;
        }
        case 33: { // DRAW_POINT_DEPTH — draw one mesh into the active face tile.
          // Payload (20B): vbuf | ibuf | index_byte_off | index_count | model_ptr.
          const vh = dv.getUint32(off, true);
          const ih = dv.getUint32(off + 4, true);
          const byteOff = dv.getUint32(off + 8, true);
          const count = dv.getUint32(off + 12, true);
          const modelPtr = dv.getUint32(off + 16, true);
          if (!st.buffers[vh] || !st.buffers[ih] || !st.active) break;
          bindVaoFor(st, vh, ih);
          gl.uniformMatrix4fv(st.active.model, false,
            new Float32Array(memory.buffer, modelPtr, 16));
          gl.drawElements(gl.TRIANGLES, count, gl.UNSIGNED_SHORT, byteOff);
          break;
        }
        case 34: { // END_POINT_SHADOW — unbind FBO, disable scissor, restore canvas viewport.
          // Payload (8B): width | height (canvas dimensions to restore).
          gl.bindFramebuffer(gl.FRAMEBUFFER, null);
          gl.disable(gl.SCISSOR_TEST);
          gl.viewport(0, 0, dv.getUint32(off, true), dv.getUint32(off + 4, true));
          gl.cullFace(gl.BACK);
          st.active = null; // match end_shadow_pass pattern; prevent stale program writes
          break;
        }
        case 35: { // BIND_POINT_SHADOW — bind atlas colour tex to slot; store for receiver.
          // NEW payload (8B): slot | handle. Multi-caster: u_point_light_pos/u_point_far
          // removed (Task 1) — the receiver reads each caster's lpos/far from the
          // per-light loop vars, so the bridge only binds the atlas to the texture unit.
          const slot = dv.getUint32(off, true);
          const ps = st.pointShadows[dv.getUint32(off + 4, true)];
          if (ps) {
            gl.activeTexture(gl.TEXTURE0 + slot);
            gl.bindTexture(gl.TEXTURE_2D, ps.tex);
          }
          if (st.active && st.active.pointAtlas != null)
            gl.uniform1i(st.active.pointAtlas, slot);
          break;
        }

        default:
          break; // unknown tag: size-skip = forward compatible
      }
      off += size;
    }
    return total;
  };

  // Full GPU teardown for an island unmount: deletes every live buffer,
  // texture (incl. tag-10 cubemaps), program, and cached VAO, then resets the
  // tables so the state object is inert. Null-guarded throughout — slots may
  // already be null from prior DELETE_RESOURCE commands.
  const disposeGlState = (st) => {
    const gl = st.gl;
    if (!gl) return;
    for (const entry of st.buffers) if (entry) gl.deleteBuffer(entry.buf);
    for (const entry of st.textures) if (entry) gl.deleteTexture(entry.tex);
    for (const sh of st.shaders) if (sh) gl.deleteProgram(sh.prog);
    for (const vao of st.vaos.values()) gl.deleteVertexArray(vao);
    for (const rt of st.renderTargets) {
      if (rt) {
        gl.deleteFramebuffer(rt.fbo);
        gl.deleteTexture(rt.colorTex);
        if (rt.depthTex) gl.deleteTexture(rt.depthTex);
      }
    }
    if (st.emptyVao) { gl.deleteVertexArray(st.emptyVao); st.emptyVao = null; }
    if (st.instanceBuf) { gl.deleteBuffer(st.instanceBuf); st.instanceBuf = null; }
    for (const tex of st.morphTextures) if (tex) gl.deleteTexture(tex);
    for (const ps of st.pointShadows) {
      if (ps) {
        gl.deleteFramebuffer(ps.fbo);
        gl.deleteTexture(ps.tex);
        gl.deleteRenderbuffer(ps.depth);
      }
    }
    if (st.pointDepthProg) { gl.deleteProgram(st.pointDepthProg.prog); st.pointDepthProg = null; }
    st.morphTextures = [];
    st.morphTex = null;
    st.buffers = [];
    st.textures = [];
    st.shaders = [];
    st.renderTargets = [];
    st.pointShadows = [];
    st.vaos.clear();
    st.active = null;
  };

  // Build the device-default placeholder textures + sampler that fill any
  // unbound PBR material slot (0–7), so the draw_pbr bind group (T3) is always
  // complete. WebGPU has no global texture state: every sampled binding in the
  // WGSL must resolve to a valid view. Created ONCE per device.
  //
  // Default-slot color mapping (T3 consults this when a slot has no bound tex):
  //   0 base-color           → white (neutral multiply → material base factor)
  //   1 metallic-roughness   → white (factors carry metallic/roughness)
  //   2 normal               → white (no per-pixel normal; geometric normal used)
  //   3 emissive             → black (no emission)
  //   4 occlusion            → white (neutral multiply → full ambient)
  //   5 irradiance (cube)    → black (zero diffuse IBL; real cubes in slice 2b)
  //   6 prefiltered (cube)   → black (zero specular IBL)
  //   7 brdf_lut             → black (zero IBL contribution)
  // i.e. slots 0/1/2/4 → white2d, 3 → black2d, 5/6 → blackCube, 7 → black2d.
  const gpuMakeDefaults = (device) => {
    const make2d = (rgba) => {
      const tex = device.createTexture({
        size: [1, 1],
        format: "rgba8unorm",
        usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST |
          GPUTextureUsage.RENDER_ATTACHMENT,
      });
      device.queue.writeTexture(
        { texture: tex },
        new Uint8Array(rgba),
        { bytesPerRow: 4, rowsPerImage: 1 },
        [1, 1],
      );
      return { tex, view: tex.createView(), w: 1, h: 1 };
    };
    // 1×1×6 black cube. Each face is one RGBA texel; upload per-layer.
    const cubeTex = device.createTexture({
      size: [1, 1, 6],
      format: "rgba8unorm",
      usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST |
        GPUTextureUsage.RENDER_ATTACHMENT,
    });
    for (let face = 0; face < 6; face++) {
      device.queue.writeTexture(
        { texture: cubeTex, origin: [0, 0, face] },
        new Uint8Array([0, 0, 0, 255]),
        { bytesPerRow: 4, rowsPerImage: 1 },
        [1, 1, 1],
      );
    }
    return {
      white2d: make2d([255, 255, 255, 255]),
      black2d: make2d([0, 0, 0, 255]),
      blackCube: {
        tex: cubeTex,
        view: cubeTex.createView({ dimension: "cube" }),
        w: 1,
        h: 1,
      },
      sampler: device.createSampler({
        magFilter: "linear",
        minFilter: "linear",
        addressModeU: "repeat",
        addressModeV: "repeat",
      }),
      // Fallback shadow resources (variant_shadow bind group is always complete
      // even before bind_shadow_map): a 1×1 depth texture (content irrelevant —
      // unbound shadow leaves geometry lit) + a comparison sampler.
      shadowTex: (() => {
        const t = device.createTexture({
          size: [1, 1],
          format: "depth32float",
          usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.RENDER_ATTACHMENT,
        });
        return { tex: t, view: t.createView() };
      })(),
      shadowSampler: device.createSampler({ compare: "less" }),
      // S3 LTC fallback: the WGSL PBR shader ALWAYS declares the LTC samplers
      // (group(1) bindings 12/13), so every PBR bind group MUST bind them even
      // when no LTC LUT is loaded / area_count=0. A 1×1 rgba16f dummy keeps the
      // bind-group layout valid (content irrelevant — shader never samples it
      // when area_count=0). Mirrors the white2d/blackCube fallback pattern.
      ltcDummy: (() => {
        const t = device.createTexture({
          size: [1, 1],
          format: "rgba16float",
          usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST,
        });
        // 4 halfs = 0.0 (bit pattern 0x0000). bytesPerRow = 8 (1 texel × 8B).
        device.queue.writeTexture(
          { texture: t },
          new Uint16Array([0, 0, 0, 0]),
          { bytesPerRow: 8, rowsPerImage: 1 },
          [1, 1],
        );
        return { tex: t, view: t.createView(), w: 1, h: 1 };
      })(),
    };
  };

  // ── PBR uniform-buffer byte-offset map (derived from wgslPbr's `U` struct) ──
  // WGSL uniform address space: every member 16B-aligned; mat3x3 = 3 vec4 cols;
  // vec3 padded to 16. Confirmed against command.zig's `U` decl + its layout
  // comment (lines ~467-476). All offsets in BYTES.
  //   mvp        : mat4x4  @   0  (16 f32)
  //   model      : mat4x4  @  64  (16 f32)
  //   normal_mat : mat3x3  @ 128  (3 cols × vec4 = 12 f32, col i at 128+16i)
  //   camera_pos : vec3    @ 176  (3 f32 + 4B pad)
  //   material   : vec4[3] @ 192  (12 f32)
  //   lights     : vec4[16] @ 240  (64 f32 packed = count*16 from wasm; 4 vec4/light:
  //                                  v0=[type,intensity,pos.x,pos.y],
  //                                  v1=[pos.z,dir.x,dir.y,dir.z],
  //                                  v2=[color.r,color.g,color.b,range],
  //                                  v3=[cosIn,cosOut,__,__])
  //   light_count: i32     @ 496
  //   prefiltered_mips:f32 @ 500
  //   area_count : i32     @ 504  (S3 area lights — ALWAYS present)
  //   area_lights: vec4[16]@ 512  (512..768; 4 vec4/area light)
  //   shadow_vp  : mat4x4[8]@ 768 (variant_shadow; non-shadow ignores; instanced
  //                                writes its single vp here)
  //   cascade_count: i32   @1280  cascade_splits: vec4 @1296  view_forward: vec3 @1312
  // base struct = 768; shadow struct = 1328 → PBR_STRIDE = align(1328,256) = 1536.
  const PBR_U = {
    mvp: 0,
    model: 64,
    normalMat: 128, // 3 vec4 columns at 128,144,160
    cameraPos: 176,
    material: 192,
    lights: 240,
    lightCount: 496,
    prefMips: 500,
    // S3 area lights (LTC): area_count i32 @504; area_lights array<vec4,16> @512
    // (512..768, ALWAYS present). a0=[pos,intensity] a1=[ex,two_sided]
    // a2=[ey,shadow_slot] a3=[color,shadow_kind]. Base (non-shadow) struct = 768.
    areaCount: 504,  // i32  @504 (504..508, 4-aligned after prefMips@500)
    areaLights: 512, // array<vec4,16> @512 (512..768, 256B)
    // CSM/Multi-caster: shadow_vp is array<mat4x4<f32>,8> @ 768 (8×64 = 512B, 768..1280),
    // shifted from 512 by the area_lights block. (Instanced variant reuses 768 for its
    // single `vp` mat — same slot, where shadow_vp would be.)
    shadowVp: 768, // shadow_vp[8] (set by bind_shadow_map; instanced path writes 1 mat here)
    // CSM frame-globals (shadow variant only), set by set_csm (tag 36):
    cascadeCount: 1280,  // i32  @1280 (1280..1284)
    cascadeSplits: 1296, // vec4 @1296 (16-aligned, 1296..1312) view-space FAR per cascade
    viewForward: 1312,   // vec3 @1312 (1312..1324, +4B pad → 1328) normalized camera look dir
    // area @504/512..768; shadowVp @768 (512B, 768..1280); cascade fields 1280..1328;
    // size 1328, stride 1536
    size: 1328,
  };
  // Multiple draws per frame each need isolated uniforms: WebGPU defers draws, so
  // a single shared buffer would let the last writeBuffer clobber earlier draws.
  // Solution: dynamic uniform offsets — each draw writes its full struct to its
  // own 256-aligned slot and binds with that offset. Per-frame values (lights/
  // ibl/light_vp) are cached and replicated into every slot.
  const PBR_STRIDE = 1536; // align(1328, 256)
  const DEPTH_STRIDE = 256; // one mat4 (64B) padded to the 256B dynamic-offset min
  const MAX_DRAWS = 64; // per-frame draw cap (cube+plane today; headroom for scenes)
  // Post fullscreen draws (bright/blurH/blurV/composite/fxaa = up to 5/frame) each
  // need their own params slot — same hazard as PBR: all draws defer to one submit,
  // so a single shared buffer lets the last writeBuffer clobber every earlier draw.
  const POST_STRIDE = 256; // 32B params padded to the 256B uniform-offset min
  const MAX_POST_DRAWS = 16; // per-frame fullscreen-draw cap (5 today; headroom)
  // Lazily create the shared PBR uniform buffer (reused across frames/draws).
  const gpuEnsurePbrUniform = (st) => {
    if (!st.pbrUniform) {
      st.pbrUniform = st.device.createBuffer({
        size: PBR_STRIDE * MAX_DRAWS, // one PBR_U.size slot per draw
        usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
      });
    }
    return st.pbrUniform;
  };
  // Lazily create the shared post-effect params buffer (one 256B slot per
  // fullscreen draw, isolated like the PBR uniform so deferred draws don't clobber).
  const gpuEnsurePostUniform = (st) => {
    if (!st.postUniform) {
      st.postUniform = st.device.createBuffer({
        size: POST_STRIDE * MAX_POST_DRAWS,
        usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
      });
    }
    return st.postUniform;
  };
  // Lazily create the shared bones palette uniform (64 mat4 = 4096 B), bound at
  // @group(0) @binding(1) for skinned variants. set_bones (tag 21) writes it;
  // skinned bg0 binds the whole buffer (static, no dynamic offset).
  const gpuEnsureBones = (st) => {
    if (!st.bonesBuf) {
      st.bonesBuf = st.device.createBuffer({
        size: 64 * 64, // 64 mat4x4<f32> = 64 * 64 B
        usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
      });
    }
    return st.bonesBuf;
  };
  // Lazily create the depth-pass uniform (a mat4 per draw) + its bind group
  // against the depth pipeline's dynamic-offset layout. Reused across frames.
  const gpuEnsureDepthUniform = (st, depthPipe) => {
    if (!st.depthUniform) {
      st.depthUniform = st.device.createBuffer({
        size: DEPTH_STRIDE * MAX_DRAWS,
        usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
      });
    }
    if (!st.depthBindGroup && depthPipe) {
      st.depthBindGroup = st.device.createBindGroup({
        layout: depthPipe.bgl0,
        // size = one mat4; the dynamic offset selects the per-draw slot.
        entries: [{ binding: 0, resource: { buffer: st.depthUniform, offset: 0, size: 64 } }],
      });
    }
    return st.depthUniform;
  };
  // Lazily create the depth-at uniform (per draw: mvp 64B + material 48B = 112B,
  // padded to the DEPTH_STRIDE 256B dynamic-offset slot). The bind group is built
  // per draw_depth_at (binding 1 = base texture view varies), so only the buffer
  // is cached here. Reused across frames; dropped on device loss.
  const gpuEnsureDepthAtUniform = (st) => {
    if (!st.depthAtUniform) {
      st.depthAtUniform = st.device.createBuffer({
        size: DEPTH_STRIDE * MAX_DRAWS,
        usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
      });
    }
    return st.depthAtUniform;
  };
  // Resolve a material slot (0=base,1=mr,2=normal,3=emissive,4=occlusion — the
  // bind_texture wire numbering) to a texture view, falling back to a device
  // default per gpuMakeDefaults' documented mapping. IBL slots (irradiance/
  // prefiltered/brdf_lut) are not driven by bind_texture in slice 2a, so they
  // always resolve to defaults (real cubes arrive in slice 2b via bind_ibl).
  const gpuSlotView = (st, slot, fallback) => {
    const h = st.boundTex[slot];
    const t = (h != null) ? st.textures[h] : null;
    return (t && t.view) ? t.view : fallback.view;
  };
  // Resolve an IBL texture handle (set by bind_ibl) to its view, falling back to
  // a device default (black) when no environment is bound — so the bind group is
  // always complete and unbound IBL contributes zero.
  const gpuIblView = (st, handle, fallback) => {
    const t = (handle != null) ? st.textures[handle] : null;
    return (t && t.view) ? t.view : fallback.view;
  };

  // S3 LTC LUTs (WebGPU): lazily fetch /gl/ltc.bin (65536B) ONCE, split into two
  // 64×64 rgba16f textures (bytes 0..32767 → ltc_mat, 32768..65535 → ltc_mag; the
  // bytes are already little-endian f16 — upload directly). CLAMP_TO_EDGE; the
  // shared filtering sampler covers mag=LINEAR. Cached on st.ltcMat/st.ltcMag.
  // The fetch is guarded by st.ltcLoading so it fires exactly once. On completion
  // mark bg1Dirty so the next draw rebuilds group(1) with the real views.
  const gpuEnsureLtc = (st) => {
    if (st.ltcMat || st.ltcLoading) return; // loaded or in-flight
    st.ltcLoading = true;
    fetch("/gl/ltc.bin")
      .then((r) => r.arrayBuffer())
      .then((buf) => {
        const device = st.device;
        if (!device) return;
        const make = (byteOffset) => {
          const tex = device.createTexture({
            size: [64, 64],
            format: "rgba16float",
            usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST,
          });
          // 64 texels/row × 8 bytes (4 halfs) = 512 bytes/row; 64 rows = 32768B.
          device.queue.writeTexture(
            { texture: tex },
            new Uint8Array(buf, byteOffset, 32768),
            { bytesPerRow: 64 * 8, rowsPerImage: 64 },
            [64, 64],
          );
          return { tex, view: tex.createView(), w: 64, h: 64 };
        };
        st.ltcMat = make(0);      // bytes 0..32767
        st.ltcMag = make(32768);  // bytes 32768..65535
        st.bg1Dirty = true;       // rebind group(1) with the real LUT views
      })
      .catch(() => { st.ltcLoading = false; }); // allow a later retry on failure
  };

  // Lazily build (and cache) a post render pipeline for a given (format, hasDepth)
  // combination. Post pipelines must match the pass's color attachment format AND
  // its depth-stencil state. The final canvas pass (BEGIN_FRAME) has depth24plus;
  // offscreen passes (BEGIN_OFFSCREEN_PASS without depth) do not. Key: "format:0/1".
  const getOrCreatePostPipeline = (st, entry, format, hasDepth) => {
    const key = format + (hasDepth ? ":d" : "");
    let pipe = entry.byFormat[key];
    if (!pipe) {
      const desc = {
        layout: st.device.createPipelineLayout({ bindGroupLayouts: [entry.bgl0, entry.bgl1] }),
        vertex: { module: entry.module, entryPoint: "vs_main" }, // no vertex buffers
        fragment: { module: entry.module, entryPoint: "fs_main", targets: [{ format }] },
        primitive: { topology: "triangle-list" },
      };
      // Canvas pass has depth24plus; fullscreen-quad never writes depth.
      if (hasDepth) {
        desc.depthStencil = { format: "depth24plus", depthWriteEnabled: false, depthCompare: "always" };
      }
      pipe = st.device.createRenderPipeline(desc);
      entry.byFormat[key] = pipe;
    }
    return pipe;
  };

  // WebGPU command-stream interpreter. Consumes the SAME binary stream as
  // glInterpret (4-byte tag/size header per command, little-endian) but drives
  // WebGPU. Slice 1 handles only the minimal unlit-cube subset (6 tags);
  // unknown tags size-skip for forward compatibility, exactly like glInterpret.
  // `st` carries the per-canvas WebGPU state (device/ctx/format + resource
  // tables + frame-scoped encoder/pass). Each tag null-guards its prerequisites
  // so a missing resource is a no-op rather than a crash.
  const gpuInterpret = (st, ptr) => {
    // Fresh DataView every frame: memory.buffer detaches on wasm growth.
    const dv = new DataView(memory.buffer);
    const total = dv.getUint32(ptr, true);
    let off = ptr + 4;
    const end = off + total;
    const device = st.device;
    while (off < end) {
      const tag = dv.getUint16(off, true);
      const size = dv.getUint16(off + 2, true);
      off += 4;
      switch (tag) {
        case 1: { // BEGIN_FRAME
          const r = dv.getFloat32(off, true);
          const g = dv.getFloat32(off + 4, true);
          const b = dv.getFloat32(off + 8, true);
          const a = dv.getFloat32(off + 12, true);
          const w = dv.getUint32(off + 16, true);
          const h = dv.getUint32(off + 20, true);
          if (!st.depthTex || w !== st.lastW || h !== st.lastH) {
            const oldDepth = st.depthTex;
            st.depthTex = device.createTexture({
              size: [w, h],
              format: "depth24plus",
              usage: GPUTextureUsage.RENDER_ATTACHMENT,
            });
            st.depthView = st.depthTex.createView();
            if (oldDepth) oldDepth.destroy();
            st.lastW = w;
            st.lastH = h;
          }
          st.pbrSlot = 0; // reset per-draw uniform slot allocation for this frame
          st.frameCascadeCount = 0; // default CSM off; set_csm (36) re-enables per frame
          st.frameAreaCount = 0; // default no area lights; set_area_lights (37) re-enables per frame
          st.curTargetFormat = st.format; // canvas pass: post draws target st.format
          st.curPassHasDepth = true; // canvas pass always has depth24plus
          // Reuse the encoder if a shadow/offscreen pass already opened one this
          // frame (those run BEFORE begin_frame); else create one. All passes share
          // one encoder + submit. Reset post slot only on a genuinely new encoder so
          // the canvas FXAA draw keeps a slot distinct from the offscreen bloom draws.
          if (!st.encoder) { st.encoder = device.createCommandEncoder(); st.postSlot = 0; }
          st.pass = st.encoder.beginRenderPass({
            colorAttachments: [{
              view: st.ctx.getCurrentTexture().createView(),
              clearValue: { r, g, b, a },
              loadOp: "clear",
              storeOp: "store",
            }],
            depthStencilAttachment: {
              view: st.depthView,
              depthClearValue: 1.0,
              depthLoadOp: "clear",
              depthStoreOp: "store",
            },
          });
          break;
        }
        case 2: { // CREATE_BUFFER
          const handle = dv.getUint32(off, true);
          const kind = dv.getUint32(off + 4, true);
          const p = dv.getUint32(off + 8, true);
          const len = dv.getUint32(off + 12, true);
          const usage = kind === 1
            ? (GPUBufferUsage.INDEX | GPUBufferUsage.COPY_DST)
            : (GPUBufferUsage.VERTEX | GPUBufferUsage.COPY_DST);
          const buf = device.createBuffer({ size: (len + 3) & ~3, usage });
          device.queue.writeBuffer(buf, 0, new Uint8Array(memory.buffer, p, len));
          st.buffers[handle] = { buf, kind };
          break;
        }
        case 3: { // CREATE_SHADER — one WGSL module in vs_ptr/vs_len.
          // Payload (command.zig Encoder.createShader, 24B): handle | variant |
          //   vs_ptr | vs_len | fs_ptr | fs_len. The WGSL holds BOTH stages in
          //   the vs slot (fs slot is 0/0). variant carries the variant_* bits.
          const handle = dv.getUint32(off, true);
          const variant = dv.getUint32(off + 4, true);
          const code = readStr(dv.getUint32(off + 8, true), dv.getUint32(off + 12, true));
          const module = device.createShaderModule({ code });
          if ((variant & 0x100) !== 0) { // variant_post — fullscreen-quad post pass.
            // All four post WGSL modules (bright/blur/composite/fxaa) share ONE
            // layout (group0=params uniform, group1=sampler+tex0+tex1) and the
            // vs_main/fs_main entry points; only the WGSL body differs and rides
            // the create_shader stream. The render pipeline must match the COLOR
            // format of the pass it draws into (rgba16float bloom / rgba8unorm ldr
            // / st.format canvas), so we defer pipeline creation to draw time and
            // cache per `${handle}:${format}` (getOrCreatePostPipeline below).
            const bgl0 = device.createBindGroupLayout({
              entries: [{ binding: 0, visibility: GPUShaderStage.FRAGMENT, buffer: { type: "uniform" } }],
            });
            const bgl1 = device.createBindGroupLayout({
              entries: [
                { binding: 0, visibility: GPUShaderStage.FRAGMENT, sampler: { type: "filtering" } },
                { binding: 1, visibility: GPUShaderStage.FRAGMENT, texture: { sampleType: "float", viewDimension: "2d" } },
                { binding: 2, visibility: GPUShaderStage.FRAGMENT, texture: { sampleType: "float", viewDimension: "2d" } },
              ],
            });
            st.pipelines[handle] = { module, bgl0, bgl1, kind: "post", byFormat: {} };
            break;
          }
          // variant_pbr = 1 << 2 (command.zig). variant_normal_map = 1 << 3,
          // variant_emissive = 1 << 4 — gate which group(1) texture bindings the
          // WGSL declares (wgslPbr appends tex_normal/tex_emissive conditionally;
          // tex_base + tex_ibl are unconditional).
          if ((variant & 0x40) !== 0) { // variant_depth = 1 << 6 — shadow depth pass
            if ((variant & 0x400) !== 0) { // + variant_alpha_test (1 << 10) → depth-at
              // Depth-at pipeline (wgslDepthAt): alpha-tested depth draw for MASK
              // cutout shadows. Vertex carries pos + uv; the fragment samples the
              // base texture and discards holes before writing depth. group(0):
              //   binding 0 = per-draw uniform {mvp(64B), material[3](48B)} (dynamic
              //   offset), binding 1 = base texture view, binding 2 = sampler.
              const bgl0 = device.createBindGroupLayout({
                entries: [
                  {
                    binding: 0,
                    visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT,
                    buffer: { type: "uniform", hasDynamicOffset: true },
                  },
                  { binding: 1, visibility: GPUShaderStage.FRAGMENT, texture: { sampleType: "float", viewDimension: "2d" } },
                  { binding: 2, visibility: GPUShaderStage.FRAGMENT, sampler: { type: "filtering" } },
                ],
              });
              const layout = device.createPipelineLayout({ bindGroupLayouts: [bgl0] });
              const pipeline = device.createRenderPipeline({
                layout,
                vertex: {
                  module,
                  entryPoint: "vs_main",
                  buffers: [{
                    arrayStride: 48, // stride-48 layout: pos @0, uv @40
                    attributes: [
                      { shaderLocation: 0, offset: 0, format: "float32x3" },
                      { shaderLocation: 1, offset: 40, format: "float32x2" },
                    ],
                  }],
                },
                // Matches the plain depth pipeline: front-face cull, depth32float,
                // depth-write on, 'less' compare. No color target.
                primitive: { topology: "triangle-list", cullMode: "front" },
                depthStencil: {
                  format: "depth32float",
                  depthWriteEnabled: true,
                  depthCompare: "less",
                },
              });
              st.pipelines[handle] = { pipeline, bgl0, kind: "depthAt" };
              break;
            }
            // Depth-only pipeline (wgslDepth): position-only vertex, NO color
            // target, renders into the depth32float shadow map. Front-face cull
            // pushes self-shadow acne behind geometry (mirrors the WebGL2 path).
            const bgl0 = device.createBindGroupLayout({
              entries: [{ binding: 0, visibility: GPUShaderStage.VERTEX, buffer: { type: "uniform", hasDynamicOffset: true } }],
            });
            const layout = device.createPipelineLayout({ bindGroupLayouts: [bgl0] });
            const pipeline = device.createRenderPipeline({
              layout,
              vertex: {
                module,
                entryPoint: "vs_main",
                buffers: [{
                  arrayStride: 48, // stride-48 layout; only position (attr 0) is read
                  attributes: [{ shaderLocation: 0, offset: 0, format: "float32x3" }],
                }],
              },
              primitive: { topology: "triangle-list", cullMode: "front" },
              depthStencil: {
                format: "depth32float",
                depthWriteEnabled: true,
                depthCompare: "less",
              },
            });
            st.pipelines[handle] = { pipeline, bgl0, kind: "depth" };
            break;
          }
          // variant_instanced (1<<12 = 0x1000): PBR with slot-1 per-instance buffer.
          // Must be checked BEFORE the generic isPbr block so the pipeline is built
          // with two vertex.buffers and stored as kind "pbr-instanced". FRESH
          // descriptor literals — does NOT touch pbrDesc or the non-instanced pipeline.
          if ((variant & 0x1000) !== 0) {
            // Guard: instanced + shadow (0x1020) share offset 768 in the WGSL U
            // struct (vp vs shadow_vp[0]) — unsupported in v1.  Fail loud, not garbage.
            if ((variant & 0x1020) === 0x1020) {
              console.error("gl: variant_instanced|variant_shadow (0x" + variant.toString(16) + ") unsupported — vp/shadow_vp collision at U offset 768; skipping pipeline build");
              break;
            }
            const hasNormal = (variant & 0x8) !== 0;
            const hasEmissive = (variant & 0x10) !== 0;
            const hasShadow = (variant & 0x20) !== 0;
            const doubleSided = (variant & 0x800) !== 0;
            const hasFog = (variant & 0x2000) !== 0; // variant_fog: distance fog uniform
            const instBgl0Entries = [{
              binding: 0,
              visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT,
              buffer: { type: "uniform", hasDynamicOffset: true },
            }];
            if (hasFog) {
              instBgl0Entries.push({
                binding: 2,
                visibility: GPUShaderStage.FRAGMENT,
                buffer: { type: "uniform" },
              });
            }
            const bgl0 = device.createBindGroupLayout({ entries: instBgl0Entries });
            const FRAG = GPUShaderStage.FRAGMENT;
            const tex2d = { sampleType: "float", viewDimension: "2d" };
            const texCube = { sampleType: "float", viewDimension: "cube" };
            const g1 = [
              { binding: 0, visibility: FRAG, sampler: { type: "filtering" } },
              { binding: 1, visibility: FRAG, texture: tex2d }, // base
              { binding: 2, visibility: FRAG, texture: tex2d }, // metallic-roughness
            ];
            if (hasNormal) g1.push({ binding: 3, visibility: FRAG, texture: tex2d });
            if (hasEmissive) g1.push({ binding: 4, visibility: FRAG, texture: tex2d });
            g1.push({ binding: 5, visibility: FRAG, texture: tex2d }); // occlusion
            g1.push({ binding: 6, visibility: FRAG, texture: texCube }); // irradiance
            g1.push({ binding: 7, visibility: FRAG, texture: texCube }); // prefiltered
            g1.push({ binding: 8, visibility: FRAG, texture: tex2d }); // brdf_lut
            if (hasShadow) {
              g1.push({ binding: 9, visibility: FRAG, texture: { sampleType: "depth", viewDimension: "2d" } });
              g1.push({ binding: 10, visibility: FRAG, sampler: { type: "comparison" } });
            }
            // S3 LTC LUTs — ALWAYS declared in every PBR variant (group(1) 12/13).
            g1.push({ binding: 12, visibility: FRAG, texture: { sampleType: "float", viewDimension: "2d" } }); // ltc_mat
            g1.push({ binding: 13, visibility: FRAG, texture: { sampleType: "float", viewDimension: "2d" } }); // ltc_mag
            const bgl1 = device.createBindGroupLayout({ entries: g1 });
            const layout = device.createPipelineLayout({ bindGroupLayouts: [bgl0, bgl1] });
            const pbrFragFormat = (variant & 0x200) ? "rgba16float" : st.format;
            // Two vertex.buffers: slot 0 = mesh (stride 48, non-skinned attribs 0-3),
            // slot 1 = per-instance (stride 80, stepMode "instance", attrs 4-8).
            const instDesc = {
              layout,
              vertex: {
                module,
                entryPoint: "vs_main",
                buffers: [
                  {
                    arrayStride: 48,
                    attributes: [
                      { shaderLocation: 0, offset: 0,  format: "float32x3" }, // pos
                      { shaderLocation: 1, offset: 12, format: "float32x3" }, // normal
                      { shaderLocation: 2, offset: 24, format: "float32x4" }, // tangent
                      { shaderLocation: 3, offset: 40, format: "float32x2" }, // uv
                    ],
                  },
                  {
                    arrayStride: 80,
                    stepMode: "instance",
                    attributes: [
                      { shaderLocation: 4, offset: 0,  format: "float32x4" }, // mat col 0
                      { shaderLocation: 5, offset: 16, format: "float32x4" }, // mat col 1
                      { shaderLocation: 6, offset: 32, format: "float32x4" }, // mat col 2
                      { shaderLocation: 7, offset: 48, format: "float32x4" }, // mat col 3
                      { shaderLocation: 8, offset: 64, format: "float32x4" }, // color rgba
                    ],
                  },
                ],
              },
              fragment: {
                module,
                entryPoint: "fs_main",
                targets: [{ format: pbrFragFormat }],
              },
              primitive: { topology: "triangle-list", cullMode: doubleSided ? "none" : "back" },
              depthStencil: {
                format: "depth24plus",
                depthWriteEnabled: true,
                depthCompare: "less",
              },
            };
            const pipeline = device.createRenderPipeline(instDesc);
            st.pipelines[handle] = {
              pipeline,
              bgl0,
              bgl1,
              kind: "pbr-instanced",
              flags: variant,
              hasNormal,
              hasEmissive,
              hasShadow,
              hasFog,
            };
            break;
          }
          const isPbr = (variant & 0x4) !== 0;
          if (isPbr) {
            const hasNormal = (variant & 0x8) !== 0;
            const hasEmissive = (variant & 0x10) !== 0;
            const hasShadow = (variant & 0x20) !== 0;
            const skinned = (variant & 0x80) !== 0; // variant_skinned
            const doubleSided = (variant & 0x800) !== 0; // variant_double_sided
            const hasPointShadow = (variant & 0x8000) !== 0; // variant_shadow_point: RGBA8 atlas + pt uniform
            // group(0): binding 0 is the per-draw uniform (dynamic offset),
            // visible to VERTEX|FRAGMENT (wgslPbr: @group(0) @binding(0)
            // var<uniform> u: U). Skinned variants ALSO declare a bones uniform
            // at @group(0) @binding(1) (struct Bones { m: array<mat4x4,64> }),
            // VERTEX-only, static (no dynamic offset). Non-skinned layout is
            // binding-0-only — UNCHANGED.
            const bgl0Entries = [{
              binding: 0,
              visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT,
              buffer: { type: "uniform", hasDynamicOffset: true },
            }];
            if (skinned) {
              bgl0Entries.push({
                binding: 1,
                visibility: GPUShaderStage.VERTEX,
                buffer: { type: "uniform" },
              });
            }
            const hasFog = (variant & 0x2000) !== 0; // variant_fog: distance fog uniform
            if (hasFog) {
              bgl0Entries.push({
                binding: 2,
                visibility: GPUShaderStage.FRAGMENT,
                buffer: { type: "uniform" },
              });
            }
            const hasMorph = (variant & 0x4000) !== 0; // variant_morph: morph-target UBO + texture
            if (hasMorph) {
              // binding 3: morph weights UBO (80 bytes: idx[8] + wt[8] + count + pad),
              // VERTEX-visible (the vertex shader applies morph deltas).
              bgl0Entries.push({
                binding: 3,
                visibility: GPUShaderStage.VERTEX,
                buffer: { type: "uniform" },
              });
              // binding 4: morph-target data texture (RGBA16F, 2D),
              // VERTEX-visible (vertex shader fetches deltas via textureLoad).
              bgl0Entries.push({
                binding: 4,
                visibility: GPUShaderStage.VERTEX,
                texture: { sampleType: "unfilterable-float", viewDimension: "2d" },
              });
            }
            const bgl0 = device.createBindGroupLayout({ entries: bgl0Entries });
            // group(1): sampler@0 + per-slot textures. Binding numbers + types
            // EXACTLY match wgslPbr's @group(1) decls. base@1, mr@2 always;
            // normal@3 only with variant_normal_map; emissive@4 only with
            // variant_emissive; then occlusion@5(2d), irradiance@6(cube),
            // prefiltered@7(cube), brdf_lut@8(2d) always (tex_ibl unconditional).
            const FRAG = GPUShaderStage.FRAGMENT;
            const tex2d = { sampleType: "float", viewDimension: "2d" };
            const texCube = { sampleType: "float", viewDimension: "cube" };
            const g1 = [
              { binding: 0, visibility: FRAG, sampler: { type: "filtering" } },
              { binding: 1, visibility: FRAG, texture: tex2d }, // base
              { binding: 2, visibility: FRAG, texture: tex2d }, // metallic-roughness
            ];
            if (hasNormal) g1.push({ binding: 3, visibility: FRAG, texture: tex2d });
            if (hasEmissive) g1.push({ binding: 4, visibility: FRAG, texture: tex2d });
            g1.push({ binding: 5, visibility: FRAG, texture: tex2d }); // occlusion
            g1.push({ binding: 6, visibility: FRAG, texture: texCube }); // irradiance
            g1.push({ binding: 7, visibility: FRAG, texture: texCube }); // prefiltered
            g1.push({ binding: 8, visibility: FRAG, texture: tex2d }); // brdf_lut
            if (hasShadow) { // variant_shadow: depth-compare shadow map + sampler
              g1.push({ binding: 9, visibility: FRAG, texture: { sampleType: "depth", viewDimension: "2d" } });
              g1.push({ binding: 10, visibility: FRAG, sampler: { type: "comparison" } });
            }
            if (hasPointShadow) { // variant_shadow_point: RGBA8 atlas at binding 11
              g1.push({ binding: 11, visibility: FRAG, texture: tex2d });
            }
            // S3 LTC LUTs — ALWAYS declared in every PBR variant (group(1) 12/13),
            // so the layout must include them even when no area light is active
            // (the bind group binds a 1×1 rgba16f dummy otherwise).
            g1.push({ binding: 12, visibility: FRAG, texture: tex2d }); // ltc_mat
            g1.push({ binding: 13, visibility: FRAG, texture: tex2d }); // ltc_mag
            const bgl1 = device.createBindGroupLayout({ entries: g1 });
            const layout = device.createPipelineLayout({
              bindGroupLayouts: [bgl0, bgl1],
            });
            // variant_linear_output (1<<9 = 0x200): scene renders into rgba16float
            // HDR target (post path). All other PBR variants render to canvas.
            const pbrFragFormat = (variant & 0x200) ? "rgba16float" : st.format;
            const pbrDesc = {
              layout,
              vertex: {
                module,
                entryPoint: "vs_main",
                buffers: [{
                  // PBR vertex: pos@0, normal@12, tangent@24, uv@40 (stride 48).
                  // Skinned variants extend to stride 56 with joints@48
                  // (uint8x4) + weights@52 (unorm8x4) at locations 4/5.
                  arrayStride: skinned ? 56 : 48,
                  attributes: skinned ? [
                    { shaderLocation: 0, offset: 0, format: "float32x3" },
                    { shaderLocation: 1, offset: 12, format: "float32x3" },
                    { shaderLocation: 2, offset: 24, format: "float32x4" },
                    { shaderLocation: 3, offset: 40, format: "float32x2" },
                    { shaderLocation: 4, offset: 48, format: "uint8x4" },
                    { shaderLocation: 5, offset: 52, format: "unorm8x4" },
                  ] : [
                    { shaderLocation: 0, offset: 0, format: "float32x3" },
                    { shaderLocation: 1, offset: 12, format: "float32x3" },
                    { shaderLocation: 2, offset: 24, format: "float32x4" },
                    { shaderLocation: 3, offset: 40, format: "float32x2" },
                  ],
                }],
              },
              fragment: {
                module,
                entryPoint: "fs_main",
                targets: [{ format: pbrFragFormat }],
              },
              // double-sided (variant_double_sided = 1<<11): render both faces;
              // single-sided: cull back faces (standard winding).
              primitive: { topology: "triangle-list", cullMode: doubleSided ? "none" : "back" },
              depthStencil: {
                format: "depth24plus",
                depthWriteEnabled: true,
                depthCompare: "less",
              },
            };
            const pipeline = device.createRenderPipeline(pbrDesc);
            // Blend fragment target (shared across all blend pipeline variants).
            const blendFragTargets = [{
              format: pbrFragFormat,
              blend: {
                color: { srcFactor: "src-alpha", dstFactor: "one-minus-src-alpha", operation: "add" },
                alpha: { srcFactor: "one", dstFactor: "one-minus-src-alpha", operation: "add" },
              },
            }];
            const blendDepthStencil = {
              format: "depth24plus",
              depthWriteEnabled: false,
              depthCompare: "less",
            };
            // Blend variant: same module/layout/depth-format/color-format as the
            // opaque pipeline — only src-alpha-over blend + depth-write-off differ.
            // Selected by SET_PIPELINE when state_blend (state & 4) is set.
            // Single-sided blend uses cull-back (same as pbrDesc opaque).
            // Double-sided blend needs TWO pipelines: cull-front (back faces) and
            // cull-back (front faces), selected by state_cull_front/state_cull_back.
            const pipelineBlend = device.createRenderPipeline({
              ...pbrDesc,
              fragment: { module, entryPoint: "fs_main", targets: blendFragTargets },
              depthStencil: blendDepthStencil,
            });
            // Double-sided blend cull pipelines (only created when doubleSided).
            // pipelineBlendFront: state_cull_front (8) → draws back faces.
            // pipelineBlendBack:  state_cull_back  (2) → draws front faces.
            const pipelineBlendFront = doubleSided ? device.createRenderPipeline({
              ...pbrDesc,
              primitive: { topology: "triangle-list", cullMode: "front" },
              fragment: { module, entryPoint: "fs_main", targets: blendFragTargets },
              depthStencil: blendDepthStencil,
            }) : null;
            const pipelineBlendBack = doubleSided ? device.createRenderPipeline({
              ...pbrDesc,
              primitive: { topology: "triangle-list", cullMode: "back" },
              fragment: { module, entryPoint: "fs_main", targets: blendFragTargets },
              depthStencil: blendDepthStencil,
            }) : null;
            st.pipelines[handle] = {
              pipeline,
              pipelineBlend,
              pipelineBlendFront,
              pipelineBlendBack,
              bgl0,
              bgl1,
              kind: "pbr",
              flags: variant,
              hasNormal,
              hasEmissive,
              hasShadow,
              skinned,
              hasFog,
              hasMorph,
              hasPointShadow,
            };
            break;
          }
          // Unlit stride-24 path (slice 1) — unchanged.
          const pipeline = device.createRenderPipeline({
            layout: "auto",
            vertex: {
              module,
              entryPoint: "vs_main",
              buffers: [{
                arrayStride: 24,
                attributes: [
                  { shaderLocation: 0, offset: 0, format: "float32x3" },
                  { shaderLocation: 1, offset: 12, format: "float32x3" },
                ],
              }],
            },
            fragment: {
              module,
              entryPoint: "fs_main",
              targets: [{ format: st.format }],
            },
            primitive: { topology: "triangle-list", cullMode: "back" },
            depthStencil: {
              format: "depth24plus",
              depthWriteEnabled: true,
              depthCompare: "less",
            },
          });
          st.pipelines[handle] = { pipeline, kind: "unlit" };
          break;
        }
        case 4: { // SET_PIPELINE — state word selects opaque vs blend variant
          const handle = dv.getUint32(off, true);
          const state = dv.getUint32(off + 4, true);
          const entry = st.pipelines[handle];
          if (entry && st.pass) {
            // state_blend (state & 4): blend variant. For double-sided blend,
            // state_cull_front (8) selects pipelineBlendFront (back faces drawn),
            // state_cull_back (2) selects pipelineBlendBack (front faces drawn).
            // Non-double-sided blend uses pipelineBlend (cull-back inherited from pbrDesc).
            // Fall back to opaque pipeline if no blend variant exists.
            let pipe = entry.pipeline;
            if (state & 4) {
              if (state & 8 && entry.pipelineBlendFront) {
                pipe = entry.pipelineBlendFront;
              } else if (state & 2 && entry.pipelineBlendBack) {
                pipe = entry.pipelineBlendBack;
              } else if (entry.pipelineBlend) {
                pipe = entry.pipelineBlend;
              }
            }
            st.pass.setPipeline(pipe);
            st.active = entry;
          }
          break;
        }
        case 5: { // DRAW
          const vbuf = dv.getUint32(off, true);
          const ibuf = dv.getUint32(off + 4, true);
          const indexCount = dv.getUint32(off + 8, true);
          const mvpPtr = dv.getUint32(off + 12, true);
          const vb = st.buffers[vbuf];
          const ib = st.buffers[ibuf];
          if (vb && ib && st.active && st.pass) {
            if (!st.uniformBuf) {
              st.uniformBuf = device.createBuffer({
                size: 64,
                usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
              });
            }
            device.queue.writeBuffer(st.uniformBuf, 0, new Float32Array(memory.buffer, mvpPtr, 16));
            st.bindGroup = device.createBindGroup({
              layout: st.active.pipeline.getBindGroupLayout(0),
              entries: [{ binding: 0, resource: { buffer: st.uniformBuf } }],
            });
            st.pass.setVertexBuffer(0, vb.buf);
            st.pass.setIndexBuffer(ib.buf, "uint16");
            st.pass.setBindGroup(0, st.bindGroup);
            st.pass.drawIndexed(indexCount);
          }
          break;
        }
        case 6: { // END_FRAME
          if (st.pass && st.encoder) {
            st.pass.end();
            st.device.queue.submit([st.encoder.finish()]);
            st.pass = null;
            st.encoder = null;
          }
          break;
        }
        case 7: // CREATE_TEXTURE — raw RGBA8 (linear)
        case 15: { // CREATE_TEXTURE_SRGB — RGBA8 sRGB internal (hw sRGB→linear on sample)
          // Same 20-byte payload for both: handle|w|h|ptr|byte_len.
          const handle = dv.getUint32(off, true);
          const w = dv.getUint32(off + 4, true);
          const h = dv.getUint32(off + 8, true);
          const p = dv.getUint32(off + 12, true);
          const len = dv.getUint32(off + 16, true);
          const format = tag === 15 ? "rgba8unorm-srgb" : "rgba8unorm";
          const tex = device.createTexture({
            size: [w, h],
            format,
            usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST |
              GPUTextureUsage.RENDER_ATTACHMENT,
          });
          device.queue.writeTexture(
            { texture: tex },
            new Uint8Array(memory.buffer, p, len),
            { bytesPerRow: w * 4, rowsPerImage: h },
            [w, h],
          );
          st.textures[handle] = { tex, view: tex.createView(), w, h };
          break;
        }
        case 10: { // CREATE_TEXTURE_EX — explicit-mip 2D/cube, RGBA8 or RGBA16F (IBL)
          // Payload (command.zig Encoder.createTextureEx, 32B):
          //   handle|target|format|w|h|mip_count|ptr|byte_len.
          // target: 0=2d, 1=cube; format: 0=rgba8, 1=rgba16f. A cube is a 2d
          // texture with 6 array layers + a cube VIEW. Data is mip-major then
          // face-major (+X,-X,+Y,-Y,+Z,-Z), tightly packed.
          const handle = dv.getUint32(off, true);
          const cube = dv.getUint32(off + 4, true) === 1;
          const f16 = dv.getUint32(off + 8, true) === 1;
          const w = dv.getUint32(off + 12, true);
          const h = dv.getUint32(off + 16, true);
          const mips = dv.getUint32(off + 20, true);
          let cursor = dv.getUint32(off + 24, true);
          // off + 28 = byte_len (informational; per-mip/face sizes derived below).
          const bpt = f16 ? 8 : 4; // bytes per RGBA texel (rgba16float vs rgba8)
          const tex = device.createTexture({
            size: [w, h, cube ? 6 : 1],
            format: f16 ? "rgba16float" : "rgba8unorm",
            mipLevelCount: mips,
            usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST,
          });
          const faces = cube ? 6 : 1;
          for (let m = 0; m < mips; m++) {
            const mw = Math.max(1, w >> m);
            const mh = Math.max(1, h >> m);
            for (let face = 0; face < faces; face++) {
              const byteLen = mw * mh * bpt;
              device.queue.writeTexture(
                { texture: tex, mipLevel: m, origin: [0, 0, face] },
                new Uint8Array(memory.buffer, cursor, byteLen),
                { bytesPerRow: mw * bpt, rowsPerImage: mh },
                [mw, mh, 1],
              );
              cursor += byteLen;
            }
          }
          const view = cube
            ? tex.createView({ dimension: "cube" })
            : tex.createView();
          st.textures[handle] = { tex, view, w, h, cube };
          break;
        }
        case 8: { // BIND_TEXTURE — record slot→handle; bind group assembled at draw_pbr (T3)
          const slot = dv.getUint32(off, true);
          const handle = dv.getUint32(off + 4, true);
          st.boundTex[slot] = handle;
          st.bg1Dirty = true; // invalidate cached group(1) bind group
          break;
        }
        case 11: { // SET_LIGHTS — pack into the PBR uniform's lights region.
          // Payload (command.zig Encoder.setLights, 8B): count | ptr. Each light
          // is 16 f32 = 64B (4 vec4/light):
          //   v0 = [type, intensity, pos.x, pos.y]
          //   v1 = [pos.z, dir.x, dir.y, dir.z]
          //   v2 = [color.r, color.g, color.b, range]
          //   v3 = [cosIn, cosOut, __, __]
          // Copies verbatim into lights[] (max 4 lights = 16 vec4 = 64 f32).
          // Per-frame state (same for every draw): cache a copy; draw_pbr writes
          // it into each draw's uniform slot. Copy out of wasm memory now.
          const count = dv.getUint32(off, true);
          const p = dv.getUint32(off + 4, true);
          const n = Math.min(count, 4);
          st.frameLights = (n > 0) ? new Float32Array(memory.buffer, p, n * 16).slice() : new Float32Array(0);
          st.frameLightCount = n;
          break;
        }
        case 36: { // SET_CSM — cache CSM frame-globals (cascade_count, splits, view_forward).
          // Payload (command.zig Encoder.setCsm, 12B): count | splits_ptr | view_forward_ptr.
          // Frame-global like set_lights; draw_pbr/case-20 write them into each shadowed
          // draw's U at PBR_U.cascadeCount/cascadeSplits/viewForward. .slice() → byteOffset 0.
          st.frameCascadeCount = dv.getUint32(off, true);
          st.frameCascadeSplits = new Float32Array(memory.buffer, dv.getUint32(off + 4, true), 4).slice();
          st.frameViewForward = new Float32Array(memory.buffer, dv.getUint32(off + 8, true), 3).slice();
          break;
        }
        case 12: { // BIND_IBL — irradiance(6)/prefiltered(7)/brdf_lut(8) + prefMips.
          // Payload (command.zig Encoder.bindIbl, 16B): irr|spec|lut|spec_mip_count.
          // Records the IBL handles; draw_pbr resolves them into bind group 1
          // (replacing the black placeholders). prefiltered_mips drives the
          // specular reflection LOD in wgslPbr.
          const irr = dv.getUint32(off, true);
          const spec = dv.getUint32(off + 4, true);
          const lut = dv.getUint32(off + 8, true);
          const specMips = dv.getUint32(off + 12, true);
          st.ibl = { irr, spec, lut };
          st.framePrefMips = specMips; // cached; draw_pbr writes it per slot
          st.bg1Dirty = true; // rebind group(1) with the real IBL views
          break;
        }
        case 37: { // SET_AREA_LIGHTS — cache the per-frame area-light array (LTC).
          // Payload (command.zig Encoder.setAreaLights, 8B): count | ptr. Each area
          // light is 16 f32 = 64B (4 vec4): a0=[pos,intensity] a1=[ex,two_sided]
          // a2=[ey,shadow_slot] a3=[color,shadow_kind]. Per-frame state; draw_pbr
          // writes area_count@504 + area_lights@512 into each draw's slot. Max 16.
          const count = dv.getUint32(off, true);
          const p = dv.getUint32(off + 4, true);
          const n = Math.min(count, 16);
          st.frameAreaCount = n;
          st.frameAreaLights = (n > 0) ? new Float32Array(memory.buffer, p, n * 16).slice() : null;
          break;
        }
        case 38: { // BIND_LTC_LUT — ensure the LTC LUTs are loaded + mark group(1) dirty.
          // Payload (command.zig Encoder.bindLtcLut, 8B): mat_handle | mag_handle.
          // The handles are ADVISORY — the bridge OWNS the LUTs (global, not per
          // scene) and fetches them by fixed URL (/gl/ltc.bin) ONCE. The two 64×64
          // rgba16f textures bind at group(1) 12/13 (draw_pbr); a 1×1 dummy stands
          // in until the fetch resolves. bg1Dirty so the bind group rebuilds with
          // the real views once loaded.
          gpuEnsureLtc(st);
          st.bg1Dirty = true;
          break;
        }
        case 21: { // SET_BONES — upload the bone palette to bones @group(0)@binding(1).
          // Payload (command.zig Encoder.setBones, 8B): count | ptr. count = number
          // of mat4 (≤64); ptr → count*16 f32 column-major. Writes the whole
          // palette into the bones uniform; skinned bg0 binds it (binding 1).
          const count = dv.getUint32(off, true);
          const p = dv.getUint32(off + 4, true);
          device.queue.writeBuffer(gpuEnsureBones(st), 0, new Float32Array(memory.buffer, p, count * 16));
          break;
        }
        case 14: { // DELETE_RESOURCE — free one GPU object (parity with glInterpret).
          // Payload (command.zig Encoder.deleteResource, 8B): kind | handle.
          // ResKind: 0 buffer, 1 texture, 2 shader/pipeline, 3 shadow map.
          const kind = dv.getUint32(off, true);
          const handle = dv.getUint32(off + 4, true);
          if (kind === 0) {
            if (st.buffers[handle]) { st.buffers[handle].buf.destroy(); st.buffers[handle] = null; }
          } else if (kind === 1) {
            if (st.textures[handle]) { st.textures[handle].tex.destroy(); st.textures[handle] = null; }
          } else if (kind === 2) {
            // Pipelines have no .destroy() (GC-only); drop the entry ref (which
            // GC's both pipeline + pipelineBlend variants) + clear active.
            if (st.active === st.pipelines[handle]) st.active = null;
            st.pipelines[handle] = null;
          } else if (kind === 3) {
            if (st.shadowMaps[handle]) { st.shadowMaps[handle].tex.destroy(); st.shadowMaps[handle] = null; }
          } else if (kind === 4) { // render target — color + optional depth texture
            const rt = st.renderTargets[handle];
            if (rt) {
              rt.tex.destroy();
              if (rt.depthTex) rt.depthTex.destroy();
              st.renderTargets[handle] = null;
            }
          }
          break;
        }
        case 16: { // CREATE_SHADOW_MAP — depth texture + comparison sampler; 2D shadow ATLAS.
          // Payload (command.zig Encoder.createShadowMap, 8B): handle | size.
          // Multi-caster: T3 passes size=4096; up to 4 casters each render into a
          // 1024² tile (col=slot%4, row=slot/4) of this one depth32float atlas.
          const handle = dv.getUint32(off, true);
          const size = dv.getUint32(off + 4, true);
          const tex = device.createTexture({
            size: [size, size],
            format: "depth32float",
            usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING,
          });
          // Hardware depth comparison (textureSampleCompare) — LEQUAL via 'less'.
          const sampler = device.createSampler({
            compare: "less",
            magFilter: "linear",
            minFilter: "linear",
          });
          st.shadowMaps[handle] = { tex, view: tex.createView(), sampler, size };
          break;
        }
        case 17: { // BEGIN_SHADOW_PASS — open a depth-only pass into one ATLAS TILE.
          // NEW payload (20B): atlas_handle | depth_shader_handle | col | row | tile.
          // Runs BEFORE begin_frame; opens (and owns) the frame's command encoder so
          // the depth pass and the later color pass share one encoder + submit.
          // Multi-caster: mirrors the point-face tiling (case 32) — each caster opens
          // its own depth pass into the shared atlas; loadOp clears the WHOLE depth
          // attachment ONLY on the first tile (col=0,row=0) since WebGPU loadOp
          // ignores scissor, then setViewport/setScissorRect restrict draws to the tile.
          const sm = st.shadowMaps[dv.getUint32(off, true)];
          const depthPipe = st.pipelines[dv.getUint32(off + 4, true)];
          const col  = dv.getUint32(off + 8, true);
          const row  = dv.getUint32(off + 12, true);
          const tile = dv.getUint32(off + 16, true);
          if (!sm || !depthPipe) break;
          if (!st.encoder) st.encoder = device.createCommandEncoder();
          // Close any prior shadow pass (previous caster's tile) before opening this one.
          if (st.shadowPass) { st.shadowPass.end(); st.shadowPass = null; }
          const isFirstTile = (col === 0 && row === 0);
          st.shadowPass = st.encoder.beginRenderPass({
            colorAttachments: [],
            depthStencilAttachment: {
              view: sm.view,
              depthClearValue: 1.0,
              depthLoadOp: isFirstTile ? "clear" : "load",
              depthStoreOp: "store",
            },
          });
          st.shadowPass.setViewport(col * tile, row * tile, tile, tile, 0, 1);
          st.shadowPass.setScissorRect(col * tile, row * tile, tile, tile);
          st.active = depthPipe;
          // Reset per-draw depth-uniform slot allocation only at the first tile so
          // slots are unique across all casters within the frame (like point faces).
          if (isFirstTile) {
            st.depthSlot = 0; // reset per-draw depth-uniform slot allocation
            st.depthAtSlot = 0; // depth-at draws use a separate buffer + slot counter
          }
          gpuEnsureDepthUniform(st, depthPipe);
          break;
        }
        case 18: { // END_SHADOW_PASS — close the depth pass (keep encoder for color).
          if (st.shadowPass) {
            st.shadowPass.end();
            st.shadowPass = null;
          }
          break;
        }
        case 19: { // DRAW_DEPTH — position-only draw into the shadow map.
          // Payload (20B): vbuf | ibuf | idx_byte_off | count | mvp_ptr.
          const vb = st.buffers[dv.getUint32(off, true)];
          const ib = st.buffers[dv.getUint32(off + 4, true)];
          const byteOff = dv.getUint32(off + 8, true);
          const count = dv.getUint32(off + 12, true);
          const mvpPtr = dv.getUint32(off + 16, true);
          if (!vb || !ib || !st.shadowPass || !st.active || st.active.kind !== "depth") break;
          const dslot = st.depthSlot++;
          if (dslot >= MAX_DRAWS) break; // per-pass draw cap
          const dbase = dslot * DEPTH_STRIDE;
          device.queue.writeBuffer(st.depthUniform, dbase, new Float32Array(memory.buffer, mvpPtr, 16));
          st.shadowPass.setPipeline(st.active.pipeline);
          st.shadowPass.setVertexBuffer(0, vb.buf);
          st.shadowPass.setIndexBuffer(ib.buf, "uint16", byteOff);
          st.shadowPass.setBindGroup(0, st.depthBindGroup, [dbase]);
          st.shadowPass.drawIndexed(count);
          break;
        }
        case 26: { // DRAW_DEPTH_AT — alpha-tested depth draw (MASK cutout shadows).
          // Payload (command.zig Encoder.drawDepthAt, 28B / 7 u32):
          //   shader | vbuf | ibuf | idx_byte_off | count | mvp_ptr | material_ptr.
          // Selects the depth-at pipeline (handle from the payload — created as
          // shader handle 10), writes {mvp, material} into its own dynamic-offset
          // uniform slot, and binds the base texture (slot 0, from the preceding
          // bind_texture) + a sampler so the fragment can discard cutout holes.
          const datPipe = st.pipelines[dv.getUint32(off, true)];
          const vb = st.buffers[dv.getUint32(off + 4, true)];
          const ib = st.buffers[dv.getUint32(off + 8, true)];
          const byteOff = dv.getUint32(off + 12, true);
          const count = dv.getUint32(off + 16, true);
          const mvpPtr = dv.getUint32(off + 20, true);
          const materialPtr = dv.getUint32(off + 24, true);
          if (!datPipe || datPipe.kind !== "depthAt" || !vb || !ib || !st.shadowPass) break;
          const dslot = st.depthAtSlot++;
          if (dslot >= MAX_DRAWS) break; // per-pass draw cap
          const dbase = dslot * DEPTH_STRIDE;
          const ubuf = gpuEnsureDepthAtUniform(st);
          // Slot layout (wgslDepthAt U): mvp mat4x4 @0 (64B), material vec4[3] @64 (48B).
          device.queue.writeBuffer(ubuf, dbase, new Float32Array(memory.buffer, mvpPtr, 16));
          device.queue.writeBuffer(ubuf, dbase + 64, new Float32Array(memory.buffer, materialPtr, 12));
          // Base texture (bind_texture slot 0) + the default filtering sampler.
          const baseView = gpuSlotView(st, 0, st.defaults.white2d);
          const bg = device.createBindGroup({
            layout: datPipe.bgl0,
            entries: [
              { binding: 0, resource: { buffer: ubuf, offset: 0, size: 112 } },
              { binding: 1, resource: baseView },
              { binding: 2, resource: st.defaults.sampler },
            ],
          });
          st.shadowPass.setPipeline(datPipe.pipeline);
          st.shadowPass.setVertexBuffer(0, vb.buf);
          st.shadowPass.setIndexBuffer(ib.buf, "uint16", byteOff);
          st.shadowPass.setBindGroup(0, bg, [dbase]);
          st.shadowPass.drawIndexed(count);
          break;
        }
        case 20: { // BIND_SHADOW_MAP — record the atlas + cache shadow_vp[] array.
          // NEW payload (16B): slot | atlas_handle | vp_ptr | count. The depth-compare
          // atlas + comparison sampler are bound at draw_pbr (group(1) 9/10); here we
          // record the handle and cache `count` consecutive mat4 for the U.shadow_vp[].
          const atlasHandle = dv.getUint32(off + 4, true);
          const vpPtr = dv.getUint32(off + 8, true);
          const count = dv.getUint32(off + 12, true);
          st.shadow = { handle: atlasHandle };
          // Cache the shadow_vp[] array; draw_pbr writes it into each slot.
          st.frameShadowVp = new Float32Array(memory.buffer, vpPtr, count * 16).slice();
          st.frameShadowVpCount = count;
          st.bg1Dirty = true; // rebind group(1) with the real shadow atlas
          break;
        }
        case 13: { // DRAW_PBR — full PBR submesh draw.
          // Payload (command.zig Encoder.drawPbr, 36B / 9 u32):
          //   vbuf | ibuf | idx_byte_off | count | mvp_ptr | model_ptr |
          //   normal_ptr(mat3) | material_ptr | camera_ptr.
          const vh = dv.getUint32(off, true);
          const ih = dv.getUint32(off + 4, true);
          const byteOff = dv.getUint32(off + 8, true);
          const count = dv.getUint32(off + 12, true);
          const mvpPtr = dv.getUint32(off + 16, true);
          const modelPtr = dv.getUint32(off + 20, true);
          const normalPtr = dv.getUint32(off + 24, true);
          const materialPtr = dv.getUint32(off + 28, true);
          const cameraPtr = dv.getUint32(off + 32, true);
          const vb = st.buffers[vh];
          const ib = st.buffers[ih];
          const active = st.active;
          if (!vb || !ib || !active || active.kind !== "pbr" || !st.pass) break;
          const ubuf = gpuEnsurePbrUniform(st);
          const slot = st.pbrSlot++;
          if (slot >= MAX_DRAWS) break; // per-frame draw cap (silently drop extras)
          const base = slot * PBR_STRIDE;
          // ── Write the FULL uniform struct into this draw's slot (per-draw from
          // the payload + cached per-frame values replicated per draw). Dynamic
          // offset isolates draws so a later writeBuffer can't clobber this one. ──
          device.queue.writeBuffer(ubuf, base + PBR_U.mvp, new Float32Array(memory.buffer, mvpPtr, 16));
          device.queue.writeBuffer(ubuf, base + PBR_U.model, new Float32Array(memory.buffer, modelPtr, 16));
          // mat3 (9 f32, column-major) → mat3x3 (3 vec4 cols, 12 f32). Re-pack:
          // each 3-f32 column at +0/+12/+24 in source goes to +0/+16/+32 in dest.
          const nm = new Float32Array(memory.buffer, normalPtr, 9);
          const nmPadded = new Float32Array(12);
          nmPadded[0] = nm[0]; nmPadded[1] = nm[1]; nmPadded[2] = nm[2];
          nmPadded[4] = nm[3]; nmPadded[5] = nm[4]; nmPadded[6] = nm[5];
          nmPadded[8] = nm[6]; nmPadded[9] = nm[7]; nmPadded[10] = nm[8];
          device.queue.writeBuffer(ubuf, base + PBR_U.normalMat, nmPadded);
          // camera_pos: vec3 (3 f32) — write 3, the 4th byte slot is pad.
          device.queue.writeBuffer(ubuf, base + PBR_U.cameraPos, new Float32Array(memory.buffer, cameraPtr, 3));
          // material: 3×vec4 = 12 f32.
          device.queue.writeBuffer(ubuf, base + PBR_U.material, new Float32Array(memory.buffer, materialPtr, 12));
          // Per-frame cached uniforms (lights / IBL mips / shadow light_vp).
          if (st.frameLights && st.frameLights.length) {
            device.queue.writeBuffer(ubuf, base + PBR_U.lights, st.frameLights);
          }
          device.queue.writeBuffer(ubuf, base + PBR_U.lightCount, new Int32Array([st.frameLightCount | 0]));
          device.queue.writeBuffer(ubuf, base + PBR_U.prefMips, new Float32Array([st.framePrefMips || 0]));
          // S3 area lights (set_area_lights, tag 37): area_count i32 @504, area_lights
          // array<vec4,16> @512 (count*16 f32). Element-vs-byte: pass .buffer/.byteOffset
          // + byte size for the TypedArray (it is .slice()'d → byteOffset 0).
          device.queue.writeBuffer(ubuf, base + PBR_U.areaCount, new Int32Array([st.frameAreaCount | 0]));
          if (st.frameAreaLights && st.frameAreaCount > 0) {
            device.queue.writeBuffer(ubuf, base + PBR_U.areaLights,
              st.frameAreaLights.buffer, st.frameAreaLights.byteOffset, (st.frameAreaCount | 0) * 16 * 4);
          }
          if (st.frameShadowVp && st.frameShadowVpCount > 0) {
            // shadow_vp[count] → U.shadow_vp @768. writeBuffer dataOffset/size are
            // ELEMENTS for a TypedArray, so pass .buffer/.byteOffset + the byte size.
            device.queue.writeBuffer(ubuf, base + PBR_U.shadowVp,
              st.frameShadowVp.buffer, st.frameShadowVp.byteOffset, st.frameShadowVpCount * 64);
          }
          // CSM frame-globals (set_csm, tag 36): cascade_count i32 @1280, cascade_splits
          // vec4 @1296 (16B), view_forward vec3 @1312 (12B). Element-vs-byte: pass
          // .buffer/.byteOffset + byte size for the TypedArrays (they are .slice()'d → off 0).
          if (st.frameCascadeCount > 0) {
            device.queue.writeBuffer(ubuf, base + PBR_U.cascadeCount, new Int32Array([st.frameCascadeCount | 0]));
            device.queue.writeBuffer(ubuf, base + PBR_U.cascadeSplits,
              st.frameCascadeSplits.buffer, st.frameCascadeSplits.byteOffset, 16);
            device.queue.writeBuffer(ubuf, base + PBR_U.viewForward,
              st.frameViewForward.buffer, st.frameViewForward.byteOffset, 12);
          }
          // ── Bind group 0: created once; the dynamic offset selects the slot. ──
          // Skinned variants add binding 1 (bones palette, whole buffer, static).
          // Keyed on active.bgl0, so switching between skinned (2-entry) and
          // non-skinned (1-entry) layouts rebuilds. The setBindGroup offsets
          // array length tracks hasDynamicOffset entries — binding 0 only — so it
          // stays exactly 1 (binding 1 is static).
          if (!st.bg0 || st.bg0Layout !== active.bgl0) {
            const bg0Entries = [{ binding: 0, resource: { buffer: ubuf, offset: 0, size: PBR_U.size } }];
            if (active.skinned) {
              bg0Entries.push({ binding: 1, resource: { buffer: gpuEnsureBones(st) } });
            }
            // binding 2: fog UBO (static, FRAGMENT-only). Created lazily; SET_FOG
            // also creates it on first call. Layout has binding 2 iff hasFog.
            if (active.hasFog) {
              if (!st.fogBuf) st.fogBuf = device.createBuffer({ size: 32, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
              bg0Entries.push({ binding: 2, resource: { buffer: st.fogBuf } });
            }
            // binding 3: morph weights UBO (80B), binding 4: morph texture (VERTEX-visible).
            // Layout has bindings 3+4 iff hasMorph — must match bgl0 exactly.
            if (active.hasMorph) {
              if (!st.morphBuf) st.morphBuf = device.createBuffer({ size: 80, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
              const mte = st.morphTexView;
              if (mte) {
                bg0Entries.push({ binding: 3, resource: { buffer: st.morphBuf } });
                bg0Entries.push({ binding: 4, resource: mte });
              }
            }
            // Multi-caster: the dead PointShadow uniform (old bg0 binding 5) is GONE.
            // Task 1 deleted the WGSL `struct PointShadow` + `@group(0) @binding(5)`;
            // the receiver now reads each point caster's lpos/far from the per-light
            // loop vars. Pushing a binding-5 entry here would be a bind-group-layout
            // mismatch (WebGPU validation error), so it is removed entirely.
            st.bg0 = device.createBindGroup({ layout: active.bgl0, entries: bg0Entries });
            st.bg0Layout = active.bgl0;
          }
          // ── Bind group 1: sampler + textures. Cached; invalidated by tag 8 ──
          // (bg1Dirty) or a layout/pipeline change. WGSL @group(1) binding =
          // logical PBR slot + 1 (binding 0 is the sampler). Per-logical-slot
          // default (gpuMakeDefaults): 0 base/1 mr/2 normal/4 occlusion→white2d,
          // 3 emissive→black2d, 5 irradiance/6 prefiltered→blackCube, 7 brdf_lut
          // →black2d. bind_texture wire slots: 0 base,1 mr,2 normal,3 emissive,
          // 4 occlusion. IBL (bindings 6/7/8) fall back to defaults in slice 2a.
          if (st.bg1Dirty || !st.bg1 || st.bg1Layout !== active.bgl1) {
            const d = st.defaults;
            const e = [{ binding: 0, resource: d.sampler }];
            e.push({ binding: 1, resource: gpuSlotView(st, 0, d.white2d) }); // base
            e.push({ binding: 2, resource: gpuSlotView(st, 1, d.white2d) }); // mr
            if (active.hasNormal) {
              e.push({ binding: 3, resource: gpuSlotView(st, 2, d.white2d) }); // normal
            }
            if (active.hasEmissive) {
              e.push({ binding: 4, resource: gpuSlotView(st, 3, d.black2d) }); // emissive
            }
            e.push({ binding: 5, resource: gpuSlotView(st, 4, d.white2d) }); // occlusion
            const ibl = st.ibl;
            e.push({ binding: 6, resource: gpuIblView(st, ibl?.irr, d.blackCube) }); // irradiance (cube)
            e.push({ binding: 7, resource: gpuIblView(st, ibl?.spec, d.blackCube) }); // prefiltered (cube)
            e.push({ binding: 8, resource: gpuIblView(st, ibl?.lut, d.black2d) }); // brdf_lut
            if (active.hasShadow) { // variant_shadow: depth-compare map + sampler
              const sm = st.shadow ? st.shadowMaps[st.shadow.handle] : null;
              e.push({ binding: 9, resource: (sm && sm.view) ? sm.view : d.shadowTex.view });
              e.push({ binding: 10, resource: (sm && sm.sampler) ? sm.sampler : d.shadowSampler });
            }
            if (active.hasPointShadow) { // variant_shadow_point: RGBA8 atlas at binding 11
              e.push({ binding: 11, resource: st.pointAtlasView || d.black2d });
            }
            // S3 LTC LUTs (ALWAYS declared in every PBR variant — bindings 12/13).
            // Bind the loaded LUTs (set by bind_ltc_lut, tag 38) or a 1×1 rgba16f
            // dummy so the group(1) layout stays valid even when no LTC is loaded /
            // area_count=0 (shader never samples them then — content irrelevant).
            e.push({ binding: 12, resource: (st.ltcMat && st.ltcMat.view) ? st.ltcMat.view : d.ltcDummy.view });
            e.push({ binding: 13, resource: (st.ltcMag && st.ltcMag.view) ? st.ltcMag.view : d.ltcDummy.view });
            st.bg1 = device.createBindGroup({ layout: active.bgl1, entries: e });
            st.bg1Layout = active.bgl1;
            st.bg1Dirty = false;
          }
          // Multi-caster: no per-draw PointShadow uniform write — the dead binding-5
          // buffer is gone (the receiver reads lpos/far from the per-light loop vars).
          st.pass.setPipeline(active.pipeline);
          st.pass.setVertexBuffer(0, vb.buf);
          st.pass.setIndexBuffer(ib.buf, "uint16", byteOff);
          st.pass.setBindGroup(0, st.bg0, [base]);
          st.pass.setBindGroup(1, st.bg1);
          st.pass.drawIndexed(count);
          break;
        }
        case 27: { // DRAW_PBR_INSTANCED — N instances via per-instance attr mat4+color.
          // Payload (command.zig draw_pbr_instanced, 36B / 9 u32):
          //   vbuf | ibuf | idx_byte_off | count | instance_ptr | instance_count |
          //   vp_ptr | material_ptr | camera_ptr.
          const vh = dv.getUint32(off, true);
          const ih = dv.getUint32(off + 4, true);
          const byteOff = dv.getUint32(off + 8, true);
          const count = dv.getUint32(off + 12, true);
          const instancePtr = dv.getUint32(off + 16, true);
          const instanceCount = dv.getUint32(off + 20, true);
          const vpPtr = dv.getUint32(off + 24, true);
          const materialPtr = dv.getUint32(off + 28, true);
          const cameraPtr = dv.getUint32(off + 32, true);
          const vb = st.buffers[vh];
          const ib = st.buffers[ih];
          const active = st.active;
          if (!vb || !ib || !active || active.kind !== "pbr-instanced" || !st.pass) break;
          // ── Persistent instance vertex buffer — lazy create, resize-on-demand. ──
          const instBytes = instanceCount * 80;
          if (!st.instanceBuf || st.instanceBuf.size < instBytes) {
            if (st.instanceBuf) st.instanceBuf.destroy();
            st.instanceBuf = device.createBuffer({
              size: instBytes,
              usage: GPUBufferUsage.VERTEX | GPUBufferUsage.COPY_DST,
            });
          }
          device.queue.writeBuffer(st.instanceBuf, 0, memory.buffer, instancePtr, instBytes);
          // ── Per-draw uniform slot (PBR_U layout, instanced U adds vp @ 768). ──
          // The instanced WGSL U struct has all standard fields (mvp, model, …) plus
          // the S3 area block (area_count@504, area_lights@512..768), then a single
          // `vp: mat4x4<f32>` appended at offset 768 — the SAME slot as PBR_U.shadowVp
          // (the shadow variant's shadow_vp[0]). We write one mat there. We only write
          // the fields the shader actually reads: vp, material, camera. Instanced is
          // non-area (area_count=0), but we still zero area_count for a valid struct.
          const ubuf = gpuEnsurePbrUniform(st);
          const slot = st.pbrSlot++;
          if (slot >= MAX_DRAWS) break;
          const base = slot * PBR_STRIDE;
          // vp (view-proj): u.vp — offset 768 (= PBR_U.shadowVp in the JS table).
          device.queue.writeBuffer(ubuf, base + PBR_U.shadowVp, new Float32Array(memory.buffer, vpPtr, 16));
          // material: 3×vec4 = 12 f32.
          device.queue.writeBuffer(ubuf, base + PBR_U.material, new Float32Array(memory.buffer, materialPtr, 12));
          // camera_pos: vec3 (3 f32, 4th byte is pad).
          device.queue.writeBuffer(ubuf, base + PBR_U.cameraPos, new Float32Array(memory.buffer, cameraPtr, 3));
          // Per-frame cached uniforms (lights / IBL mips).
          if (st.frameLights && st.frameLights.length) {
            device.queue.writeBuffer(ubuf, base + PBR_U.lights, st.frameLights);
          }
          device.queue.writeBuffer(ubuf, base + PBR_U.lightCount, new Int32Array([st.frameLightCount | 0]));
          device.queue.writeBuffer(ubuf, base + PBR_U.prefMips, new Float32Array([st.framePrefMips || 0]));
          // Instanced is non-area: zero area_count so the shader skips the area loop.
          device.queue.writeBuffer(ubuf, base + PBR_U.areaCount, new Int32Array([0]));
          // ── Bind group 0: dynamic-offset uniform. Instanced has no bones. ──
          if (!st.bg0 || st.bg0Layout !== active.bgl0) {
            const bg0Entries = [{ binding: 0, resource: { buffer: ubuf, offset: 0, size: PBR_U.size } }];
            if (active.hasFog) {
              if (!st.fogBuf) st.fogBuf = device.createBuffer({ size: 32, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
              bg0Entries.push({ binding: 2, resource: { buffer: st.fogBuf } });
            }
            st.bg0 = device.createBindGroup({
              layout: active.bgl0,
              entries: bg0Entries,
            });
            st.bg0Layout = active.bgl0;
          }
          // ── Bind group 1: sampler + textures (same logic as non-instanced). ──
          if (st.bg1Dirty || !st.bg1 || st.bg1Layout !== active.bgl1) {
            const d = st.defaults;
            const e = [{ binding: 0, resource: d.sampler }];
            e.push({ binding: 1, resource: gpuSlotView(st, 0, d.white2d) }); // base
            e.push({ binding: 2, resource: gpuSlotView(st, 1, d.white2d) }); // mr
            if (active.hasNormal) {
              e.push({ binding: 3, resource: gpuSlotView(st, 2, d.white2d) }); // normal
            }
            if (active.hasEmissive) {
              e.push({ binding: 4, resource: gpuSlotView(st, 3, d.black2d) }); // emissive
            }
            e.push({ binding: 5, resource: gpuSlotView(st, 4, d.white2d) }); // occlusion
            const ibl = st.ibl;
            e.push({ binding: 6, resource: gpuIblView(st, ibl?.irr, d.blackCube) }); // irradiance
            e.push({ binding: 7, resource: gpuIblView(st, ibl?.spec, d.blackCube) }); // prefiltered
            e.push({ binding: 8, resource: gpuIblView(st, ibl?.lut, d.black2d) }); // brdf_lut
            if (active.hasShadow) {
              const sm = st.shadow ? st.shadowMaps[st.shadow.handle] : null;
              e.push({ binding: 9, resource: (sm && sm.view) ? sm.view : d.shadowTex.view });
              e.push({ binding: 10, resource: (sm && sm.sampler) ? sm.sampler : d.shadowSampler });
            }
            // S3 LTC LUTs — always declared (bindings 12/13). Instanced is non-area
            // so the dummy is what binds; the layout still requires the entries.
            e.push({ binding: 12, resource: (st.ltcMat && st.ltcMat.view) ? st.ltcMat.view : d.ltcDummy.view });
            e.push({ binding: 13, resource: (st.ltcMag && st.ltcMag.view) ? st.ltcMag.view : d.ltcDummy.view });
            st.bg1 = device.createBindGroup({ layout: active.bgl1, entries: e });
            st.bg1Layout = active.bgl1;
            st.bg1Dirty = false;
          }
          // ── Draw: mesh at slot 0, instance data at slot 1. ──
          st.pass.setPipeline(active.pipeline);
          st.pass.setVertexBuffer(0, vb.buf);
          st.pass.setVertexBuffer(1, st.instanceBuf);
          st.pass.setIndexBuffer(ib.buf, "uint16", byteOff);
          st.pass.setBindGroup(0, st.bg0, [base]);
          st.pass.setBindGroup(1, st.bg1);
          st.pass.drawIndexed(count, instanceCount);
          break;
        }
        case 22: { // CREATE_RENDER_TARGET — color (+ optional depth) offscreen target.
          // Payload (command.zig createRenderTarget, 20B): handle|w|h|fmt|flags.
          // fmt: 0=rgba8unorm, 1=rgba16float. flags bit0 = with_depth (depth24plus).
          const handle = dv.getUint32(off, true);
          const w = dv.getUint32(off + 4, true);
          const h = dv.getUint32(off + 8, true);
          const fmt = dv.getUint32(off + 12, true);
          const flags = dv.getUint32(off + 16, true);
          const format = fmt === 1 ? "rgba16float" : "rgba8unorm";
          const tex = device.createTexture({
            size: [w, h],
            format,
            usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING,
          });
          let depthTex = null, depthView = null;
          if (flags & 1) {
            depthTex = device.createTexture({
              size: [w, h],
              format: "depth24plus",
              usage: GPUTextureUsage.RENDER_ATTACHMENT,
            });
            depthView = depthTex.createView();
          }
          st.renderTargets[handle] = { tex, view: tex.createView(), depthTex, depthView, w, h, format };
          break;
        }
        case 23: { // BEGIN_OFFSCREEN_PASS — render into a target (reuse frame encoder).
          // Payload (24B): target | clear_rgba(4×f32) | clear_flags.
          const target = dv.getUint32(off, true);
          const r = dv.getFloat32(off + 4, true);
          const g = dv.getFloat32(off + 8, true);
          const b = dv.getFloat32(off + 12, true);
          const a = dv.getFloat32(off + 16, true);
          const cf = dv.getUint32(off + 20, true);
          const rt = st.renderTargets[target];
          if (!rt) break;
          // First pass of a post frame: new encoder → reset the post params slot.
          if (!st.encoder) { st.encoder = device.createCommandEncoder(); st.postSlot = 0; }
          st.pass = st.encoder.beginRenderPass({
            colorAttachments: [{
              view: rt.view,
              clearValue: { r, g, b, a },
              loadOp: (cf & 1) ? "clear" : "load",
              storeOp: "store",
            }],
            depthStencilAttachment: rt.depthView ? {
              view: rt.depthView,
              depthClearValue: 1.0,
              depthLoadOp: (cf & 2) ? "clear" : "load",
              depthStoreOp: "store",
            } : undefined,
          });
          st.curTargetFormat = rt.format;
          st.curPassHasDepth = !!rt.depthView; // offscreen pass has depth only if the RT has one
          st.active = null; // force pipeline re-bind for draws in this pass
          break;
        }
        case 24: { // END_OFFSCREEN_PASS — close the offscreen pass (keep encoder).
          if (st.pass) { st.pass.end(); st.pass = null; }
          break;
        }
        case 25: { // DRAW_FULLSCREEN_QUAD — post effect into the current pass.
          // Payload (20B): shader | tex0 | tex1 | params_ptr | param_count.
          const shHandle = dv.getUint32(off, true);
          const t0 = dv.getUint32(off + 4, true);
          const t1 = dv.getUint32(off + 8, true);
          const pPtr = dv.getUint32(off + 12, true);
          const pCount = dv.getUint32(off + 16, true);
          const entry = st.pipelines[shHandle];
          const src0rt = st.renderTargets[t0];
          if (!entry || entry.kind !== "post" || !st.pass || !src0rt) break;
          const format = st.curTargetFormat || st.format;
          const pipe = getOrCreatePostPipeline(st, entry, format, !!st.curPassHasDepth);
          // Params: up to 4 f32 from the wire (zero-padded), written into this
          // draw's own 256-aligned slot so a later draw's writeBuffer can't clobber
          // it before the single end-of-frame submit (see POST_STRIDE note above).
          const pubuf = gpuEnsurePostUniform(st);
          const pslot = st.postSlot++;
          if (pslot >= MAX_POST_DRAWS) break; // per-frame cap (silently drop extras)
          const pbase = pslot * POST_STRIDE;
          const arr = new Float32Array(4);
          for (let i = 0; i < pCount && i < 4; i++) arr[i] = dv.getFloat32(pPtr + i * 4, true);
          device.queue.writeBuffer(pubuf, pbase, arr);
          const src1 = (t1 !== 0 && st.renderTargets[t1]) ? st.renderTargets[t1].view : st.dummyTexView;
          const bg0 = device.createBindGroup({
            layout: entry.bgl0,
            entries: [{ binding: 0, resource: { buffer: pubuf, offset: pbase, size: 32 } }],
          });
          const bg1 = device.createBindGroup({
            layout: entry.bgl1,
            entries: [
              { binding: 0, resource: st.linearSampler },
              { binding: 1, resource: src0rt.view },
              { binding: 2, resource: src1 },
            ],
          });
          st.pass.setPipeline(pipe);
          st.pass.setBindGroup(0, bg0);
          st.pass.setBindGroup(1, bg1);
          st.pass.draw(3, 1, 0, 0);
          break;
        }
        case 28: { // SET_FOG (WebGPU) — write the 8 f32 fog UBO at group(0) binding(2).
          // Payload (4B): ptr → 8 f32 (Fog.a: vec4, Fog.b: vec4 = 32B total).
          // Lazily creates st.fogBuf on first call; SET_FOG may arrive before the
          // first draw if the frame order is set_fog → set_pipeline → draw_pbr.
          if (!st.fogBuf) st.fogBuf = device.createBuffer({ size: 32, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
          device.queue.writeBuffer(st.fogBuf, 0, memory.buffer, dv.getUint32(off, true), 32);
          break;
        }
        case 29: { // SET_MORPH_WEIGHTS (WebGPU) — write 80-byte UBO at group(0) binding(3).
          // Payload (command.zig Encoder.setMorphWeights, 12B): count | idx_ptr | wt_ptr.
          // UBO layout (80 bytes): idx 8×i32 @0 (as 2×vec4i), wt 8×f32 @32 (as 2×vec4),
          // count i32 @64, pad 12 to 80 bytes total.
          const count  = dv.getUint32(off, true);
          const idxPtr = dv.getUint32(off + 4, true);
          const wtPtr  = dv.getUint32(off + 8, true);
          if (!st.morphBuf) st.morphBuf = device.createBuffer({ size: 80, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
          // idx: 8 i32 at offset 0 (pad unused with 0)
          const idx = new Int32Array(8);
          const idxSrc = new Uint32Array(memory.buffer, idxPtr, Math.min(count, 8));
          for (let i = 0; i < Math.min(count, 8); i++) idx[i] = idxSrc[i];
          device.queue.writeBuffer(st.morphBuf, 0, idx.buffer, 0, 32);
          // wt: 8 f32 at offset 32 (pad unused with 0)
          const wt = new Float32Array(8);
          const wtSrc = new Float32Array(memory.buffer, wtPtr, Math.min(count, 8));
          for (let i = 0; i < Math.min(count, 8); i++) wt[i] = wtSrc[i];
          device.queue.writeBuffer(st.morphBuf, 32, wt.buffer, 0, 32);
          // count: i32 at offset 64 (4B, then 12B pad implicit to end of 80B buffer)
          device.queue.writeBuffer(st.morphBuf, 64, new Int32Array([count]).buffer, 0, 4);
          // Invalidate bg0 so the next DRAW_PBR rebuilds it with fresh morphBuf data.
          st.bg0Layout = null;
          break;
        }
        case 30: { // CREATE_MORPH_TEX (WebGPU) — build rgba16float morph-target texture.
          // Payload (command.zig Encoder.createMorphTex, 20B):
          //   handle | width (=vertex_count) | height (=target_count*2) | ptr | byte_len.
          // Source blob (M2 layout, f16): target-major then vertex-major.
          // Per (t, v): 3 f16 POSITION then 3 f16 NORMAL (6 u16 per record).
          // Texture row layout: row 2t = POSITION deltas, row 2t+1 = NORMAL deltas.
          // Repack scatter: texel(v, 2t)   = blob[(t*vertCount + v)*6 + 0..2] (+ 0 alpha)
          //                 texel(v, 2t+1) = blob[(t*vertCount + v)*6 + 3..5] (+ 0 alpha)
          const handle    = dv.getUint32(off, true);
          const vertCount = dv.getUint32(off + 4, true);  // width
          const height    = dv.getUint32(off + 8, true);  // target_count * 2
          const blobPtr   = dv.getUint32(off + 12, true);
          // byte_len at off+16 — informational.
          const targCount = height >>> 1;
          const blob = new Uint16Array(memory.buffer, blobPtr, targCount * vertCount * 6);
          // Repack into RGBA16F row-major: 4 u16 per texel.
          const pixels = new Uint16Array(vertCount * height * 4);
          for (let t = 0; t < targCount; t++) {
            for (let v = 0; v < vertCount; v++) {
              const srcBase = (t * vertCount + v) * 6;
              // POSITION row (row = 2*t)
              const posRow = t * 2;
              const posDst = (posRow * vertCount + v) * 4;
              pixels[posDst + 0] = blob[srcBase + 0];
              pixels[posDst + 1] = blob[srcBase + 1];
              pixels[posDst + 2] = blob[srcBase + 2];
              pixels[posDst + 3] = 0; // alpha pad
              // NORMAL row (row = 2*t+1)
              const nrmRow = t * 2 + 1;
              const nrmDst = (nrmRow * vertCount + v) * 4;
              pixels[nrmDst + 0] = blob[srcBase + 3];
              pixels[nrmDst + 1] = blob[srcBase + 4];
              pixels[nrmDst + 2] = blob[srcBase + 5];
              pixels[nrmDst + 3] = 0; // alpha pad
            }
          }
          const tex = device.createTexture({
            size: [vertCount, height],
            format: "rgba16float",
            usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST,
          });
          device.queue.writeTexture(
            { texture: tex },
            pixels.buffer,
            { bytesPerRow: vertCount * 8, rowsPerImage: height }, // 8 bytes per RGBA16F texel
            [vertCount, height],
          );
          const view = tex.createView();
          st.textures[handle] = { tex, view, w: vertCount, h: height };
          st.morphTexView = view; // active morph texture view for bg0 binding 4
          // Invalidate bg0 so next DRAW_PBR rebuilds with the new texture view.
          st.bg0Layout = null;
          break;
        }

        // ── Point-light shadow atlas (T2, WebGPU) ──────────────────────────
        case 31: { // CREATE_POINT_SHADOW — rgba8unorm atlas + depth scratch texture.
          // Payload (12B): handle | w | h.
          const handle = dv.getUint32(off, true);
          const w = dv.getUint32(off + 4, true);
          const h = dv.getUint32(off + 8, true);
          // rgba8unorm colour atlas (w×h); RENDER_ATTACHMENT for face passes,
          // TEXTURE_BINDING so the receiver can sample it.
          const atlasTex = device.createTexture({
            size: [w, h],
            format: "rgba8unorm",
            usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING,
          });
          // Shared depth scratch (depth16unorm, same footprint as the atlas).
          // One per atlas; each begin_point_shadow_face begins a fresh render pass
          // (clear), so faces don't bleed into each other's depth.
          const depthTex = device.createTexture({
            size: [w, h],
            format: "depth16unorm",
            usage: GPUTextureUsage.RENDER_ATTACHMENT,
          });
          st.pointShadows[handle] = {
            atlasTex,
            atlasView: atlasTex.createView(),
            depthTex,   // kept so teardown can .destroy() both textures
            depthView: depthTex.createView(),
            w, h,
          };
          // Lazily build the point-depth pipeline (once per device).
          if (!st.pointDepthPipe) {
            // Uniform layout (256B stride): face_vp @0 (64B), model @64 (64B),
            //   light_pos @128 (12B), far @140 (4B). Total 144B fits in 256B slot.
            const VERT = GPUShaderStage.VERTEX;
            const FRAG = GPUShaderStage.FRAGMENT;
            const bgl = device.createBindGroupLayout({
              entries: [
                { binding: 0, visibility: VERT | FRAG,
                  buffer: { type: "uniform", hasDynamicOffset: true } },
              ],
            });
            const wgsl = [
              "struct U { face_vp: mat4x4<f32>, model: mat4x4<f32>, light_pos: vec3<f32>, far: f32 }",
              "@group(0) @binding(0) var<uniform> u: U;",
              "struct VOut { @builtin(position) pos: vec4f, @location(0) world: vec3f }",
              "fn packDist(v: f32) -> vec4f {",
              "  var e = fract(v*vec4f(1.0,255.0,65025.0,16581375.0));",
              "  e -= e.yzww*vec4f(1.0/255.0,1.0/255.0,1.0/255.0,0.0);",
              "  return e;",
              "}",
              "@vertex fn vs_main(@location(0) a_pos: vec3f) -> VOut {",
              "  var o: VOut;",
              "  let w = u.model * vec4f(a_pos, 1.0);",
              "  o.world = w.xyz;",
              "  o.pos = u.face_vp * w;",
              "  return o;",
              "}",
              "@fragment fn fs_main(@location(0) world: vec3f) -> @location(0) vec4f {",
              "  return packDist(clamp(length(world - u.light_pos) / u.far, 0.0, 1.0));",
              "}",
            ].join("\n");
            const module = device.createShaderModule({ code: wgsl });
            const layout = device.createPipelineLayout({ bindGroupLayouts: [bgl] });
            const pipeline = device.createRenderPipeline({
              layout,
              vertex: {
                module, entryPoint: "vs_main",
                buffers: [{
                  arrayStride: 48, // PBR stride: pos@0 only used here
                  attributes: [{ shaderLocation: 0, offset: 0, format: "float32x3" }],
                }],
              },
              fragment: {
                module, entryPoint: "fs_main",
                targets: [{ format: "rgba8unorm" }],
              },
              primitive: { topology: "triangle-list", cullMode: "back" },
              depthStencil: {
                format: "depth16unorm",
                depthWriteEnabled: true,
                depthCompare: "less",
              },
            });
            // Uniform buffer: POINT_DEPTH_STRIDE slots (one per draw_point_depth call).
            const POINT_DEPTH_STRIDE = 256;
            const pointDepthUniform = device.createBuffer({
              size: POINT_DEPTH_STRIDE * 384, // 6 faces × 64 submeshes
              usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
            });
            st.pointDepthPipe = { pipeline, bgl, pointDepthUniform,
              POINT_DEPTH_STRIDE, pointDepthSlot: 0,
              // Cached per-face data (written by begin_point_shadow_face).
              faceVp: null, lightPos: null, far: 0 };
          }
          break;
        }
        case 32: { // BEGIN_POINT_SHADOW_FACE — start a render pass for one cube face.
          // Payload (28B): handle | col | row | tile | face_vp_ptr | light_pos_ptr | far_bits.
          // Each face is a separate render pass (clear colour to 1,1,1,1 = far,
          // clear depth). setViewport + setScissorRect restrict to the tile.
          const ps = st.pointShadows[dv.getUint32(off, true)];
          const col  = dv.getUint32(off + 4, true);
          const row  = dv.getUint32(off + 8, true);
          const tile = dv.getUint32(off + 12, true);
          const faceVpPtr   = dv.getUint32(off + 16, true);
          const lightPosPtr = dv.getUint32(off + 20, true);
          const far = dv.getFloat32(off + 24, true); // far_bits reinterpreted as f32
          if (!ps || !st.pointDepthPipe) break;
          // Ensure a command encoder exists (shared with the later colour pass).
          if (!st.encoder) st.encoder = device.createCommandEncoder();
          // Close any previous face pass before opening the next.
          if (st.pointPass) { st.pointPass.end(); st.pointPass = null; }
          // WebGPU: loadOp:"clear" clears the ENTIRE attachment regardless of
          // scissor/viewport. Only the first face (col=0,row=0) should clear —
          // it zeros the whole atlas to (1,1,1,1) = packDist(1) ≈ far. All
          // subsequent faces use "load" so they preserve the already-drawn tiles;
          // setScissorRect + setViewport below restrict each draw to its own tile.
          const isFirstFace = (col === 0 && row === 0);
          st.pointPass = st.encoder.beginRenderPass({
            colorAttachments: [{
              view: ps.atlasView,
              clearValue: { r: 1, g: 1, b: 1, a: 1 }, // 1,1,1,1 = packDist(1) ≈ far
              loadOp: isFirstFace ? "clear" : "load",
              storeOp: "store",
            }],
            depthStencilAttachment: {
              view: ps.depthView,
              depthClearValue: 1.0,
              depthLoadOp: "clear",   // fresh depth per face (tiles don't overlap)
              depthStoreOp: "discard", // depth scratch: no need to preserve
            },
          });
          // Restrict rendering to this face's tile via viewport + scissor.
          st.pointPass.setViewport(col * tile, row * tile, tile, tile, 0, 1);
          st.pointPass.setScissorRect(col * tile, row * tile, tile, tile);
          st.pointPass.setPipeline(st.pointDepthPipe.pipeline);
          // Cache per-face uniforms; they are written per draw in DRAW_POINT_DEPTH.
          st.pointDepthPipe.faceVp    = new Float32Array(memory.buffer, faceVpPtr, 16).slice();
          st.pointDepthPipe.lightPos  = new Float32Array(memory.buffer, lightPosPtr, 3).slice();
          st.pointDepthPipe.far       = far;
          // Reset slot counter at the first face so slots 0..N-1 are face-0, N..2N-1 are face-1, etc.
          // Unique within the frame; resets next frame when face 0 fires again.
          if (isFirstFace) st.pointDepthPipe.pointDepthSlot = 0;
          break;
        }
        case 33: { // DRAW_POINT_DEPTH — draw one mesh into the active face tile.
          // Payload (20B): vbuf | ibuf | index_byte_off | index_count | model_ptr.
          const vb = st.buffers[dv.getUint32(off, true)];
          const ib = st.buffers[dv.getUint32(off + 4, true)];
          const byteOff = dv.getUint32(off + 8, true);
          const count   = dv.getUint32(off + 12, true);
          const modelPtr = dv.getUint32(off + 16, true);
          if (!vb || !ib || !st.pointPass || !st.pointDepthPipe) break;
          const pd = st.pointDepthPipe;
          const slot = pd.pointDepthSlot++;
          const base = slot * pd.POINT_DEPTH_STRIDE;
          // Write face_vp @0 (64B), model @64 (64B), light_pos @128 (12B), far @140 (4B).
          // NOTE: when `data` is a TypedArray, writeBuffer's dataOffset/size are in
          // ELEMENTS, not bytes — so pass the underlying .buffer (ArrayBuffer) with
          // byte offset/size, matching the model/far writes. faceVp / lightPos are
          // .slice() copies so byteOffset = 0.
          device.queue.writeBuffer(pd.pointDepthUniform, base,
            pd.faceVp.buffer, pd.faceVp.byteOffset, 64);
          const modelF32 = new Float32Array(memory.buffer, modelPtr, 16);
          device.queue.writeBuffer(pd.pointDepthUniform, base + 64,
            modelF32.buffer, modelF32.byteOffset, 64);
          device.queue.writeBuffer(pd.pointDepthUniform, base + 128,
            pd.lightPos.buffer, pd.lightPos.byteOffset, 12);
          device.queue.writeBuffer(pd.pointDepthUniform, base + 140,
            new Float32Array([pd.far]).buffer, 0, 4);
          // Bind group with dynamic offset to this slot.
          const bg = device.createBindGroup({
            layout: pd.bgl,
            entries: [{ binding: 0, resource: { buffer: pd.pointDepthUniform,
              offset: 0, size: 144 } }],
          });
          st.pointPass.setBindGroup(0, bg, [base]);
          st.pointPass.setVertexBuffer(0, vb.buf);
          st.pointPass.setIndexBuffer(ib.buf, "uint16", byteOff);
          st.pointPass.drawIndexed(count);
          break;
        }
        case 34: { // END_POINT_SHADOW — close the active face pass.
          // Payload (8B): width | height — unused by WebGPU (no viewport restore needed).
          if (st.pointPass) { st.pointPass.end(); st.pointPass = null; }
          break;
        }
        case 35: { // BIND_POINT_SHADOW — stash the atlas view for the receiver bg1.
          // NEW payload (8B): slot | handle. Multi-caster: the per-caster lpos/far
          // uniforms are gone (Task 1) — the receiver reads them from the per-light
          // loop vars, so we only stash the atlas view for group(1) binding 11.
          const ps = st.pointShadows[dv.getUint32(off + 4, true)];
          if (ps) {
            st.pointAtlasView = ps.atlasView;
          }
          st.bg1Dirty = true; // trigger bg1 rebuild before next DRAW_PBR
          break;
        }

        default:
          break; // unknown tag: size-skip = forward compatible
      }
      off += size;
    }
    return total;
  };

  // WebGPU device bootstrap. Feature-detects navigator.gpu, requests an
  // adapter + device, and configures the canvas' "webgpu" context with the
  // preferred format. Degrades gracefully: returns null (never throws) on any
  // missing capability or async failure so the WebGL2 path stays the fallback.
  const gpuInit = async (canvas) => {
    try {
      if (typeof navigator === "undefined" || !navigator.gpu) return null;
      const adapter = await navigator.gpu.requestAdapter();
      if (!adapter) return null;
      const device = await adapter.requestDevice();
      const ctx = canvas.getContext("webgpu");
      if (!ctx) return null;
      const format = navigator.gpu.getPreferredCanvasFormat();
      ctx.configure({ device, format, alphaMode: "opaque" });
      return { device, ctx, format };
    } catch (err) {
      console.warn("verve.gl: WebGPU init failed:", err);
      return null;
    }
  };

  // Asset-loader worker: lazily-spawned same-origin module worker that fetches +
  // (passthrough) decodes a gl asset off the main thread and transfers the bytes
  // back. gl_load prefers it and falls back to a main-thread fetch if the worker is
  // unavailable / CSP-blocked / errors. Decode runs in the worker (hook for future
  // compressed formats); the wasm-memory copy stays on the main thread.
  let assetWorker = null;
  let assetWorkerDead = false;
  let assetReqId = 0;
  const assetPending = new Map(); // id -> { resolve, reject }
  const assetWorkerLoad = (url) => {
    if (assetWorkerDead || typeof Worker === "undefined") {
      return Promise.reject(new Error("no worker"));
    }
    if (!assetWorker) {
      try {
        assetWorker = new Worker("/verve-worker.js", { type: "module" });
        assetWorker.onmessage = ({ data }) => {
          const p = assetPending.get(data.id);
          if (!p) return;
          assetPending.delete(data.id);
          if (data.ok) p.resolve(data.buffer);
          else p.reject(new Error(data.err || "worker error"));
        };
        assetWorker.onerror = () => {
          assetWorkerDead = true;
          for (const p of assetPending.values()) p.reject(new Error("worker crashed"));
          assetPending.clear();
        };
      } catch (e) {
        assetWorkerDead = true;
        return Promise.reject(e);
      }
    }
    const id = ++assetReqId;
    return new Promise((resolve, reject) => {
      assetPending.set(id, { resolve, reject });
      assetWorker.postMessage({ id, url });
    });
  };

  const glStart = (refHandle, exportName) => {
    const canvas = refHandles[refHandle];
    const exports = glActiveChunkExports;
    if (!canvas || !exports || typeof exports[exportName] !== "function") {
      console.error("verve.gl: glStart cannot resolve canvas/export:", exportName);
      return;
    }
    const ctx = canvas.getContext("webgl2", { antialias: true });
    if (!ctx) {
      // No GL context was created, so no context-loss listeners are needed and
      // there is nothing to dispose. The SSR poster is visible by default —
      // leave it up so the user sees the static frame instead of a blank canvas.
      console.error("verve.gl: WebGL2 unavailable; canvas left inert");
      return;
    }
    const st = {
      gl: ctx,
      exports,
      exportName,
      buffers: [],
      shaders: [],
      textures: [],
      shadowMaps: [], // P9 slice 3: { fbo, tex, size } per handle
      renderTargets: [], // post-processing: { fbo, colorTex, depthTex, w, h } per handle
      pointShadows: [], // T2: { fbo, tex, depth, w, h } per handle (RGBA8 atlas + depth RBO)
      pointDepthProg: null, // lazy — compiled on first CREATE_POINT_SHADOW (case 31)
      vaos: new Map(),
      emptyVao: null, // lazy-created VAO for fullscreen-quad draw (case 25)
      instanceBuf: null, // lazy-created ARRAY_BUFFER for per-instance mat4+color (case 27)
      morphTextures: [], // morph-target RGBA16F textures (case 30), indexed by handle
      morphTex: null, // active morph texture bound to TEXTURE9 (most recently created)
      extColorBufferFloat: null, // EXT_color_buffer_float, enabled on first rgba16f target
      frameAreaCount: 0, // S3 area lights: active count (set_area_lights, tag 37; 0 = none)
      frameAreaLights: null, // S3: Float32Array(count*16) area_lights[] cached per frame
      ltcMat: null, // S3: ltc_mat 64×64 rgba16f LUT (fetched from /gl/ltc.bin once)
      ltcMag: null, // S3: ltc_mag 64×64 rgba16f LUT
      ltcDummy: null, // S3: 1×1 rgba16f dummy bound to units 10/11 by default
      ltcLoading: false, // S3: guards the one-shot /gl/ltc.bin fetch
      active: null,
      last: 0,
      // Poster swap: SSR may drop an <img data-gl-poster> sibling under the
      // canvas's parent. Looked up once on first non-empty frame, then cached.
      poster: undefined, // undefined = not yet looked up; null = none present
      posterHidden: false,
      // Context loss: true between webglcontextlost and webglcontextrestored.
      // While lost, the rAF loop is fully stopped (no idle polling); the
      // restored handler resets resource state and restarts it.
      lost: false,
      // P7: this canvas's GlScene instance vid — selected before each frame so
      // the chunk renders THIS instance's state. 0 for single-instance chunks.
      vid: vidOfEl(canvas),
    };
    // Sink driven by the master anim rAF (animTick) — see glSinks. Same body
    // as the old self-rescheduling step(), except stop paths remove the sink
    // from glSinks instead of skipping a requestAnimationFrame(step) self-call.
    const sink = (now) => {
      // Context lost: the GL objects are gone and any GL call would error.
      // Stop the loop entirely; webglcontextrestored restarts it. (Chosen over
      // idle polling: zero work while suspended, single clear resume point.)
      if (st.lost) {
        glSinks.delete(sink);
        return;
      }
      // Island unmounted: canvas detached from the DOM. Free GPU objects and
      // stop without rescheduling, instead of leaking the whole resource set.
      if (!canvas.isConnected) {
        // Reclaim the chunk-side instance slot (P7) before tearing down GPU
        // state, so add/remove cycles don't exhaust the pool. No-op for
        // single-instance chunks (no glscene_unmount export).
        if (typeof st.exports.glscene_unmount === "function")
          st.exports.glscene_unmount(st.vid >>> 0);
        disposeGlState(st);
        glSinks.delete(sink);
        return;
      }
      const dt = st.last ? now - st.last : 16.7;
      st.last = now;
      const dpr = window.devicePixelRatio || 1;
      // Clamp the backing store: an unstyled canvas would otherwise feed its
      // own attribute size back through clientWidth and grow exponentially
      // (the canvas CSS is the real fix; this caps the damage if it's missing).
      const w = Math.min(4096, Math.max(1, Math.round(canvas.clientWidth * dpr)));
      const h = Math.min(4096, Math.max(1, Math.round(canvas.clientHeight * dpr)));
      if (canvas.width !== w) canvas.width = w;
      if (canvas.height !== h) canvas.height = h;
      // P7: select this canvas's instance before the frame export reads state.
      glSelect(st.exports, st.vid);
      const ptr = st.exports[st.exportName](dt, w, h) >>> 0;
      if (!ptr) {
        // wasm asked to stop (island unmount path, P4). 0 = stop loop; per spec
        // this is the unmount signal, so tear down GPU state rather than just
        // halting and leaking. Frame exports that always return a pointer are
        // unaffected.
        disposeGlState(st);
        glSinks.delete(sink);
        return;
      }
      try {
        const drawn = glInterpret(st, ptr);
        // First successful non-empty frame: hide the SSR poster (the real
        // scene is now on the canvas). Lookup is done once and cached.
        if (drawn && !st.posterHidden) {
          if (st.poster === undefined) {
            st.poster = (canvas.parentElement &&
              canvas.parentElement.querySelector("[data-gl-poster]")) || null;
          }
          if (st.poster) st.poster.style.display = "none";
          st.posterHidden = true;
        }
        // T3: cull HUD — only present on /gl-cull; no-op on all other demos.
        glCullHudUpdate(st.exports);
      } catch (err) {
        // A corrupt stream/pointer must not kill the loop silently.
        console.error("verve.gl: interpreter fault, loop stopped:", err, err && err.stack);
        glSinks.delete(sink);
        return;
      }
    };
    // preventDefault is REQUIRED — without it the browser never fires
    // webglcontextrestored, leaving the canvas permanently dead.
    canvas.addEventListener("webglcontextlost", (e) => {
      e.preventDefault();
      st.lost = true;
      // Drop the sink immediately (the st.lost bail also self-removes, but
      // only if the master tick happens to run before restore).
      glSinks.delete(sink);
      // Bring the static poster back while the GPU recovers.
      if (st.poster) {
        st.poster.style.display = "";
        st.posterHidden = false;
      }
    });
    canvas.addEventListener("webglcontextrestored", () => {
      // The GL objects died with the old context; drop our handles WITHOUT
      // calling gl.delete* (deleting names from a dead context errors / is a
      // no-op). disposeGlState is deliberately NOT used here for that reason.
      st.buffers = [];
      st.textures = [];
      st.shaders = [];
      st.vaos.clear();
      st.active = null;
      // S3 LTC: the LUT/dummy textures died with the context — drop the handles +
      // reset the fetch guard so they re-create/re-fetch against the new context.
      st.ltcMat = null;
      st.ltcMag = null;
      st.ltcDummy = null;
      st.ltcLoading = false;
      // Re-hide poster only after the first new frame draws again.
      st.posterHidden = false;
      st.lost = false;
      st.last = 0;
      // Let the chunk re-upload GPU resources before frames resume, if it
      // exports a restore hook. Convention: "<frame_export>_restore" (Task 10/12).
      glSelect(st.exports, st.vid); // P7: restore THIS instance's resources
      const restoreFn = st.exports[st.exportName + "_restore"];
      if (typeof restoreFn === "function") restoreFn();
      // st.last was reset to 0 above, so the first resumed frame uses the
      // fixed 16.7 ms dt instead of the whole lost-context gap.
      glSinks.add(sink);
      tickerKick();
    });
    glSinks.add(sink);
    tickerKick();
  };

  // WebGPU frame loop — parallel to glStart but kept SEPARATE. Driven by the
  // same master rAF (glSinks). Slice 1: no context-loss / poster-swap handling.
  const gpuStart = async (refHandle, exportName) => {
    const canvas = refHandles[refHandle];
    const exports = glActiveChunkExports;
    if (!canvas || !exports || typeof exports[exportName] !== "function") {
      console.error("verve.gl: gpuStart cannot resolve canvas/export:", exportName);
      return;
    }
    const gpu = await gpuInit(canvas);
    if (!gpu) {
      // Leave the SSR poster up — do NOT throw.
      console.warn("verve.gl: WebGPU unavailable; canvas left inert");
      return;
    }
    const st = {
      device: gpu.device,
      ctx: gpu.ctx,
      format: gpu.format,
      exports,
      exportName,
      buffers: [],
      pipelines: [],
      textures: [],
      boundTex: [],
      ibl: null, // { irr, spec, lut } texture handles set by bind_ibl (2b)
      shadowMaps: [], // { tex, view, sampler, size } by handle (create_shadow_map, 2c)
      shadow: null, // { handle } (2D atlas) set by bind_shadow_map
      frameShadowVp: null, // Float32Array(count*16) shadow_vp[] cached by bind_shadow_map
      frameShadowVpCount: 0, // number of 2D casters in frameShadowVp
      frameCascadeCount: 0, // CSM: active cascade count (set_csm, tag 36; 0 = no CSM)
      frameCascadeSplits: null, // CSM: Float32Array(4) view-space FAR per cascade
      frameViewForward: null, // CSM: Float32Array(3) normalized camera look dir
      frameAreaCount: 0, // S3 area lights: active count (set_area_lights, tag 37; 0 = none)
      frameAreaLights: null, // S3: Float32Array(count*16) area_lights[] cached per frame
      ltcMat: null, // S3: ltc_mat 64×64 rgba16f LUT (bridge fetches /gl/ltc.bin once)
      ltcMag: null, // S3: ltc_mag 64×64 rgba16f LUT
      ltcLoading: false, // S3: guards the one-shot /gl/ltc.bin fetch
      pointShadows: [], // T2: { atlasTex, atlasView, depthView, w, h } by handle
      pointDepthPipe: null, // lazy — pipeline + uniform buf for point-depth pass
      pointPass: null, // active render pass during begin/end_point_shadow_face
      pointAtlasView: null, // stashed by bind_point_shadow (tag 35) for bg1 binding 11
      renderTargets: [], // post: { tex, view, depthTex, depthView, w, h, format } by handle
      curTargetFormat: null, // color format of the active pass (post pipeline keying)
      curPassHasDepth: false, // true when the active render pass has a depth attachment
      postUniform: null, // slotted params buffer for draw_fullscreen_quad (lazy)
      postSlot: 0, // per-frame fullscreen-draw slot counter (reset at encoder start)
      // Linear/clamp sampler + 1×1 dummy view for the unused tex1 post slot. Eager
      // (cheap, always needed by the post chain when present); clamp avoids UV wrap.
      linearSampler: gpu.device.createSampler({
        magFilter: "linear", minFilter: "linear",
        addressModeU: "clamp-to-edge", addressModeV: "clamp-to-edge",
      }),
      dummyTexView: (() => {
        const t = gpu.device.createTexture({
          size: [1, 1], format: "rgba8unorm",
          usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST,
        });
        gpu.device.queue.writeTexture({ texture: t }, new Uint8Array([0, 0, 0, 255]), { bytesPerRow: 4, rowsPerImage: 1 }, [1, 1]);
        return t.createView();
      })(),
      shadowPass: null, // active depth render pass during begin/end_shadow_pass
      defaults: gpuMakeDefaults(gpu.device),
      active: null,
      encoder: null,
      pass: null,
      uniformBuf: null,
      bindGroup: null,
      instanceBuf: null, // lazy GPUBuffer (VERTEX|COPY_DST) for per-instance mat4+color (case 27)
      fogBuf: null, // lazy 32-byte UBO (UNIFORM|COPY_DST) for distance fog (case 28/binding 2)
      morphBuf: null, // lazy 80-byte UBO (UNIFORM|COPY_DST) for morph weights (case 29/binding 3)
      morphTexView: null, // GPUTextureView for morph-target data texture (case 30/binding 4)
      pbrUniform: null, // shared PBR uniform buffer (lazy; PBR_U.size bytes)
      bonesBuf: null, // shared bones palette uniform (lazy; 64 mat4) — skinned
      depthUniform: null, // shadow depth-pass uniform (lazy; one mat4)
      depthBindGroup: null, // cached depth-pass bind group (2c)
      depthAtUniform: null, // depth-at (MASK cutout) uniform (lazy; mvp+material)
      depthAtSlot: 0, // per-pass depth-at draw counter (reset at begin_shadow_pass)
      bg0: null, // cached group(0) bind group (uniform)
      bg0Layout: null,
      bg1: null, // cached group(1) bind group (sampler + textures)
      bg1Layout: null,
      bg1Dirty: true, // rebuild group(1) on first draw / after bind_texture
      depthTex: null,
      depthView: null,
      lastW: 0,
      lastH: 0,
      last: 0,
      pbrSlot: 0, // per-frame draw counter (also gates the poster swap below)
      poster: undefined, // SSR <img data-gl-poster>; undefined=unlooked, null=none
      posterHidden: false,
      // P11: this canvas's GlScene instance vid — selected before each frame so
      // the chunk renders THIS instance's state (mirrors glStart). 0 = single.
      vid: vidOfEl(canvas),
      lost: false, // P11: true between device.lost and a successful re-init
    };
    const sink = (now) => {
      // Device lost: the GPU objects are gone; stop the loop. The device.lost
      // handler (armDeviceLost) drives recovery and re-adds the sink.
      if (st.lost) {
        glSinks.delete(sink);
        return;
      }
      // Island unmounted: canvas detached. Reclaim the chunk instance slot (P7)
      // then stop without rescheduling. GPU objects are GC'd (no WebGL-style
      // dispose needed); the unmount keeps the chunk's instance pool from leaking.
      if (!canvas.isConnected) {
        if (typeof st.exports.glscene_unmount === "function") st.exports.glscene_unmount(st.vid >>> 0);
        glSinks.delete(sink);
        return;
      }
      const dt = st.last ? now - st.last : 16.7;
      st.last = now;
      const dpr = window.devicePixelRatio || 1;
      const w = Math.min(4096, Math.max(1, Math.round(canvas.clientWidth * dpr)));
      const h = Math.min(4096, Math.max(1, Math.round(canvas.clientHeight * dpr)));
      if (canvas.width !== w) canvas.width = w;
      if (canvas.height !== h) canvas.height = h;
      // P11: select this canvas's instance before the frame export reads state.
      glSelect(st.exports, st.vid);
      const ptr = st.exports[st.exportName](dt, w, h) >>> 0;
      if (!ptr) {
        // wasm asked to stop. 0 = stop loop.
        glSinks.delete(sink);
        return;
      }
      try {
        gpuInterpret(st, ptr);
        // T3: cull HUD — only present on /gl-cull; no-op on all other demos.
        glCullHudUpdate(st.exports);
      } catch (err) {
        console.error("verve.gl: WebGPU interpreter fault, loop stopped:", err);
        glSinks.delete(sink);
        return;
      }
      // First frame that actually drew geometry: hide the SSR poster (the real
      // scene is now on the canvas). Clear-only frames (assets still loading)
      // leave pbrSlot at 0, so the poster stays up until the scene renders.
      if (st.pbrSlot > 0 && !st.posterHidden) {
        if (st.poster === undefined) {
          st.poster = (canvas.parentElement &&
            canvas.parentElement.querySelector("[data-gl-poster]")) || null;
        }
        if (st.poster) st.poster.style.display = "none";
        st.posterHidden = true;
      }
    };
    // P11 device-loss/restore (mirrors WebGL2 webglcontextlost/restored). WebGPU
    // device loss can't be triggered headless, so this is structural: on a real
    // loss, re-init a fresh device, drop the dead resource refs (NOT .destroy() —
    // invalid on a lost device), and let the chunk's `<frame>_restore` hook replay
    // its create* commands (registry replay). Graceful: poster stays up if re-init
    // fails. The no-loss path is untouched.
    const resetGpuResourcesForRestore = () => {
      st.buffers = [];
      st.pipelines = [];
      st.textures = [];
      st.boundTex = [];
      st.shadowMaps = [];
      st.ibl = null;
      st.shadow = null;
      st.instanceBuf = null; // GPU vertex buffer for per-instance data (no .destroy — dead device)
      if (st.fogBuf) { st.fogBuf.destroy?.(); st.fogBuf = null; }
      if (st.morphBuf) { st.morphBuf.destroy?.(); st.morphBuf = null; }
      // Destroy point-shadow atlas textures before dropping references.
      for (const ps of st.pointShadows) {
        if (ps) { ps.atlasTex?.destroy(); ps.depthTex?.destroy(); }
      }
      st.pointShadows = [];
      if (st.pointDepthPipe) { st.pointDepthPipe.pointDepthUniform?.destroy(); st.pointDepthPipe = null; }
      st.pointPass = null;
      st.pointAtlasView = null;
      st.frameShadowVp = null;
      st.frameShadowVpCount = 0;
      // S3 LTC: drop the LUT textures + reset the fetch guard so they re-fetch on
      // the next bind_ltc_lut against the new device.
      st.ltcMat = null;
      st.ltcMag = null;
      st.ltcLoading = false;
      // Multi-caster: pointShadowBuf (dead bg0 binding 5) removed — nothing to destroy.
      st.morphTexView = null;
      st.pbrUniform = null;
      st.bonesBuf = null;
      st.uniformBuf = null; // slice-1 basic-draw path's persistent buffer
      st.bindGroup = null;
      st.depthUniform = null;
      st.depthBindGroup = null;
      st.depthAtUniform = null;
      st.bg0 = null;
      st.bg0Layout = null;
      st.bg1 = null;
      st.bg1Layout = null;
      st.bg1Dirty = true;
      st.depthTex = null;
      st.depthView = null;
      st.encoder = null;
      st.pass = null;
      st.shadowPass = null;
      st.lastW = 0;
      st.lastH = 0;
      st.last = 0;
    };
    const armDeviceLost = () => {
      st.device.lost.then(async (info) => {
        if (info && info.reason === "destroyed") return; // intentional teardown
        st.lost = true;
        glSinks.delete(sink);
        if (st.poster) {
          st.poster.style.display = "";
          st.posterHidden = false;
        }
        const g2 = await gpuInit(canvas);
        if (!g2) {
          console.warn("verve.gl: WebGPU device lost; recovery failed, poster left up");
          return;
        }
        st.device = g2.device;
        st.ctx = g2.ctx;
        st.format = g2.format;
        st.defaults = gpuMakeDefaults(g2.device);
        resetGpuResourcesForRestore();
        st.lost = false;
        glSelect(st.exports, st.vid);
        const restoreFn = st.exports[st.exportName + "_restore"];
        if (typeof restoreFn === "function") restoreFn();
        armDeviceLost(); // re-arm on the fresh device
        glSinks.add(sink);
        tickerKick();
      });
    };
    armDeviceLost();
    glSinks.add(sink);
    tickerKick();
  };

  // One-shot fetch routed to an island export: `{api, island, export}` POSTs
  // `/api/<api>` and delivers the reply text to the named export. This is the
  // push path's resync hook, reusable by any island.
  window.verveHost.verveFetchExport = (argsJson) => {
    let a = {};
    try {
      // `verve_host_call` hands these a parsed object; a JS caller may pass a
      // JSON string. Tolerate both — JSON.parse on an object throws.
      a = typeof argsJson === "string" ? JSON.parse(argsJson || "{}") : argsJson || {};
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
          verve: {
            gl_start: (refHandle, namePtr, nameLen) =>
              glStart(refHandle, readStr(namePtr, nameLen)),
            // P10: WebGPU frame loop. Fire-and-forget (gpuStart is async).
            gl_start_gpu: (refHandle, namePtr, nameLen) =>
              gpuStart(refHandle, readStr(namePtr, nameLen)),
            // P10 slice 2d: synchronous backend feature-detect. The chunk calls
            // this at hydrate to choose WGSL + gl_start_gpu (1) vs GLSL +
            // gl_start (0). gpuInit still degrades gracefully if the async
            // adapter/device request later fails.
            gl_webgpu_available: () => (navigator.gpu ? 1 : 0),
            // P8 onPickExport: dispatch a bubbling DOM CustomEvent from the
            // canvas (resolved by ref handle). detail.name carries the picked
            // submesh name. No-op if the handle is stale.
            gl_emit_event: (refHandle, namePtr, nameLen, detailPtr, detailLen) => {
              const el = refHandles[refHandle];
              if (!el) return;
              const name = readStr(namePtr, nameLen);
              const detail = readStr(detailPtr, detailLen);
              el.dispatchEvent(
                new CustomEvent(name, { bubbles: true, detail: { name: detail } }),
              );
            },
            gl_load: (urlPtr, urlLen, cbPtr, cbLen) => {
              const url = readStr(urlPtr, urlLen);
              const cb = readStr(cbPtr, cbLen);
              const exports = glActiveChunkExports;
              // P7: the fetch resolves async, after other instances may have
              // hydrated/rendered. Capture the requesting instance's vid NOW
              // (this gl_load runs synchronously inside that instance's hydrate)
              // and re-select it before delivering the callback.
              const reqVid = glHydratingVid || glCurrentVid;
              const deliver = (a, b) => {
                glSelect(exports, reqVid);
                exports[cb](a, b);
              };
              if (!exports || typeof exports[cb] !== "function") {
                // No callback to deliver failure to — the callback IS what's
                // missing (typo'd export name = programmer error). The chunk
                // degrades to its no-asset frames, per the spec's poster
                // fallback policy.
                console.error("verve.gl: gl_load callback missing:", cb);
                return;
              }
              // Alloc in the page-scoped asset region (MAIN client `exp`, not the
              // chunk), copy the bytes into shared wasm memory, deliver the ptr.
              // 16-byte alignment kept: Uint16Array views need >=2 and .venv
              // internal offsets are 16-aligned. (Copy stays main-thread — the
              // worker has its own memory.)
              const onBytes = (bytes) => {
                const ptr = typeof exp.verve_asset_alloc === "function"
                  ? exp.verve_asset_alloc(bytes.length >>> 0, 16)
                  : 0;
                if (!ptr) {
                  console.error("verve.gl: asset region full for", url);
                  deliver(0, 0);
                  return;
                }
                new Uint8Array(memory.buffer, ptr, bytes.length).set(bytes);
                deliver(ptr, bytes.length >>> 0);
              };
              const isImageUrl = (u) => /\.(png|jpe?g|webp)$/i.test(u);
              const decodeImageMain = async (ab) => {
                const bm = await createImageBitmap(new Blob([ab]));
                const c = new OffscreenCanvas(bm.width, bm.height);
                const cx = c.getContext("2d");
                cx.drawImage(bm, 0, 0);
                const px = cx.getImageData(0, 0, bm.width, bm.height).data;
                const out = new Uint8Array(8 + px.length);
                const dv = new DataView(out.buffer);
                dv.setUint32(0, bm.width, true);
                dv.setUint32(4, bm.height, true);
                out.set(px, 8);
                bm.close();
                return out;
              };
              const mainThreadFetch = () => {
                fetch(url)
                  .then((r) => {
                    if (!r.ok) throw new Error("HTTP " + r.status);
                    return r.arrayBuffer();
                  })
                  .then((ab) =>
                    isImageUrl(url) ? decodeImageMain(ab) : new Uint8Array(ab),
                  )
                  .then((bytes) => onBytes(bytes))
                  .catch((err) => {
                    console.error("verve.gl: asset fetch failed:", url, err);
                    deliver(0, 0);
                  });
              };
              // Prefer the asset worker; fall back to a main-thread fetch on any
              // worker failure (unavailable / CSP-blocked / crashed / fetch error).
              assetWorkerLoad(url).then(
                (ab) => onBytes(new Uint8Array(ab)),
                () => mainThreadFetch(),
              );
            },
          },
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
    // P7: the chunk's hydrate self-selects from its root_id arg, but any
    // gl_load it kicks captures this vid for its async callback. Reset in the
    // finally so a stray later gl_load can't mis-route.
    glHydratingVid = instanceId;
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
        glSetActiveChunk(cexp);
        cexp.hydrate(ptr, propsBytes.length, instanceId);
      } else {
        glSetActiveChunk(cexp);
        cexp.hydrate(0, 0, instanceId);
      }
    } finally {
      if (scope && typeof exp.verve_exit_island === "function") exp.verve_exit_island();
      glHydratingVid = 0;
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
  // Smoother FIRST (wrapper must be fixed + spacer sized before trigger
  // geometry measures), then SplitText line grouping (animations
  // targeting .st-line resolve targets at create), then declarative
  // animations and draggables.
  smootherScan(document.body);
  splitLinesScan(document.body);
  animScan(document.body);
  dragScan(document.body);

  new MutationObserver((records) => {
    for (const rec of records) {
      rec.removedNodes.forEach((n) => eachIslandIn(n, unmountIslandEl));
      rec.addedNodes.forEach((n) => {
        eachIslandIn(n, hydrateIslandEl);
        // New subtrees (Suspense swaps, SPA navigations, template
        // clones) may carry their own [data-split-lines]/[data-anim]/
        // [data-drag] markers. Lines group BEFORE animations resolve.
        if (n instanceof Element) {
          smootherScan(n);
          splitLinesScan(n);
          animScan(n);
          dragScan(n);
        }
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
