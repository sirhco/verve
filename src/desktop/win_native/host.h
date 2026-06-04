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

#ifdef __cplusplus
}
#endif

#endif /* VERVE_WV2_HOST_H */
