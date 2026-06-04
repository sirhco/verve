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

#ifdef __cplusplus
}
#endif

#endif /* VERVE_WV2_HOST_H */
