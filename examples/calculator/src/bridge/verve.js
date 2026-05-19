// Calculator bridge — load wasm, route z-on-click to exports.

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
    },
  };

  const resp = await fetch("/client.wasm");
  const wasm = await WebAssembly.instantiateStreaming(resp, env);
  memory = wasm.instance.exports.memory;
  const exp = wasm.instance.exports;

  if (typeof exp.verve_hydrate === "function") exp.verve_hydrate();

  document.addEventListener("click", (e) => {
    const target = e.target.closest("[z-on-click]");
    if (!target) return;
    const action = target.getAttribute("z-on-click");
    const fn = exp[action];
    if (typeof fn === "function") {
      e.preventDefault();
      fn();
    } else {
      console.warn("calculator: no wasm export for action", action);
    }
  });

  // Keyboard shortcuts: digits, +, -, *, /, Enter (=) and Escape (C).
  document.addEventListener("keydown", (e) => {
    const m = /^[0-9]$/.exec(e.key);
    if (m) { exp["digit_" + e.key](); return; }
    switch (e.key) {
      case "+": exp.op_add(); return;
      case "-": exp.op_sub(); return;
      case "*": exp.op_mul(); return;
      case "/": e.preventDefault(); exp.op_div(); return;
      case "Enter":
      case "=": exp.op_equals(); return;
      case "Escape":
      case "c":
      case "C": exp.clear(); return;
    }
  });
})();
