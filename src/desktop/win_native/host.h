/*
 * host.h — flat C ABI for the WebView2 native-host spike.
 *
 * This is the entire seam between Zig and the native WebView2 host. Zig sees
 * only these ~8 functions and one callback typedef; all COM lives behind the
 * boundary in webview2_host.cpp. If this seam proves out on real Windows, the
 * remaining Window backend methods are mechanical additions to this list.
 *
 * Strings crossing the boundary are UTF-8 (the host converts to UTF-16 for
 * Win32 / WebView2). Lengths are explicit; no NUL-termination assumed.
 */
#ifndef VERVE_WV2_HOST_H
#define VERVE_WV2_HOST_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct WV2Host WV2Host;

/* Called on the UI thread when JS posts a message via window.chrome.webview. */
typedef void (*verve_bridge_cb)(void *ctx, const uint8_t *msg, size_t len);

/* Create the host + Win32 window (not yet shown). Returns NULL on failure. */
WV2Host *wv2_create(const char *title, int width, int height);

/* Queue HTML to display once the WebView2 controller is ready (or navigate
 * immediately if it already is). */
void wv2_load_html(WV2Host *host, const char *html, size_t len);

/* Queue a URL to navigate to once the WebView2 controller is ready (or
 * navigate immediately if it already is). */
void wv2_load_url(WV2Host *host, const char *url, size_t len);

/* Run script in the page. Safe to call from inside the bridge callback. */
void wv2_eval_js(WV2Host *host, const char *js, size_t len);

/* Register the JS->host bridge callback. */
void wv2_set_bridge(WV2Host *host, verve_bridge_cb cb, void *ctx);

/* Show the window, create the WebView2 environment/controller, and pump the
 * Win32 message loop until the window closes. Blocks. */
void wv2_run(WV2Host *host);

/* Tear down. */
void wv2_destroy(WV2Host *host);

/* ---- Bundle 2: window geometry & state ----------------------------------- */

void  wv2_set_title(WV2Host *host, const char *title, size_t len);
void  wv2_set_always_on_top(WV2Host *host, int on);
void  wv2_set_opacity(WV2Host *host, double v);
void  wv2_set_size(WV2Host *host, uint32_t w, uint32_t h);
void  wv2_set_position(WV2Host *host, int32_t x, int32_t y);
void  wv2_center(WV2Host *host);
void  wv2_minimize(WV2Host *host);
void  wv2_maximize(WV2Host *host);
void  wv2_restore(WV2Host *host);
void  wv2_show(WV2Host *host);
void  wv2_hide(WV2Host *host);
void  wv2_focus(WV2Host *host);
void  wv2_set_min_size(WV2Host *host, uint32_t w, uint32_t h);
void  wv2_set_max_size(WV2Host *host, uint32_t w, uint32_t h);
float wv2_scale_factor(WV2Host *host);
int   wv2_is_minimized(WV2Host *host);
int   wv2_is_maximized(WV2Host *host);
int   wv2_is_fullscreen(WV2Host *host);
void  wv2_request_attention(WV2Host *host, int critical);
void  wv2_set_resizable(WV2Host *host, int on);
void  wv2_set_fullscreen(WV2Host *host, int on);

/* ---- Bundle 3: navigation & webview state -------------------------------- */

void   wv2_reload(WV2Host *host);
void   wv2_go_back(WV2Host *host);
void   wv2_go_forward(WV2Host *host);
int    wv2_can_go_back(WV2Host *host);
int    wv2_can_go_forward(WV2Host *host);

/* Fill `buf` (capacity `cap`) with the current Source URL / DocumentTitle as
 * UTF-8 (no NUL). Returns the FULL byte length even when it exceeds `cap`;
 * copies min(len, cap). 0 when the webview is not yet ready. */
size_t wv2_current_url(WV2Host *host, uint8_t *buf, size_t cap);
size_t wv2_current_title(WV2Host *host, uint8_t *buf, size_t cap);

void   wv2_set_zoom(WV2Host *host, double level);
double wv2_get_zoom(WV2Host *host);

/* OS theme: 0 light, 1 dark, 2 unknown. */
int    wv2_color_scheme(WV2Host *host);

/* Called on the UI thread when the OS light/dark theme toggles. */
typedef void (*verve_color_scheme_cb)(void *ctx, int scheme);
void   wv2_set_color_scheme_cb(WV2Host *host, verve_color_scheme_cb cb, void *ctx);

/* ---- Bundle 4: event handlers & lifecycle -------------------------------- */

/* All fired on the UI thread. resize: client-area size on WM_SIZE. focus:
 * activated(1)/blurred(0) on WM_ACTIVATE. close: WM_CLOSE veto gate — return 0
 * to veto (keep the window), non-zero to allow the default close. drag_drop:
 * dropped file paths as one UTF-8 buffer with paths separated by '\0' (no
 * trailing separator); `len` is the buffer length. */
typedef void (*verve_resize_cb)(void *ctx, uint32_t w, uint32_t h);
typedef void (*verve_focus_cb)(void *ctx, int focused);
typedef int  (*verve_close_cb)(void *ctx);
typedef void (*verve_drag_drop_cb)(void *ctx, const uint8_t *paths_nul_joined,
                                   size_t len);

void wv2_set_resize_cb(WV2Host *host, verve_resize_cb cb, void *ctx);
void wv2_set_focus_cb(WV2Host *host, verve_focus_cb cb, void *ctx);
void wv2_set_close_cb(WV2Host *host, verve_close_cb cb, void *ctx);
void wv2_set_drag_drop_cb(WV2Host *host, verve_drag_drop_cb cb, void *ctx);

/* Send WM_CLOSE synchronously so the close path (incl. any veto handler) runs. */
void wv2_close(WV2Host *host);

/* ---- Bundle 5: dialogs & child windows ----------------------------------- */

/* Modal Win32 common file dialogs (GetOpenFileNameW / GetSaveFileNameW).
 *
 * Strings are UTF-8 (ptr,len). `filters` is the pattern string already joined
 * by the Zig side (e.g. "*.txt;*.json"); empty (filters_len==0) => allow any.
 * The host wraps it under a single "Allowed types" description and builds the
 * double-NUL-terminated OPENFILENAMEW filter buffer.
 *
 * Result: the chosen path is written into `buf` (capacity `cap`) as UTF-8 (no
 * NUL); the FULL byte length is returned even when it exceeds `cap` (caller
 * re-allocs + re-calls, same buffer-grow contract as wv2_current_url). A return
 * of 0 means the user cancelled / picked nothing. */
size_t wv2_open_file_dialog(WV2Host *host, const char *title, size_t title_len,
                            const char *default_path, size_t default_path_len,
                            const char *filters, size_t filters_len,
                            int allow_multiple, uint8_t *buf, size_t cap);
size_t wv2_save_file_dialog(WV2Host *host, const char *title, size_t title_len,
                            const char *default_path, size_t default_path_len,
                            const char *default_name, size_t default_name_len,
                            const char *filters, size_t filters_len,
                            uint8_t *buf, size_t cap);

/* Modal alert via MessageBoxW. `style`: 0 informational, 1 warning, 2 critical.
 * `button_count` (1/2/3+) maps onto MB_OK / MB_YESNO / MB_YESNOCANCEL exactly
 * as the legacy backend does. Returns the chosen button INDEX in the caller's
 * button order: 1-button => 0; 2-button => IDYES=0/IDNO=1; 3-button =>
 * IDYES=0/IDNO=1/IDCANCEL=2. The custom button label strings are not honored by
 * MessageBoxW and are therefore not passed across the ABI (documented at the
 * Zig surface). */
size_t wv2_show_alert(WV2Host *host, const char *title, size_t title_len,
                      const char *message, size_t message_len, int style,
                      size_t button_count);

/* Create an independent top-level host + Win32 window (same as wv2_create but
 * conceptually a child of `parent`'s app session). Returns the new WV2Host* or
 * NULL on failure. The caller owns it and must wv2_destroy it. */
WV2Host *wv2_open_child(WV2Host *parent, const char *title, size_t title_len,
                        int width, int height);

/* ---- Bundle 6: cookies (ICoreWebView2CookieManager) ---------------------- */
/*
 * Cookie fields cross the seam as explicit args (no JSON). Strings are UTF-8
 * (ptr,len); the host widens to UTF-16 for WebView2. `same_site` is the
 * COREWEBVIEW2_COOKIE_SAME_SITE_KIND int (0 none / 1 lax / 2 strict); the Zig
 * cookie_codec owns the SameSite<->int mapping. `has_expiry`==0 => session
 * cookie (no put_Expires); otherwise `expiry` is Unix epoch seconds as a double.
 * secure / http_only are 0/1 bools.
 *
 * All four require the WebView2 to be ready; they return a backend error code
 * when it is not (set/delete/clear: nonzero; get: <0). get pumps the async
 * GetCookies completion to a bounded finish before returning.
 */

/* Set (create-or-update) a cookie. Returns 0 on success, nonzero on error
 * (webview not ready, CreateCookie / AddOrUpdateCookie HRESULT < 0). */
int wv2_cookie_set(WV2Host *host, const char *name, size_t nlen, const char *value,
                   size_t vlen, const char *domain, size_t dlen, const char *path,
                   size_t plen, int has_expiry, double expiry, int secure,
                   int http_only, int same_site);

/* Delete the first cookie matching `name` (scoped by domain/path when given).
 * No-op when no match. Returns 0 on success, nonzero on error. */
int wv2_cookie_delete(WV2Host *host, const char *name, size_t nlen,
                      const char *domain, size_t dlen, const char *path,
                      size_t plen);

/* Delete every cookie in the manager's store. Returns 0 on success, nonzero on
 * error (webview not ready, DeleteAllCookies HRESULT < 0). */
int wv2_cookie_clear(WV2Host *host);

/* Read the first cookie matching `name`. Fills the string out-buffers (UTF-8,
 * no NUL) and the scalar out-params. Returns 1 = found, 0 = not found, <0 =
 * error (webview not ready / GetCookies failed). The string lengths written to
 * *_len are clamped to the matching *_cap (4096 each is generous). */
int wv2_cookie_get(WV2Host *host, const char *name, size_t nlen,
                   uint8_t *value_buf, size_t value_cap, size_t *value_len,
                   uint8_t *domain_buf, size_t domain_cap, size_t *domain_len,
                   uint8_t *path_buf, size_t path_cap, size_t *path_len,
                   int *has_expiry, double *expiry, int *secure, int *http_only,
                   int *same_site);

/* ---- Bundle 7: clipboard (Win32 clipboard + WIC) ------------------------- */
/*
 * The Win32 clipboard is process-global: the host OpenClipboard()s on the
 * window's HWND, mutates, CloseClipboard()s — every path balances open/close so
 * a left-open clipboard can't hang other apps. SetClipboardData transfers
 * ownership of the HGLOBAL to the system on success.
 *
 * Text   : CF_UNICODETEXT (the host widens the UTF-8 (ptr,len) to UTF-16LE).
 * HTML   : the registered "HTML Format" (RegisterClipboardFormatW). The CALLER
 *          (Zig clipboard_codec) builds the full CF_HTML byte blob and passes it
 *          here verbatim on write; on read the host returns the raw CF_HTML
 *          bytes and the Zig side extracts the inner fragment.
 * Image  : CF_DIBV5. The caller passes raw PNG bytes; the host transcodes
 *          PNG<->32bpp-BGRA DIB via WIC (windowscodecs).
 *
 * Read fns follow the buffer-grow contract (copy min(full,cap), return the FULL
 * byte length; 0 = no matching format on the clipboard).
 */

/* Write UTF-8 text as CF_UNICODETEXT. Returns 0 on success, nonzero on error. */
int    wv2_clip_write_text(WV2Host *host, const char *utf8, size_t len);
/* Read CF_UNICODETEXT as UTF-8 into `buf` (cap). Returns the FULL byte length
 * (copies min(len,cap)); 0 when no text is on the clipboard. */
size_t wv2_clip_read_text(WV2Host *host, uint8_t *buf, size_t cap);

/* Write a finished CF_HTML byte blob (Zig built it) under "HTML Format".
 * Returns 0 on success, nonzero on error. */
int    wv2_clip_write_html(WV2Host *host, const char *cf_html, size_t len);
/* Read the raw CF_HTML bytes under "HTML Format" into `buf` (cap). Returns the
 * FULL byte length; 0 when no HTML is on the clipboard. The Zig side extracts
 * the fragment from these bytes. */
size_t wv2_clip_read_html(WV2Host *host, uint8_t *buf, size_t cap);

/* Write a PNG image: the host WIC-transcodes PNG->32bpp-BGRA DIB and sets
 * CF_DIBV5. Returns 0 on success, nonzero on error. */
int    wv2_clip_write_image(WV2Host *host, const uint8_t *png, size_t len);
/* Read CF_DIBV5/CF_DIB off the clipboard, WIC-transcode DIB->PNG, and write the
 * PNG bytes into `buf` (cap). Returns the FULL PNG byte length; 0 when no image
 * is on the clipboard. */
size_t wv2_clip_read_image(WV2Host *host, uint8_t *buf, size_t cap);

#ifdef __cplusplus
}
#endif

#endif /* VERVE_WV2_HOST_H */
