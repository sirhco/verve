// Keystrokes bridge — pushes UTF-8 encoded key strings into a wasm-
// owned buffer, then calls record_key(len) to commit.

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
      set_text_by_bind_i32: (bp, bl, v) =>
        setTextByBind(readStr(bp, bl), String(v | 0)),
    },
  };

  const resp = await fetch("/client.wasm");
  const wasm = await WebAssembly.instantiateStreaming(resp, env);
  memory = wasm.instance.exports.memory;
  const exp = wasm.instance.exports;

  if (typeof exp.verve_hydrate === "function") exp.verve_hydrate();

  // Borrow the wasm-owned input buffer once, then reuse it on every
  // keystroke. `exp.key_buffer_ptr()` returns a number (pointer offset
  // into the wasm memory).
  const keyBufPtr = exp.key_buffer_ptr();
  const keyBufLen = exp.key_buffer_len();
  const encoder = new TextEncoder();

  document.addEventListener("keydown", (e) => {
    const bytes = encoder.encode(e.key);
    const n = Math.min(bytes.length, keyBufLen);
    const view = new Uint8Array(memory.buffer, keyBufPtr, keyBufLen);
    view.set(bytes.subarray(0, n));
    exp.record_key(n);
  });

  document.addEventListener("click", (e) => {
    const target = e.target.closest("[z-on-click]");
    if (!target) return;
    const action = target.getAttribute("z-on-click");
    const fn = exp[action];
    if (typeof fn === "function") { e.preventDefault(); fn(); }
  });
})();
