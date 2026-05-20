// Dashboard bridge — wires every wasm export the showcase relies on.
//
// Responsibilities (read top-to-bottom):
//   1. env imports the wasm module imports (`verve.*`).
//   2. Boot: load /client.wasm, hand it server-rendered ages, call hydrate.
//   3. 1Hz tick.
//   4. Click delegation for `z-on-click` exports.
//   5. Command palette: keybinds, filtering, focus trap, list rendering.
//   6. Search filter: input → wasm → DOM toggle of `.is-filtered-out`.
//   7. Toast renderer: SSE-triggered + action-triggered transient banners.
//   8. Drag-and-drop kanban: HTML5 DnD posting to /api/moveTask.
//   9. Disney carousel: pages of 6, prev/next, page indicator.
//  10. /live WebSocket: open per visit, append messages to log.

(async () => {
  let memory = null;
  let exp = null;
  let es = null;
  let ws = null;

  const decoder = new TextDecoder();
  const encoder = new TextEncoder();

  const readStr = (ptr, len) =>
    decoder.decode(new Uint8Array(memory.buffer, ptr, len));

  const setTextByBind = (bind, text) => {
    document
      .querySelectorAll(`[z-bind="${CSS.escape(bind)}"]`)
      .forEach((el) => {
        el.textContent = text;
      });
  };

  // ---- env imports -----------------------------------------------------

  const sseOpen = () => {
    if (es) return;
    try {
      es = new EventSource("/events");
    } catch (err) {
      console.warn("verve: EventSource open failed", err);
      es = null;
      exp && exp.on_sse_error && exp.on_sse_error();
      return;
    }
    es.addEventListener("count", (e) => {
      const v = Number(e.data);
      if (Number.isNaN(v)) return;
      exp && exp.on_sse_event && exp.on_sse_event(v);
    });
    es.addEventListener("error", () => {
      exp && exp.on_sse_error && exp.on_sse_error();
    });
  };

  const sseClose = () => {
    if (!es) return;
    try { es.close(); } catch (_) { /* ignore */ }
    es = null;
  };

  const wsOpen = () => {
    if (ws) return;
    const proto = location.protocol === "https:" ? "wss:" : "ws:";
    try {
      ws = new WebSocket(`${proto}//${location.host}/ws`);
    } catch (err) {
      console.warn("verve: WebSocket open failed", err);
      ws = null;
      exp && exp.on_ws_close && exp.on_ws_close();
      return;
    }
    ws.addEventListener("open", () => {
      exp && exp.on_ws_open && exp.on_ws_open();
    });
    ws.addEventListener("close", () => {
      ws = null;
      exp && exp.on_ws_close && exp.on_ws_close();
    });
    ws.addEventListener("error", () => {
      exp && exp.on_ws_close && exp.on_ws_close();
    });
    ws.addEventListener("message", (e) => appendChatLine(e.data));
  };

  const wsClose = () => {
    if (!ws) return;
    try { ws.close(); } catch (_) { /* ignore */ }
    ws = null;
  };

  const wsSendBytes = (ptr, len) => {
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    const bytes = new Uint8Array(memory.buffer, ptr, len);
    ws.send(decoder.decode(bytes));
  };

  const themeApply = (ptr, len) => {
    const slug = readStr(ptr, len);
    document.documentElement.dataset.theme = slug;
  };

  const themePersist = (ptr, len) => {
    try { localStorage.setItem("verve-theme", readStr(ptr, len)); } catch (_) {}
  };

  const themeLoad = (bufPtr, bufCap) => {
    let stored = "";
    try { stored = localStorage.getItem("verve-theme") || ""; } catch (_) {}
    if (!stored) return 0;
    const bytes = encoder.encode(stored).slice(0, bufCap);
    new Uint8Array(memory.buffer, bufPtr, bytes.length).set(bytes);
    return bytes.length;
  };

  // ---- palette state mirrored on JS side -------------------------------
  // The list lives in the DOM (rendered by Zig). JS keeps an in-memory
  // shadow keyed by data-palette-item so filter + selection apply quickly.

  let paletteItems = [];
  let paletteVisible = [];

  const refreshPaletteShadow = () => {
    const overlay = document.getElementById("palette");
    if (!overlay) return;
    paletteItems = Array.from(overlay.querySelectorAll("[data-palette-item]")).map((el) => ({
      el,
      id: el.getAttribute("data-palette-item"),
      label: el.querySelector(".palette-item-label").textContent.toLowerCase(),
      kind: el.getAttribute("data-palette-kind") || "",
    }));
    paletteVisible = paletteItems.slice();
  };

  const paletteShow = () => {
    const overlay = document.getElementById("palette");
    if (!overlay) return;
    refreshPaletteShadow();
    overlay.setAttribute("aria-hidden", "false");
    overlay.classList.add("is-open");
    document.body.classList.add("modal-open");
    const input = document.getElementById("palette-input");
    if (input) {
      input.value = "";
      input.focus();
    }
  };

  const paletteHide = () => {
    const overlay = document.getElementById("palette");
    if (!overlay) return;
    overlay.setAttribute("aria-hidden", "true");
    overlay.classList.remove("is-open");
    document.body.classList.remove("modal-open");
    // Return focus to the palette trigger if present.
    const trigger = document.querySelector(".palette-trigger");
    if (trigger) trigger.focus();
  };

  const paletteApplyFilter = (ptr, len) => {
    const q = readStr(ptr, len).trim().toLowerCase();
    paletteVisible = q.length === 0
      ? paletteItems.slice()
      : paletteItems.filter((it) => it.label.includes(q));
    paletteItems.forEach((it) => {
      it.el.style.display = paletteVisible.includes(it) ? "" : "none";
    });
  };

  const paletteRenderSelection = (idx) => {
    paletteVisible.forEach((it, i) => {
      const sel = i === idx;
      it.el.setAttribute("aria-selected", sel ? "true" : "false");
      it.el.classList.toggle("is-active", sel);
      if (sel) it.el.scrollIntoView({ block: "nearest" });
    });
  };

  const paletteVisibleCount = () => paletteVisible.length;

  const paletteActivate = (idx) => {
    const item = paletteVisible[idx];
    if (!item) return;
    paletteHide();
    runPaletteCommand(item.id);
  };

  const runPaletteCommand = (id) => {
    switch (id) {
      case "go-overview": location.href = "/"; break;
      case "go-tasks": location.href = "/tasks"; break;
      case "go-team": location.href = "/team"; break;
      case "go-external": location.href = "/external"; break;
      case "go-analytics": location.href = "/analytics"; break;
      case "go-live": location.href = "/live"; break;
      case "go-settings": location.href = "/settings"; break;
      case "act-reload": location.reload(); break;
      case "act-theme": exp.theme_cycle(); break;
      case "act-disconnect": exp.disconnect_sse(); break;
      case "act-connect": exp.connect_sse(); break;
      case "act-focus-search": focusSearch(); break;
      default: console.warn("verve: unknown palette command", id);
    }
  };

  const focusSearch = () => {
    const input = document.querySelector("[data-global-search]");
    if (input) {
      input.focus();
      input.select();
    }
  };

  // ---- search filter -------------------------------------------------

  const searchApply = (ptr, len) => {
    const q = readStr(ptr, len).trim().toLowerCase();
    let matched = 0;
    document.querySelectorAll("[data-filterable]").forEach((el) => {
      if (q.length === 0) {
        el.classList.remove("is-filtered-out");
        matched += 1;
        return;
      }
      const haystack = (el.getAttribute("data-filter-text") || el.textContent || "").toLowerCase();
      const hit = haystack.includes(q);
      el.classList.toggle("is-filtered-out", !hit);
      if (hit) matched += 1;
    });
    return matched;
  };

  // ---- carousel ------------------------------------------------------

  let carouselSlides = [];
  let carouselCounter = null;

  const refreshCarousel = () => {
    const carousel = document.querySelector("[data-carousel]");
    carouselSlides = carousel ? Array.from(carousel.querySelectorAll("[data-slide]")) : [];
    carouselCounter = carousel ? carousel.querySelector("[data-carousel-counter]") : null;
  };

  const carouselRender = (cursor, page) => {
    if (!carouselSlides.length) return;
    const len = carouselSlides.length;
    const pageSize = 6;
    const totalPages = Math.max(1, Math.ceil(len / pageSize));
    const clampedPage = ((page % totalPages) + totalPages) % totalPages;
    const startIdx = clampedPage * pageSize;
    const endIdx = Math.min(startIdx + pageSize, len);
    let absCursor = cursor;
    if (absCursor < startIdx) absCursor = startIdx;
    if (absCursor >= endIdx) absCursor = startIdx;
    const localIdx = ((absCursor - startIdx) % (endIdx - startIdx)) + 0;
    carouselSlides.forEach((s, i) => {
      const inPage = i >= startIdx && i < endIdx;
      s.style.display = inPage ? "" : "none";
      s.classList.toggle("is-active", i === absCursor);
    });
    if (carouselCounter) {
      carouselCounter.textContent = `${localIdx + 1} of ${endIdx - startIdx} · page ${clampedPage + 1}/${totalPages}`;
    }
  };

  // ---- env table -----------------------------------------------------

  const env = {
    verve: {
      set_text_by_bind: (bp, bl, tp, tl) =>
        setTextByBind(readStr(bp, bl), readStr(tp, tl)),
      reload_page: () => window.location.reload(),
      sse_open: () => sseOpen(),
      sse_close: () => sseClose(),
      ws_open: () => wsOpen(),
      ws_close: () => wsClose(),
      ws_send: (p, l) => wsSendBytes(p, l),
      theme_apply: (p, l) => themeApply(p, l),
      theme_persist: (p, l) => themePersist(p, l),
      theme_load: (p, c) => themeLoad(p, c),
      palette_show: () => paletteShow(),
      palette_hide: () => paletteHide(),
      palette_apply_filter: (p, l) => paletteApplyFilter(p, l),
      palette_render_selection: (i) => paletteRenderSelection(i),
      palette_visible_count: () => paletteVisibleCount(),
      palette_activate: (i) => paletteActivate(i),
      focus_search: () => focusSearch(),
      search_apply: (p, l) => searchApply(p, l),
      carousel_render: (c, p) => carouselRender(c, p),
    },
  };

  // ---- boot ----------------------------------------------------------

  const resp = await fetch("/client.wasm");
  const wasm = await WebAssembly.instantiateStreaming(resp, env);
  memory = wasm.instance.exports.memory;
  exp = wasm.instance.exports;

  const ds = document.body.dataset;
  exp.verve_init_ages(
    Number(ds.serverAge || 0),
    Number(ds.chuckAge || 0),
    Number(ds.carbonAge || 0),
    Number(ds.disneyAge || 0),
    Number(ds.refreshCount || 0),
  );

  if (typeof exp.verve_hydrate === "function") exp.verve_hydrate();

  // 1Hz ticker.
  setInterval(() => exp.tick(), 1000);

  // ---- click delegation --------------------------------------------

  document.addEventListener("click", (e) => {
    const target = e.target.closest("[z-on-click]");
    if (!target) return;
    const action = target.getAttribute("z-on-click");
    const fn = exp[action];
    if (typeof fn === "function") {
      e.preventDefault();
      fn();
      if (action === "next_char" || action === "prev_char" ||
          action === "next_page" || action === "prev_page") {
        // No-op — the export already calls carousel_render via env import.
      }
    }
  });

  // ---- palette keyboard ---------------------------------------------

  document.addEventListener("keydown", (e) => {
    const cmdK = (e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k";
    if (cmdK) {
      e.preventDefault();
      exp.palette_toggle();
      return;
    }
    const openPalette = document.getElementById("palette");
    const paletteOpen = openPalette && openPalette.classList.contains("is-open");
    if (paletteOpen) {
      if (e.key === "Escape") { e.preventDefault(); exp.palette_close(); return; }
      if (e.key === "ArrowDown") { e.preventDefault(); exp.palette_move(1); return; }
      if (e.key === "ArrowUp") { e.preventDefault(); exp.palette_move(-1); return; }
      if (e.key === "Enter") { e.preventDefault(); exp.palette_enter(); return; }
    }
    // "/" focuses search when nothing else is focused on an input.
    if (e.key === "/" && document.activeElement && document.activeElement.tagName !== "INPUT" && document.activeElement.tagName !== "TEXTAREA") {
      e.preventDefault();
      focusSearch();
    }
  });

  // ---- palette input forwarding -------------------------------------

  const paletteInput = document.getElementById("palette-input");
  if (paletteInput) {
    paletteInput.addEventListener("input", () => {
      const bytes = encoder.encode(paletteInput.value);
      const ptr = 0; // we use a static scratch buffer instead — see scratchWrite
      // Allocate via memory: write into the static scratch slot below.
      scratchWrite(bytes);
      exp.palette_input(scratchPtr(), bytes.length);
    });
  }

  // ---- search forwarding -------------------------------------------

  const searchInput = document.querySelector("[data-global-search]");
  if (searchInput) {
    searchInput.addEventListener("input", () => {
      const bytes = encoder.encode(searchInput.value);
      scratchWrite(bytes);
      exp.search_input(scratchPtr(), bytes.length);
    });
    searchInput.addEventListener("keydown", (e) => {
      if (e.key === "Escape") { searchInput.value = ""; searchInput.dispatchEvent(new Event("input")); searchInput.blur(); }
    });
  }

  // ---- toasts -------------------------------------------------------

  const toastRegion = document.getElementById("toasts");
  const pushToast = (kind, message, ttlMs) => {
    if (!toastRegion) return;
    const el = document.createElement("div");
    el.className = `toast toast-${kind}`;
    el.setAttribute("role", kind === "error" ? "alert" : "status");
    const body = document.createElement("span");
    body.className = "toast-body";
    body.textContent = message;
    const close = document.createElement("button");
    close.type = "button";
    close.className = "toast-close";
    close.setAttribute("aria-label", "Dismiss notification");
    close.textContent = "×";
    close.addEventListener("click", () => el.remove());
    el.appendChild(body);
    el.appendChild(close);
    toastRegion.appendChild(el);
    setTimeout(() => {
      el.classList.add("is-leaving");
      setTimeout(() => el.remove(), 240);
    }, ttlMs || 3500);
  };

  // SSE-driven toast: when wasm increments sse_mutations, surface one.
  // We watch the mutation count by re-reading the span on every tick.
  let lastMutationCount = -1;
  setInterval(() => {
    const el = document.querySelector(`[z-bind="sse_mutations"]`);
    if (!el) return;
    const v = Number(el.textContent);
    if (lastMutationCount === -1) { lastMutationCount = v; return; }
    if (v !== lastMutationCount) {
      lastMutationCount = v;
      pushToast("info", `Server data refreshed (#${v})`);
    }
  }, 500);

  // Click-time optimistic toasts on known action buttons.
  document.addEventListener("submit", (e) => {
    const form = e.target;
    const action = form.getAttribute("action") || "";
    if (!action.startsWith("/api/")) return;
    const label = action.slice(5);
    pushToast("info", `${label} sent…`, 2200);
  }, true);

  // ---- drag-and-drop kanban -----------------------------------------

  let dragId = null;
  document.addEventListener("dragstart", (e) => {
    const card = e.target.closest("[data-task-id]");
    if (!card) return;
    dragId = card.getAttribute("data-task-id");
    card.classList.add("is-dragging");
    e.dataTransfer.effectAllowed = "move";
    e.dataTransfer.setData("text/plain", dragId);
  });
  document.addEventListener("dragend", (e) => {
    const card = e.target.closest("[data-task-id]");
    if (card) card.classList.remove("is-dragging");
    document.querySelectorAll(".is-drop-target").forEach((el) => el.classList.remove("is-drop-target"));
    dragId = null;
  });
  document.addEventListener("dragover", (e) => {
    const dz = e.target.closest("[data-drop-column]");
    if (!dz) return;
    e.preventDefault();
    e.dataTransfer.dropEffect = "move";
    dz.classList.add("is-drop-target");
  });
  document.addEventListener("dragleave", (e) => {
    const dz = e.target.closest("[data-drop-column]");
    if (dz) dz.classList.remove("is-drop-target");
  });
  document.addEventListener("drop", async (e) => {
    const dz = e.target.closest("[data-drop-column]");
    if (!dz) return;
    e.preventDefault();
    const col = dz.getAttribute("data-drop-column");
    const id = dragId || e.dataTransfer.getData("text/plain");
    if (!id) return;
    dz.classList.remove("is-drop-target");
    try {
      const body = new URLSearchParams({ id: String(id), column: col });
      const resp = await fetch("/api/moveTask", { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body: body.toString() });
      if (resp.ok || resp.status === 303) {
        pushToast("info", `Moved task ${id} → ${col}`);
        announce(`Moved task ${id} to ${col}`);
        // Server bumps last_count which fires SSE → reload.
      } else {
        pushToast("error", `Move failed (${resp.status})`);
      }
    } catch (err) {
      pushToast("error", `Move failed (${err && err.message ? err.message : "network"})`);
    }
  });

  const announce = (text) => {
    const el = document.querySelector("[data-sr-announce]");
    if (!el) return;
    el.textContent = "";
    setTimeout(() => { el.textContent = text; }, 50);
  };

  // ---- live chat ----------------------------------------------------

  const liveLog = document.querySelector("[data-live-log]");
  const liveInput = document.querySelector("[data-live-input]");
  const liveNick = document.querySelector("[data-live-nick]");
  const liveSend = document.querySelector("[data-live-send]");
  if (liveLog) {
    exp.ws_connect();
  }

  const appendChatLine = (raw) => {
    if (!liveLog) return;
    const empty = liveLog.querySelector(".live-empty");
    if (empty) empty.remove();
    let nick = "anon", text = raw, ts = "";
    try {
      const obj = JSON.parse(raw);
      if (obj && obj.nick) nick = String(obj.nick).slice(0, 32);
      if (obj && obj.text) text = String(obj.text).slice(0, 200);
      if (obj && obj.ts) ts = obj.ts;
    } catch (_) { /* plain text fallback */ }
    const row = document.createElement("div");
    row.className = "live-row";
    row.innerHTML = `<span class="live-nick"></span><span class="live-msg"></span><span class="live-ts"></span>`;
    row.children[0].textContent = nick;
    row.children[1].textContent = text;
    row.children[2].textContent = ts;
    liveLog.appendChild(row);
    liveLog.scrollTop = liveLog.scrollHeight;
  };

  const sendChat = () => {
    if (!liveInput) return;
    const text = liveInput.value.trim();
    if (!text) return;
    const nick = (liveNick && liveNick.value.trim()) || "anon";
    const ts = new Date().toLocaleTimeString();
    const payload = JSON.stringify({ nick: nick.slice(0, 32), text: text.slice(0, 200), ts });
    const bytes = encoder.encode(payload);
    scratchWrite(bytes);
    exp.ws_send(scratchPtr(), bytes.length);
    liveInput.value = "";
  };
  if (liveSend) liveSend.addEventListener("click", sendChat);
  if (liveInput) liveInput.addEventListener("keydown", (e) => {
    if (e.key === "Enter") { e.preventDefault(); sendChat(); }
  });

  // ---- scratch buffer for JS → wasm string passing -----------------
  //
  // Wasm exports that accept (ptr, len) read from linear memory. JS can
  // hand them a tiny static slice carved off the static heap. The bridge
  // doesn't share a real allocator with the module, so we lean on the
  // fact that wasm's own FBA never touches the first 32 bytes after
  // module init (its heap starts well past that). For longer payloads we
  // chunk; for this app, 512 bytes is more than enough.

  let scratchOffset = -1;
  const scratchCap = 512;
  function scratchPtr() {
    if (scratchOffset < 0) {
      // Discover an "above heap" location by stretching memory by one page.
      memory.grow(1);
      scratchOffset = memory.buffer.byteLength - scratchCap;
    }
    return scratchOffset;
  }
  function scratchWrite(bytes) {
    const dst = scratchPtr();
    new Uint8Array(memory.buffer, dst, scratchCap).set(bytes.slice(0, scratchCap));
  }

  // ---- initial DOM hooks --------------------------------------------

  refreshCarousel();
  if (typeof exp.current_cursor === "function") {
    exp.carousel_render && carouselRender(exp.current_cursor(), exp.current_page ? exp.current_page() : 0);
  }
})();
