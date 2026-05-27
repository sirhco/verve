// Verve desktop bridge — fork of src/bridge/verve.js with server-only
// paths stripped (no /api, /ws, /events, /islands, SPA router, suspense).
// Loaded by the SSR-rendered <head>; fetches and instantiates the WASM
// client served at verve://app/client.wasm.

(async () => {
  let memory = null;
  const readStr = (ptr, len) =>
    new TextDecoder().decode(new Uint8Array(memory.buffer, ptr, len));

  // NodeRef handles. Index 0 = sentinel for "not found".
  const refHandles = [null];

  const setTextByBind = (bind, text) => {
    document
      .querySelectorAll(`[z-bind="${CSS.escape(bind)}"]`)
      .forEach((el) => {
        el.textContent = text;
      });
  };

  const eachBind = (bind, fn) => {
    document.querySelectorAll(`[z-bind="${CSS.escape(bind)}"]`).forEach(fn);
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
      set_text_by_bind_f32: (bp, bl, v) =>
        eachBind(readStr(bp, bl), (el) => {
          el.textContent = String(v);
        }),
      set_text_by_bind_str: (bp, bl, tp, tl) =>
        eachBind(readStr(bp, bl), (el) => {
          el.textContent = readStr(tp, tl);
        }),
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
      set_class_present_by_bind: (bp, bl, cp, cl, on) => {
        const cls = readStr(cp, cl);
        eachBind(readStr(bp, bl), (el) =>
          on ? el.classList.add(cls) : el.classList.remove(cls),
        );
      },
      set_value_by_bind: (bp, bl, vp, vl) =>
        eachBind(readStr(bp, bl), (el) => {
          el.value = readStr(vp, vl);
        }),
      remove_by_bind: (bp, bl) =>
        eachBind(readStr(bp, bl), (el) => el.remove()),

      // ---- Keyed-list reconciler primitives (ported from src/bridge/verve.js) ----
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

      // ---- Server-fn / typed POST externs routed through the IPC channel ----
      //
      // Desktop apps have no HTTP `/api/<name>` endpoint — the
      // equivalent of an `Action.post(args)` is a fire-and-forget IPC
      // message dispatched to a route registered in `src/handlers.zig`.
      // Translate the externs so wasm-side code written against the
      // web `server_fn_post` / `post_json_i32` contract Just Works.
      //
      // The IPC router expects each route's `Args` type to match the
      // JSON payload shape. Schema drift surfaces as a parse failure
      // in the matching route handler.
      server_fn_post: (np, nl, bp, bl) => {
        const name = readStr(np, nl);
        const body = readStr(bp, bl);
        let args = {};
        try {
          args = body.length > 0 ? JSON.parse(body) : {};
        } catch (err) {
          console.error("verve server_fn_post: invalid JSON body:", err);
          return;
        }
        try {
          window.verve.send(Object.assign({ type: name }, args));
        } catch (err) {
          console.error("verve server_fn_post failed:", err);
        }
      },
      post_json_i32: (pp, pl, fp, fl, v) => {
        const path = readStr(pp, pl);
        const field = readStr(fp, fl);
        // Web semantics: POST `/api/<name>` with `{<field>: <i32>}`.
        // Desktop translation: strip a leading `/api/` segment and use
        // the remainder as the IPC route type. Paths without that prefix
        // are dispatched verbatim (lets callers reach non-/api routes too).
        const route = path.startsWith("/api/") ? path.slice(5) : path;
        try {
          window.verve.send({ type: route, [field]: v | 0 });
        } catch (err) {
          console.error("verve post_json_i32 failed:", err);
        }
      },

      // ---- NodeRef resolution -----------------------------------------
      // Same shape as the web bridge: map `data-ref="<id>"` to a JS-
      // owned Element handle (index 0 = not found).
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

      console_log_i32: (v) => console.log("verve:", v | 0),
    },
  };

  // Exposed for hand-written JS that wants to round-trip a NodeRef.id
  // without going through wasm.
  window.verveQueryRef = (id) =>
    document.querySelector(`[data-ref="${CSS.escape(String(id))}"]`);

  // WKWebView under a custom scheme can be picky about
  // WebAssembly.instantiateStreaming. Fall back to a buffered instantiate
  // when streaming rejects the response (typically a Content-Type quirk).
  let wasm;
  try {
    const resp = await fetch("verve://app/client.wasm");
    if (WebAssembly.instantiateStreaming) {
      try {
        wasm = await WebAssembly.instantiateStreaming(resp, env);
      } catch (streamErr) {
        console.warn("verve: instantiateStreaming failed, falling back:", streamErr);
        const buf = await (await fetch("verve://app/client.wasm")).arrayBuffer();
        wasm = await WebAssembly.instantiate(buf, env);
      }
    } else {
      const buf = await resp.arrayBuffer();
      wasm = await WebAssembly.instantiate(buf, env);
    }
  } catch (err) {
    console.error("verve: WASM load failed:", err);
    return;
  }

  memory = wasm.instance.exports.memory;
  const exp = wasm.instance.exports;

  // Seed wasm state from server-rendered DOM. Each `verve_init_<bind>`
  // export is matched to `[z-bind="<bind>"]` and called with the parsed
  // i32 text content.
  for (const name of Object.keys(exp)) {
    const m = /^verve_init_(.+)$/.exec(name);
    if (!m || typeof exp[name] !== "function") continue;
    const el = document.querySelector(`[z-bind="${CSS.escape(m[1])}"]`);
    if (!el) continue;
    const n = parseInt(el.textContent, 10);
    if (!Number.isNaN(n)) exp[name](n | 0);
  }

  if (typeof exp.verve_hydrate === "function") exp.verve_hydrate();

  // Deep-link receiver. The native side calls `window.verve.handleDeepLink(url)`
  // via evalJs when a verve://... URL arrives — either through the
  // macOS AppleEventManager handler (warm + cold) or the Win/Linux
  // argv path (cold-launch only). Replace the default with your own
  // assignment if you want a different UI.
  window.verve.handleDeepLink = (url) => {
    const el = document.getElementById("deep-link-url");
    if (el) el.textContent = url;
    console.log("verve: deep-link", url);
  };

  // Closure-style event dispatch. Looks for `z-on-<event>-id="<n>"`
  // on the closest ancestor of `e.target`, parses the slot id, and
  // calls `verve_event_dispatch(id)` — the runtime invokes the fn
  // pointer registered via `verve.registerEvent(...)`. Returns true
  // when a handler ran so the caller can decide whether to also fall
  // through to other dispatch paths.
  const dispatchEventId = (e, attr, prevent) => {
    const node = e.target.closest(`[${attr}]`);
    if (!node) return false;
    const id = parseInt(node.getAttribute(attr), 10);
    if (!Number.isFinite(id)) return false;
    if (typeof exp.verve_event_dispatch !== "function") return false;
    if (prevent) e.preventDefault();
    exp.verve_event_dispatch(id >>> 0);
    return true;
  };

  // Delegated click handler. Two flavors coexist:
  //
  //   [z-on-click="<name>"]   → string-name dispatch; calls `exp[name]()`.
  //   [z-on-click-id="<id>"]  → closure dispatch; calls
  //                             `exp.verve_event_dispatch(parseInt(id, 10))`.
  //
  // The id form runs the fn pointer registered via
  // `verve.registerEvent(...)` in the wasm runtime — handler keeps the
  // state it captured at registration. Both forms can appear on the
  // same node; id wins if both are stamped.
  document.addEventListener("click", (e) => {
    if (dispatchEventId(e, "z-on-click-id", true)) return;
    const target = e.target.closest("[z-on-click]");
    if (!target) return;
    const action = target.getAttribute("z-on-click");
    const fn = exp[action];
    if (typeof fn === "function") {
      e.preventDefault();
      fn();
    } else {
      console.warn("verve: no wasm export for action", action);
    }
  });

  // Delegated submit / input / change / keydown. Same dispatch model
  // as click-id — handler is `fn () void`; reads incoming state via
  // `verve.refValueI32` / `refValueF32` against a co-stamped NodeRef.
  // Submit gets `preventDefault()` so the native form post doesn't
  // fire; input / change / keydown do NOT, so the native input still
  // updates and the handler runs alongside it.
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

  // ---- Level-3 smoke driver ---------------------------------------------
  // The Zig main.zig --smoke flag loads the page as `index.html?smoke=1`
  // so we don't need an extra global / build-time flag. After hydration
  // we drive a deterministic interaction sequence, compute a checksum
  // of the resulting DOM text, and call the smoke_done IPC route. The
  // Zig handler then captures a PNG snapshot, writes the checksum, and
  // terminates the app so the build step can diff against goldens.
  if (location.search.includes("smoke=1")) {
    const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
    (async () => {
      try {
        await sleep(300);
        document.getElementById("ping")?.click();
        document
          .querySelector('[z-on-click="increment_counter"]')
          ?.click();
        await sleep(300);
        const checksum = document.body.innerText.length;
        await window.verve.request({ type: "smoke_done", checksum: checksum });
      } catch (err) {
        console.error("smoke driver failed:", err);
      }
    })();
  }
})();
