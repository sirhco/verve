// Stopwatch bridge. Loads the wasm client, wires the delegated click
// listener (so z-on-click="start_stopwatch" finds exp.start_stopwatch),
// and drives a 50ms tick into wasm so the display updates without the
// wasm code itself having to know about JS timers.

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

  const env = {
    verve: {
      set_text_by_bind: (bp, bl, tp, tl) =>
        setTextByBind(readStr(bp, bl), readStr(tp, tl)),
      console_log_i32: (v) => console.log("stopwatch:", v | 0),
    },
  };

  const resp = await fetch("/client.wasm");
  const wasm = await WebAssembly.instantiateStreaming(resp, env);
  memory = wasm.instance.exports.memory;
  const exp = wasm.instance.exports;

  if (typeof exp.verve_hydrate === "function") exp.verve_hydrate();

  // Drive the wasm tick from JS so the wasm code itself stays
  // single-threaded and timer-agnostic.
  let last = performance.now();
  setInterval(() => {
    const now = performance.now();
    const dt = Math.max(0, Math.round(now - last));
    last = now;
    exp.tick(dt | 0);
  }, 50);

  document.addEventListener("click", (e) => {
    const target = e.target.closest("[z-on-click]");
    if (!target) return;
    const action = target.getAttribute("z-on-click");
    const fn = exp[action];
    if (typeof fn === "function") {
      e.preventDefault();
      fn();
    } else {
      console.warn("stopwatch: no wasm export for action", action);
    }
  });
})();
