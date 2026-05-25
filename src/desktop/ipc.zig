//! Document-start JS shim that normalizes the per-platform postMessage
//! APIs behind a single `window.verve` surface.
//!
//! Lifecycle:
//!   1. `Window.init` adds this script to the user-content controller
//!      with `at_document_start = true` (where the platform exposes
//!      that option). On WebKitGTK the equivalent is
//!      `WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START`.
//!   2. Every navigation re-runs the shim before user scripts evaluate,
//!      so a page reload never strips `window.verve`.
//!   3. JS calls `window.verve.send(json)` which dispatches to the
//!      platform-specific bridge. Zig receives the raw string through
//!      its registered `MessageHandler`.
//!   4. Zig calls `window.verve._dispatch(json)` via `evalJs` to push a
//!      reply. The shim fans the parsed payload out to listeners
//!      registered with `window.verve.onMessage(fn)`.
//!
//! The JS deliberately uses ES5-compatible features so it loads in any
//! WKWebView/WebView2/WebKitGTK build — no module syntax, no optional
//! chaining, no `globalThis`.

pub const shim_js: []const u8 =
    \\(function () {
    \\  if (window.verve) return;
    \\  var listeners = [];
    \\  var pending = {};
    \\  var nextId = 1;
    \\  function send(payload) {
    \\    var msg = typeof payload === 'string' ? payload : JSON.stringify(payload);
    \\    try {
    \\      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.verve) {
    \\        window.webkit.messageHandlers.verve.postMessage(msg);
    \\        return;
    \\      }
    \\      if (window.chrome && window.chrome.webview && window.chrome.webview.postMessage) {
    \\        window.chrome.webview.postMessage(msg);
    \\        return;
    \\      }
    \\    } catch (err) {
    \\      console.error('[verve] postMessage failed', err);
    \\    }
    \\    console.warn('[verve] no native bridge — dropping', msg);
    \\  }
    \\  function request(payload) {
    \\    return new Promise(function (resolve, reject) {
    \\      var id = '_v' + (nextId += 1);
    \\      pending[id] = { resolve: resolve, reject: reject };
    \\      var msg = Object.assign({}, payload || {}, { __verve_id: id });
    \\      send(msg);
    \\    });
    \\  }
    \\  function onMessage(fn) {
    \\    if (typeof fn === 'function') listeners.push(fn);
    \\  }
    \\  function _dispatch(raw) {
    \\    var data;
    \\    try { data = typeof raw === 'string' ? JSON.parse(raw) : raw; }
    \\    catch (err) { data = raw; }
    \\    if (data && data.__verve_id && pending[data.__verve_id]) {
    \\      var slot = pending[data.__verve_id];
    \\      delete pending[data.__verve_id];
    \\      if (data.__verve_error) slot.reject(new Error(data.__verve_error));
    \\      else slot.resolve(data.result);
    \\      return;
    \\    }
    \\    for (var i = 0; i < listeners.length; i += 1) {
    \\      try { listeners[i](data); }
    \\      catch (err) { console.error('[verve] listener failed', err); }
    \\    }
    \\  }
    \\  window.verve = { send: send, request: request, onMessage: onMessage, _dispatch: _dispatch };
    \\  // Title auto-sync: poll document.title every 500ms, post a
    \\  // marker string to the native bridge whenever it changes. The
    \\  // backend's script-message trampolines peek for the prefix +
    \\  // route to the native setTitle without forwarding to user
    \\  // handlers. ES5-only; safe in every WebView engine.
    \\  var __vt_last = document.title || '';
    \\  function __vt_post(t) { send('__verve_title:' + t); }
    \\  __vt_post(__vt_last);
    \\  setInterval(function () {
    \\    if (document.title !== __vt_last) {
    \\      __vt_last = document.title;
    \\      __vt_post(__vt_last);
    \\    }
    \\  }, 500);
    \\  document.dispatchEvent(new Event('verve:ready'));
    \\})();
;
