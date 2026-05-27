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
      server_fn_post: (np, nl, bp, bl) => {
        const name = readStr(np, nl);
        const body = readStr(bp, bl);
        fetch(`/api/${name}`, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body,
        }).catch((err) => console.error("verve server_fn_post failed:", err));
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
    },
  };

  // Exposed for hand-written JS that wants to round-trip a NodeRef.id
  // without going through wasm — e.g. inline event handlers in
  // `components.zig` raw HTML scripts. Identical lookup to the extern.
  window.verveQueryRef = (id) =>
    document.querySelector(`[data-ref="${CSS.escape(String(id))}"]`);

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

  document.addEventListener("click", (e) => {
    // Closure-style: `[z-on-click-id="<id>"]` → fn pointer registered
    // via `verve.registerEvent(...)`, routed through
    // `verve_event_dispatch(id)`. Wins over the string-name form when
    // both attrs land on the same node.
    const targetId = e.target.closest("[z-on-click-id]");
    if (targetId) {
      const id = parseInt(targetId.getAttribute("z-on-click-id"), 10);
      if (Number.isFinite(id) && typeof exp.verve_event_dispatch === "function") {
        e.preventDefault();
        exp.verve_event_dispatch(id >>> 0);
        return;
      }
    }

    const target = e.target.closest("[z-on-click]");
    if (!target) return;
    const action = target.getAttribute("z-on-click");

    if (wsCounterAction(action)) {
      e.preventDefault();
      return;
    }

    const fn = exp[action];
    if (typeof fn === "function") {
      e.preventDefault();
      fn();
    } else {
      console.warn("verve: no wasm export for action", action);
    }
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

  const dispatchIslands = () => {
    if (typeof exp.verve_island_dispatch !== "function") return;
    const scratchPtr = exp.verve_island_scratch_ptr();
    const scratchCap = exp.verve_island_scratch_capacity();
    if (!scratchPtr || !scratchCap) return;
    const enc = new TextEncoder();
    document.querySelectorAll("verve-island").forEach((el) => {
      const name = el.getAttribute("data-name") || "";
      const props = el.getAttribute("data-props") || "";
      const nameBytes = enc.encode(name);
      const propsBytes = enc.encode(props);
      if (nameBytes.length + propsBytes.length > scratchCap) {
        console.warn("verve: island payload exceeds scratch buffer", name);
        return;
      }
      const view = new Uint8Array(memory.buffer, scratchPtr, scratchCap);
      view.set(nameBytes, 0);
      view.set(propsBytes, nameBytes.length);
      exp.verve_island_dispatch(nameBytes.length, propsBytes.length);
    });
  };
  // Run once after the initial hydrate. Components register their
  // hydrate fn during `verve_hydrate`, so this pass picks them up.
  dispatchIslands();

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
  const islandChunks = new Map();
  const loadIslandChunk = async (el) => {
    const name = el.getAttribute("data-name") || "";
    if (!name) return;
    const url = `/islands/${name}.wasm`;
    if (!islandChunks.has(name)) {
      islandChunks.set(
        name,
        WebAssembly.instantiateStreaming(fetch(url), {
          env: { memory },
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
    const props = el.getAttribute("data-props") || "";
    if (
      typeof exp.verve_island_scratch_ptr === "function" &&
      typeof exp.verve_island_scratch_capacity === "function"
    ) {
      const ptr = exp.verve_island_scratch_ptr();
      const cap = exp.verve_island_scratch_capacity();
      const propsBytes = new TextEncoder().encode(props);
      if (propsBytes.length > cap) {
        console.warn("verve: island props exceed shared scratch", name);
        return;
      }
      new Uint8Array(memory.buffer, ptr, cap).set(propsBytes, 0);
      cexp.hydrate(ptr, propsBytes.length, 0);
    } else {
      cexp.hydrate(0, 0, 0);
    }
  };
  document.querySelectorAll("verve-island").forEach((el) => {
    loadIslandChunk(el).catch(() => {});
  });

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
    // Body content swap (preserves outer <body> so scripts don't re-run).
    document.body.innerHTML = doc.body.innerHTML;
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
