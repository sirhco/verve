// Verve desktop bridge — fork of src/bridge/verve.js with server-only
// paths stripped (no /api, /ws, /events, /islands, SPA router, suspense).
// Loaded by the SSR-rendered <head>; fetches and instantiates the WASM
// client served at verve://app/client.wasm.

(async () => {
  let memory = null;
  const readStr = (ptr, len) =>
    new TextDecoder().decode(new Uint8Array(memory.buffer, ptr, len));

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
      console_log_i32: (v) => console.log("verve:", v | 0),
    },
  };

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

  // Delegated click handler: any `[z-on-click="<name>"]` calls the
  // matching wasm export by name. Falls back to a console warning when
  // the export is absent (typo / stale build).
  document.addEventListener("click", (e) => {
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
})();
