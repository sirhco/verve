/*
 * webview2_host.cpp — native C++ WebView2 host behind a flat C ABI.
 *
 * The C++ compiler generates correct COM vtables from the vendored WebView2.h;
 * we never count offsets. WRL and libc++ are deliberately avoided so the file
 * cross-compiles from macOS under zig's bundled mingw clang with only the
 * vendored header (raw malloc buffers keep the link dependency-light).
 *
 * Build: zig c++ -target x86_64-windows-gnu -fms-extensions -std=c++17
 *               -I src/desktop/win_native/include -c src/desktop/win_native/webview2_host.cpp
 */
#include <windows.h>
#include <objbase.h>
#include <ole2.h>      // OleInitialize / RegisterDragDrop / ReleaseStgMedium
#include <oleidl.h>    // IDropTarget
#include <shellapi.h>  // DragQueryFileW / CF_HDROP
#include <commdlg.h>   // GetOpenFileNameW / GetSaveFileNameW / OPENFILENAMEW
#include <shlwapi.h>   // SHCreateMemStream (PNG bytes -> IStream)
#include <wincodec.h>  // WIC: PNG <-> 32bpp-BGRA DIB transcode (Bundle 7 image)

#include <WebView2.h>

#include "host.h"

#include <stdlib.h>
#include <string.h>
#include <wchar.h>

// Back operator new/delete with malloc so the spike links without the C++
// runtime (compiled -fno-exceptions -fno-rtti). All our allocations are tiny
// COM handlers + the host struct.
void *operator new(size_t n) { return malloc(n ? n : 1); }
void *operator new[](size_t n) { return malloc(n ? n : 1); }
void operator delete(void *p) noexcept { free(p); }
void operator delete[](void *p) noexcept { free(p); }
void operator delete(void *p, size_t) noexcept { free(p); }
void operator delete[](void *p, size_t) noexcept { free(p); }

// ---- UTF-8 <-> UTF-16 helpers (caller frees) --------------------------------

// Widen a (possibly non-NUL-terminated) UTF-8 span to a NUL-terminated wide
// string on the heap. Returns NULL on allocation failure.
static wchar_t *widen(const char *s, int len) {
    int n = (len > 0) ? MultiByteToWideChar(CP_UTF8, 0, s, len, nullptr, 0) : 0;
    wchar_t *w = (wchar_t *)malloc((size_t)(n + 1) * sizeof(wchar_t));
    if (!w) return nullptr;
    if (n > 0) MultiByteToWideChar(CP_UTF8, 0, s, len, w, n);
    w[n] = 0;
    return w;
}

// Narrow a NUL-terminated wide string to a UTF-8 buffer. *out_len receives the
// byte length (excluding the NUL we append). Returns NULL on failure.
static char *narrow(const wchar_t *w, size_t *out_len) {
    int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
    if (n <= 0) { *out_len = 0; return nullptr; }
    char *s = (char *)malloc((size_t)n);
    if (!s) { *out_len = 0; return nullptr; }
    WideCharToMultiByte(CP_UTF8, 0, w, -1, s, n, nullptr, nullptr);
    *out_len = (size_t)(n - 1); // exclude trailing NUL
    return s;
}

// ---- Host state -------------------------------------------------------------

struct WV2Host {
    HWND hwnd = nullptr;
    ICoreWebView2Controller *controller = nullptr;
    ICoreWebView2 *webview = nullptr;
    verve_bridge_cb bridge = nullptr;
    void *bridge_ctx = nullptr;
    wchar_t *pending_html = nullptr; // queued until controller is ready
    wchar_t *pending_url = nullptr;  // queued until controller is ready
    bool ready = false;

    // Bundle 2: min/max track-size constraints, enforced in WM_GETMINMAXINFO.
    // 0 = unconstrained for that axis.
    uint32_t min_w = 0, min_h = 0, max_w = 0, max_h = 0;

    // Bundle 2: fullscreen save/restore state. saved_style/exstyle + placement
    // captured on enter, replayed on exit.
    bool is_fullscreen = false;
    LONG saved_style = 0;
    LONG saved_exstyle = 0;
    WINDOWPLACEMENT saved_placement = {};

    // Bundle 3: OS theme-change callback. Fired from WM_SETTINGCHANGE when the
    // broadcast area is "ImmersiveColorSet" (the light/dark toggle signal).
    verve_color_scheme_cb color_scheme_cb = nullptr;
    void *color_scheme_ctx = nullptr;

    // Bundle 4: lifecycle/event callbacks. resize fired from WM_SIZE, focus
    // from WM_ACTIVATE, close from WM_CLOSE (close_cb returns 0 => veto).
    verve_resize_cb resize_cb = nullptr;
    void *resize_ctx = nullptr;
    verve_focus_cb focus_cb = nullptr;
    void *focus_ctx = nullptr;
    verve_close_cb close_cb = nullptr;
    void *close_ctx = nullptr;
    verve_drag_drop_cb drag_drop_cb = nullptr;
    void *drag_drop_ctx = nullptr;

    // Bundle 4: OLE drag-drop registration. The drop target is lazily created
    // and RegisterDragDrop'd when a handler is first set; revoked on teardown
    // or when the handler is cleared.
    IDropTarget *drop_target = nullptr;
    bool drop_registered = false;

    // Bundle 8: server-side UI Automation provider. Ports the legacy
    // windows.zig IRawElementProviderSimple: help text -> UIA_HelpTextPropertyId,
    // role description -> UIA_LocalizedControlTypePropertyId, subrole ->
    // UIA_ControlTypePropertyId / UIA_IsDialogPropertyId. The strings/enum are
    // read live by the provider on each UIA query; the setters just swap them.
    // The provider is created lazily on the first WM_GETOBJECT and released in
    // wv2_destroy. NULL/0 slots make the property report its default.
    wchar_t *a11y_help = nullptr;      // UIA HelpText (owned, free on destroy)
    wchar_t *a11y_role_desc = nullptr; // UIA LocalizedControlType (owned)
    int a11y_subrole = 0;              // AccessibilitySubrole enum ordinal
    IUnknown *a11y_provider = nullptr; // RawElementProvider, lazily created

    // Asset serving via AddWebResourceRequestedFilter. env is retained so
    // CreateWebResourceResponse is available inside the handler. scheme_filter
    // is the wide "scheme://*" pattern (owned, freed in wv2_destroy).
    ICoreWebView2Environment *env = nullptr;
    verve_scheme_cb scheme_cb = nullptr;
    void *scheme_ctx = nullptr;
    wchar_t *scheme_filter = nullptr;
    EventRegistrationToken scheme_token = {};
};

// Read HKCU\...\Personalize\AppsUseLightTheme. 1 = light, 0 = dark, missing =
// unknown — mirrors the legacy windows.zig readColorSchemeRegistry(). Shared by
// wv2_color_scheme and the WM_SETTINGCHANGE dispatch.
static int read_color_scheme() {
    DWORD data = 0;
    DWORD size = sizeof(data);
    LSTATUS r = RegGetValueW(
        HKEY_CURRENT_USER,
        L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
        L"AppsUseLightTheme", RRF_RT_REG_DWORD, nullptr, &data, &size);
    if (r != ERROR_SUCCESS) return 2; // unknown
    return data == 0 ? 1 /* dark */ : 0 /* light */;
}

// Pure-virtual placeholder: COM interface vtables reference it for unimplemented
// slots. libc++abi normally supplies it; we compile without the C++ runtime.
extern "C" void __cxa_pure_virtual() {}

// ---- IUnknown boilerplate (shared by every handler) -------------------------

// IID_IUnknown {00000000-0000-0000-C000-000000000046}. Declared locally so we
// don't depend on mingw's libuuid (and we avoid __uuidof, which mingw reroutes
// through a template specialization the MS-authored WebView2.h never provides).
static const IID kIID_IUnknown = {
    0x00000000, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}};

// Reference-counted COM object base. QueryInterface accepts IUnknown plus the
// one derived interface IID supplied by each subclass. WebView2.h exposes each
// interface IID as a `selectany` constant named IID_<interface>.
#define WV2_IUNKNOWN_IMPL(IFACE)                                               \
    LONG ref_ = 1;                                                             \
    ULONG STDMETHODCALLTYPE AddRef() override {                               \
        return (ULONG)InterlockedIncrement(&ref_);                            \
    }                                                                         \
    ULONG STDMETHODCALLTYPE Release() override {                             \
        LONG c = InterlockedDecrement(&ref_);                                 \
        if (c == 0) delete this;                                              \
        return (ULONG)c;                                                      \
    }                                                                         \
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **ppv)         \
        override {                                                            \
        if (!ppv) return E_POINTER;                                           \
        if (IsEqualGUID(riid, kIID_IUnknown) ||                               \
            IsEqualGUID(riid, IID_##IFACE)) {                                 \
            *ppv = static_cast<IFACE *>(this);                                \
            AddRef();                                                         \
            return S_OK;                                                      \
        }                                                                     \
        *ppv = nullptr;                                                       \
        return E_NOINTERFACE;                                                 \
    }

// Same as WV2_IUNKNOWN_IMPL but Queries against an explicitly-supplied IID
// constant (for interfaces whose IID we declare locally rather than via
// WebView2.h's IID_<interface> — e.g. IRawElementProviderSimple).
#define WV2_IUNKNOWN_IMPL_GUID(IFACE, IIDVAR)                                  \
    LONG ref_ = 1;                                                             \
    ULONG STDMETHODCALLTYPE AddRef() override {                               \
        return (ULONG)InterlockedIncrement(&ref_);                            \
    }                                                                         \
    ULONG STDMETHODCALLTYPE Release() override {                             \
        LONG c = InterlockedDecrement(&ref_);                                 \
        if (c == 0) delete this;                                              \
        return (ULONG)c;                                                      \
    }                                                                         \
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **ppv)         \
        override {                                                            \
        if (!ppv) return E_POINTER;                                           \
        if (IsEqualGUID(riid, kIID_IUnknown) ||                               \
            IsEqualGUID(riid, (IIDVAR))) {                                    \
            *ppv = static_cast<IFACE *>(this);                                \
            AddRef();                                                         \
            return S_OK;                                                      \
        }                                                                     \
        *ppv = nullptr;                                                       \
        return E_NOINTERFACE;                                                 \
    }

// ---- WebMessageReceived: JS -> host -> Zig ----------------------------------

// Bridge messages are delivered to the Zig handler via a POSTED window message
// (WM_VERVE_BRIDGE), not synchronously inside WebView2's WebMessageReceived
// callback. WebView2 serializes its event callbacks and will not fire an async
// completion (e.g. GetCookies) while one of its event handlers is still on the
// stack. A bridge handler that synchronously waits on such a completion —
// cookies().get()/delete() pump the message loop until GetCookies finishes —
// would therefore deadlock. Running the handler from WndProc (one message-loop
// turn later) takes the WebView2 event off the stack so completions can fire.
static const UINT WM_VERVE_BRIDGE = WM_APP + 0x21;
struct BridgeMsg {
    uint8_t *data; // malloc'd UTF-8, freed in WndProc after dispatch
    size_t len;
};

// Tray callback message. Must match desktop/tray.zig's WM_VERVE_TRAY, which the
// Zig side writes into NOTIFYICONDATAW.uCallbackMessage so Shell32 routes tray
// mouse events through this window's WndProc. WM_USER + 100, mirroring the legacy
// windows.zig backend.
static const UINT WM_VERVE_TRAY = WM_USER + 100;

// Process-global tray dispatch hooks (v1 single-tray-per-process). Registered by
// desktop.tray via wv2_set_tray_dispatch; invoked from WndProc on WM_COMMAND
// (tray id block) and WM_VERVE_TRAY. NULL until a tray is created.
static verve_tray_command_cb g_tray_command = nullptr;
static verve_tray_message_cb g_tray_message = nullptr;

class WebMessageHandler : public ICoreWebView2WebMessageReceivedEventHandler {
    WV2Host *host_;

public:
    explicit WebMessageHandler(WV2Host *h) : host_(h) {}
    WV2_IUNKNOWN_IMPL(ICoreWebView2WebMessageReceivedEventHandler)

    HRESULT STDMETHODCALLTYPE Invoke(
        ICoreWebView2 * /*sender*/,
        ICoreWebView2WebMessageReceivedEventArgs *args) override {
        if (!host_->bridge) return S_OK;
        LPWSTR msg = nullptr;
        if (SUCCEEDED(args->TryGetWebMessageAsString(&msg)) && msg) {
            size_t len = 0;
            char *utf8 = narrow(msg, &len);
            if (utf8) {
                // Defer to WndProc (see WM_VERVE_BRIDGE note above). Ownership of
                // `utf8` transfers to the posted message on success.
                auto *bm = (BridgeMsg *)malloc(sizeof(BridgeMsg));
                if (bm) {
                    bm->data = (uint8_t *)utf8;
                    bm->len = len;
                    if (!PostMessageW(host_->hwnd, WM_VERVE_BRIDGE, 0,
                                      (LPARAM)bm)) {
                        free(utf8);
                        free(bm);
                    }
                } else {
                    free(utf8);
                }
            }
            CoTaskMemFree(msg);
        }
        return S_OK;
    }
};

// ---- ExecuteScript completion (no-op, just satisfies the API) ---------------

class ExecScriptHandler
    : public ICoreWebView2ExecuteScriptCompletedHandler {
public:
    WV2_IUNKNOWN_IMPL(ICoreWebView2ExecuteScriptCompletedHandler)
    HRESULT STDMETHODCALLTYPE Invoke(HRESULT /*code*/,
                                     LPCWSTR /*result*/) override {
        return S_OK;
    }
};

// ---- Scheme request handler: serves verve:// assets ------------------------

class SchemeRequestHandler
    : public ICoreWebView2WebResourceRequestedEventHandler {
    WV2Host *host_;

public:
    explicit SchemeRequestHandler(WV2Host *h) : host_(h) {}
    WV2_IUNKNOWN_IMPL(ICoreWebView2WebResourceRequestedEventHandler)

    HRESULT STDMETHODCALLTYPE Invoke(
        ICoreWebView2 *,
        ICoreWebView2WebResourceRequestedEventArgs *args) override
    {
        ICoreWebView2WebResourceRequest *req = nullptr;
        args->get_Request(&req);
        if (!req) return S_OK;

        LPWSTR uri_w = nullptr;
        req->get_Uri(&uri_w);
        req->Release();
        if (!uri_w) return S_OK;

        // Convert URI to UTF-8, then extract the path after "://app/".
        size_t uri_len = 0;
        char *uri_u8 = narrow(uri_w, &uri_len);
        CoTaskMemFree(uri_w);
        if (!uri_u8) return S_OK;

        const char *auth = "://app/";
        const size_t auth_len = 7;
        const char *path = uri_u8;
        size_t path_len = uri_len;
        for (size_t i = 0; i + auth_len <= uri_len; i++) {
            if (memcmp(uri_u8 + i, auth, auth_len) == 0) {
                path = uri_u8 + i + auth_len;
                path_len = uri_len - (i + auth_len);
                break;
            }
        }

        const uint8_t *bytes = nullptr;
        size_t bytes_len = 0;
        const char *ct = nullptr;
        int found = host_->scheme_cb(host_->scheme_ctx, path, path_len,
                                      &bytes, &bytes_len, &ct);
        free(uri_u8);

        ICoreWebView2WebResourceResponse *resp = nullptr;
        if (found && bytes) {
            // SHCreateMemStream copies the bytes into the IStream.
            IStream *stream = SHCreateMemStream(bytes, (UINT)bytes_len);
            const char *ct_str = ct ? ct : "application/octet-stream";
            size_t ct_slen = strlen(ct_str);
            // Build "Content-Type: <ct>" header.
            char *hdr_u8 = (char *)malloc(14 + ct_slen + 1);
            if (hdr_u8) {
                memcpy(hdr_u8, "Content-Type: ", 14);
                memcpy(hdr_u8 + 14, ct_str, ct_slen + 1);
            }
            wchar_t *hdr_w = hdr_u8 ? widen(hdr_u8, (int)(14 + ct_slen)) : nullptr;
            free(hdr_u8);
            host_->env->CreateWebResourceResponse(stream, 200, L"OK",
                                                   hdr_w ? hdr_w : L"", &resp);
            free(hdr_w);
            if (stream) stream->Release();
        } else {
            host_->env->CreateWebResourceResponse(nullptr, 404, L"Not Found",
                                                   L"", &resp);
        }
        if (resp) {
            args->put_Response(resp);
            resp->Release();
        }
        return S_OK;
    }
};

// ---- Controller created: wire up the webview --------------------------------

class ControllerHandler
    : public ICoreWebView2CreateCoreWebView2ControllerCompletedHandler {
    WV2Host *host_;

public:
    explicit ControllerHandler(WV2Host *h) : host_(h) {}
    WV2_IUNKNOWN_IMPL(ICoreWebView2CreateCoreWebView2ControllerCompletedHandler)

    HRESULT STDMETHODCALLTYPE Invoke(
        HRESULT result, ICoreWebView2Controller *controller) override {
        if (FAILED(result) || !controller) return S_OK;

        host_->controller = controller;
        controller->AddRef();
        controller->get_CoreWebView2(&host_->webview);

        // Fill the client area.
        RECT rc;
        GetClientRect(host_->hwnd, &rc);
        controller->put_Bounds(rc);

        if (host_->webview) {
            // Bridge: expose window.verve.post(msg) -> postMessage.
            host_->webview->AddScriptToExecuteOnDocumentCreated(
                L"window.verve = { post: function (m) {"
                L" window.chrome.webview.postMessage(String(m)); } };",
                nullptr);

            EventRegistrationToken token;
            auto *wmh = new WebMessageHandler(host_);
            host_->webview->add_WebMessageReceived(wmh, &token);
            wmh->Release(); // add_* took its own ref

            // Register custom URL scheme handler for asset serving.
            // Use ICoreWebView2_22::AddWebResourceRequestedFilterWithRequestSourceKinds
            // with SOURCE_KINDS_ALL so the filter intercepts the navigation document
            // itself (not just sub-resource requests). Fall back to the base filter
            // on older runtimes that don't QI to _22.
            if (host_->scheme_cb && host_->scheme_filter && host_->env) {
                ICoreWebView2_22 *wv22 = nullptr;
                if (SUCCEEDED(host_->webview->QueryInterface(
                        IID_ICoreWebView2_22, (void **)&wv22))) {
                    wv22->AddWebResourceRequestedFilterWithRequestSourceKinds(
                        host_->scheme_filter,
                        COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL,
                        COREWEBVIEW2_WEB_RESOURCE_REQUEST_SOURCE_KINDS_ALL);
                    wv22->Release();
                } else {
                    host_->webview->AddWebResourceRequestedFilter(
                        host_->scheme_filter,
                        COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL);
                }
                auto *srh = new SchemeRequestHandler(host_);
                host_->webview->add_WebResourceRequested(srh, &host_->scheme_token);
                srh->Release();
            }

            if (host_->pending_html) {
                host_->webview->NavigateToString(host_->pending_html);
                free(host_->pending_html);
                host_->pending_html = nullptr;
            }
            if (host_->pending_url) {
                host_->webview->Navigate(host_->pending_url);
                free(host_->pending_url);
                host_->pending_url = nullptr;
            }
        }

        host_->ready = true;
        controller->put_IsVisible(TRUE);
        return S_OK;
    }
};

// ---- Environment created: create the controller -----------------------------

class EnvHandler
    : public ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler {
    WV2Host *host_;

public:
    explicit EnvHandler(WV2Host *h) : host_(h) {}
    WV2_IUNKNOWN_IMPL(ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler)

    HRESULT STDMETHODCALLTYPE Invoke(HRESULT result,
                                     ICoreWebView2Environment *env) override {
        if (FAILED(result) || !env) return S_OK;
        // Retain env so SchemeRequestHandler can call CreateWebResourceResponse.
        host_->env = env;
        env->AddRef();
        auto *ch = new ControllerHandler(host_);
        env->CreateCoreWebView2Controller(host_->hwnd, ch);
        ch->Release();
        return S_OK;
    }
};

// ---- Bundle 6: cookies — async GetCookies completion handler ----------------

// ICoreWebView2CookieManager::GetCookies is the only async cookie call: it
// delivers an ICoreWebView2CookieList to this handler on the UI thread. We
// sync-wrap by spinning a nested Win32 message pump until `done_` flips (same
// model the legacy windows.zig backend used). On Invoke we AddRef the list so
// it outlives the callback frame; the caller Releases after iterating.
class GetCookiesHandler : public ICoreWebView2GetCookiesCompletedHandler {
public:
    WV2_IUNKNOWN_IMPL(ICoreWebView2GetCookiesCompletedHandler)

    ICoreWebView2CookieList *list_ = nullptr;
    bool done_ = false;

    HRESULT STDMETHODCALLTYPE Invoke(HRESULT error_code,
                                     ICoreWebView2CookieList *result) override {
        if (SUCCEEDED(error_code) && result) {
            result->AddRef();
            list_ = result;
        }
        done_ = true;
        return S_OK;
    }
};

// ---- Bundle 8: CapturePreview completion ------------------------------------

// Async completion for ICoreWebView2::CapturePreview, modeled on
// GetCookiesHandler: Invoke records the HRESULT and flips done_, and the caller
// pump_until()s the nested Win32 message loop until it fires. The PNG bytes land
// in the IStream the caller passed to CapturePreview; this handler only carries
// the completion signal + error code.
class CapturePreviewHandler
    : public ICoreWebView2CapturePreviewCompletedHandler {
public:
    WV2_IUNKNOWN_IMPL(ICoreWebView2CapturePreviewCompletedHandler)

    HRESULT error_ = S_OK;
    bool done_ = false;

    HRESULT STDMETHODCALLTYPE Invoke(HRESULT error_code) override {
        error_ = error_code;
        done_ = true;
        return S_OK;
    }
};

// ---- Bundle 4: OLE drag-drop (IDropTarget) ----------------------------------

// IID_IDropTarget {00000122-0000-0000-C000-000000000046}. Declared locally to
// avoid depending on mingw's libuuid (same rationale as kIID_IUnknown).
static const IID kIID_IDropTarget = {
    0x00000122, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}};

// Minimal file-only drop target: advertises DROPEFFECT_COPY on enter/over, and
// on Drop extracts CF_HDROP paths (UTF-8), NUL-joins them, and hands the buffer
// to the host's drag_drop_cb. Models the legacy windows.zig IDropTarget, but as
// a real C++ COM class so the compiler emits the vtable.
class DropTarget : public IDropTarget {
    WV2Host *host_;

public:
    explicit DropTarget(WV2Host *h) : host_(h) {}

    // IUnknown — QueryInterface accepts IUnknown + IDropTarget.
    LONG ref_ = 1;
    ULONG STDMETHODCALLTYPE AddRef() override {
        return (ULONG)InterlockedIncrement(&ref_);
    }
    ULONG STDMETHODCALLTYPE Release() override {
        LONG c = InterlockedDecrement(&ref_);
        if (c == 0) delete this;
        return (ULONG)c;
    }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **ppv) override {
        if (!ppv) return E_POINTER;
        if (IsEqualGUID(riid, kIID_IUnknown) ||
            IsEqualGUID(riid, kIID_IDropTarget)) {
            *ppv = static_cast<IDropTarget *>(this);
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }

    HRESULT STDMETHODCALLTYPE DragEnter(IDataObject * /*obj*/, DWORD /*ks*/,
                                        POINTL /*pt*/, DWORD *effect) override {
        if (effect) *effect = DROPEFFECT_COPY;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE DragOver(DWORD /*ks*/, POINTL /*pt*/,
                                       DWORD *effect) override {
        if (effect) *effect = DROPEFFECT_COPY;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE DragLeave() override { return S_OK; }

    HRESULT STDMETHODCALLTYPE Drop(IDataObject *obj, DWORD /*ks*/, POINTL /*pt*/,
                                   DWORD *effect) override {
        if (effect) *effect = DROPEFFECT_NONE;
        if (!host_ || !host_->drag_drop_cb || !obj) return S_OK;

        FORMATETC fmt = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
        STGMEDIUM medium = {};
        if (FAILED(obj->GetData(&fmt, &medium))) return S_OK;

        HDROP hdrop = (HDROP)medium.hGlobal;
        if (hdrop) {
            UINT n = DragQueryFileW(hdrop, 0xFFFFFFFF, nullptr, 0);
            // Build one UTF-8 buffer of all paths joined by '\0'. Grow as we go.
            char *out = nullptr;
            size_t out_len = 0, out_cap = 0;
            for (UINT i = 0; i < n; ++i) {
                UINT wlen = DragQueryFileW(hdrop, i, nullptr, 0);
                wchar_t *wbuf =
                    (wchar_t *)malloc((size_t)(wlen + 1) * sizeof(wchar_t));
                if (!wbuf) continue;
                DragQueryFileW(hdrop, i, wbuf, wlen + 1);
                int u8n = WideCharToMultiByte(CP_UTF8, 0, wbuf, (int)wlen,
                                              nullptr, 0, nullptr, nullptr);
                size_t need = out_len + (size_t)u8n + 1; // path + NUL sep
                if (need > out_cap) {
                    size_t ncap = out_cap ? out_cap * 2 : 256;
                    while (ncap < need) ncap *= 2;
                    char *grown = (char *)realloc(out, ncap);
                    if (!grown) {
                        free(wbuf);
                        break;
                    }
                    out = grown;
                    out_cap = ncap;
                }
                if (u8n > 0)
                    WideCharToMultiByte(CP_UTF8, 0, wbuf, (int)wlen,
                                        out + out_len, u8n, nullptr, nullptr);
                out_len += (size_t)u8n;
                out[out_len++] = '\0'; // separator between paths
                free(wbuf);
            }
            if (out && out_len) {
                // Deliver without the trailing separator counted, so the Zig
                // splitter sees N records (it splits on '\0').
                host_->drag_drop_cb(host_->drag_drop_ctx, (const uint8_t *)out,
                                    out_len - 1);
            }
            free(out);
        }
        ReleaseStgMedium(&medium);
        if (effect) *effect = DROPEFFECT_COPY;
        return S_OK;
    }
};

// ---- Server-side UI Automation provider (ports legacy windows.zig) ----------
//
// mingw's bundled SDK ships <uiautomation.h>; but to keep this file robust on
// older mingw trees (and to avoid pulling the whole client-side UIA surface) we
// hand-declare the minimal pieces the same way the file declares other missing
// SDK bits: the IRawElementProviderSimple interface, the ProviderOptions enum,
// the handful of UIA_*PropertyId integer constants, and the two link entry
// points. PORTED VALUES MATCH legacy src/desktop/windows.zig exactly.
#if defined(__has_include)
#  if __has_include(<uiautomation.h>)
#    define VERVE_HAVE_UIAUTOMATION 1
#  endif
#endif

#ifdef VERVE_HAVE_UIAUTOMATION
#  include <uiautomation.h>
// The header declares get_ProviderOptions(enum ProviderOptions*); our override
// must match exactly or the pure virtual stays unimplemented (abstract class).
#  define VERVE_PROVIDER_OPTIONS enum ProviderOptions
#else
// Minimal hand-declared surface (uiautomationcore.h / uiautomationclient.h).
typedef int PATTERNID;        // UIA pattern id (we only ever ignore it)
typedef int PROPERTYID;       // UIA property id
enum ProviderOptions {
    ProviderOptions_ServerSideProvider = 0x1,
};
#  define VERVE_PROVIDER_OPTIONS enum ProviderOptions

// IRawElementProviderSimple {d6dd68d1-86fd-4332-8666-9abedea2d24c}.
struct IRawElementProviderSimple : public IUnknown {
    virtual HRESULT STDMETHODCALLTYPE get_ProviderOptions(enum ProviderOptions *pRetVal) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetPatternProvider(PATTERNID patternId, IUnknown **pRetVal) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetPropertyValue(PROPERTYID propertyId, VARIANT *pRetVal) = 0;
    virtual HRESULT STDMETHODCALLTYPE get_HostRawElementProvider(IRawElementProviderSimple **pRetVal) = 0;
};
#endif // VERVE_HAVE_UIAUTOMATION

// IID_IRawElementProviderSimple, declared locally (mingw's libuuid coverage of
// UIA is spotty and we avoid __uuidof — same rationale as kIID_IUnknown above).
static const IID kIID_IRawElementProviderSimple = {
    0xd6dd68d1, 0x86fd, 0x4332,
    {0x86, 0x66, 0x9a, 0xbe, 0xde, 0xa2, 0xd2, 0x4c}};

// UIA property ids (uiautomationclient.h) and the dialog/window control-type
// constants — ported verbatim from legacy windows.zig.
#ifndef UIA_ControlTypePropertyId
#  define UIA_ControlTypePropertyId 30003
#endif
#ifndef UIA_LocalizedControlTypePropertyId
#  define UIA_LocalizedControlTypePropertyId 30004
#endif
#ifndef UIA_HelpTextPropertyId
#  define UIA_HelpTextPropertyId 30013
#endif
#ifndef UIA_IsDialogPropertyId
#  define UIA_IsDialogPropertyId 30174
#endif
#ifndef UIA_WindowControlTypeId
#  define UIA_WindowControlTypeId 50032
#endif

// UiaRootObjectId / the two link entry points. The real header declares these
// in uiautomationcoreapi.h; only hand-declare when the header is absent. Both
// live in uiautomationcore.dll (linked in build.zig).
#ifndef VERVE_HAVE_UIAUTOMATION
#  ifndef UiaRootObjectId
#    define UiaRootObjectId (-25)
#  endif
extern "C" LRESULT WINAPI UiaReturnRawElementProvider(HWND hwnd, WPARAM wParam,
                                                      LPARAM lParam,
                                                      IRawElementProviderSimple *el);
extern "C" HRESULT WINAPI UiaHostProviderFromHwnd(HWND hwnd,
                                                  IRawElementProviderSimple **ppProvider);
#endif

// The provider holds a back-pointer to its host and reads the live a11y state on
// each query (matching legacy's read-on-demand model). Subrole ordinal: 0
// standard, 1 dialog, 2 system_dialog, 3 floating (AccessibilitySubrole order).
class RawElementProvider : public IRawElementProviderSimple {
public:
    WV2_IUNKNOWN_IMPL_GUID(IRawElementProviderSimple, kIID_IRawElementProviderSimple)

    explicit RawElementProvider(WV2Host *host) : host_(host) {}

    HRESULT STDMETHODCALLTYPE get_ProviderOptions(VERVE_PROVIDER_OPTIONS *pRetVal) override {
        if (!pRetVal) return E_POINTER;
        *pRetVal = ProviderOptions_ServerSideProvider;
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE GetPatternProvider(PATTERNID, IUnknown **pRetVal) override {
        if (!pRetVal) return E_POINTER;
        *pRetVal = nullptr; // no control patterns; window chrome only
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE GetPropertyValue(PROPERTYID propertyId,
                                               VARIANT *pRetVal) override {
        if (!pRetVal) return E_POINTER;
        VariantInit(pRetVal);
        pRetVal->vt = VT_EMPTY;
        if (!host_) return S_OK;
        switch (propertyId) {
        case UIA_LocalizedControlTypePropertyId:
            if (host_->a11y_role_desc) {
                BSTR b = SysAllocString(host_->a11y_role_desc);
                if (b) { pRetVal->vt = VT_BSTR; pRetVal->bstrVal = b; }
            }
            break;
        case UIA_HelpTextPropertyId:
            if (host_->a11y_help) {
                BSTR b = SysAllocString(host_->a11y_help);
                if (b) { pRetVal->vt = VT_BSTR; pRetVal->bstrVal = b; }
            }
            break;
        case UIA_ControlTypePropertyId:
            // All window chrome reports as a Window control type; dialog vs.
            // plain window is differentiated via UIA_IsDialogPropertyId below.
            pRetVal->vt = VT_I4;
            pRetVal->lVal = UIA_WindowControlTypeId;
            break;
        case UIA_IsDialogPropertyId:
            pRetVal->vt = VT_BOOL;
            pRetVal->boolVal = is_dialog() ? VARIANT_TRUE : VARIANT_FALSE;
            break;
        default:
            break; // leave VT_EMPTY
        }
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE
    get_HostRawElementProvider(IRawElementProviderSimple **pRetVal) override {
        if (!pRetVal) return E_POINTER;
        *pRetVal = nullptr;
        if (host_ && host_->hwnd) UiaHostProviderFromHwnd(host_->hwnd, pRetVal);
        return S_OK;
    }

private:
    bool is_dialog() const {
        return host_ && (host_->a11y_subrole == 1 /* dialog */ ||
                         host_->a11y_subrole == 2 /* system_dialog */);
    }
    WV2Host *host_;
};

// Register (or revoke) the host's HWND as an OLE drop target. RegisterDragDrop
// requires the calling thread to have an OLE apartment, so OleInitialize first.
static void drop_register(WV2Host *host, bool on) {
    if (!host || !host->hwnd) return;
    if (on) {
        if (host->drop_registered) return;
        OleInitialize(nullptr); // inits the OLE apartment once per UI thread for RegisterDragDrop; left to thread/process teardown (no explicit OleUninitialize)
        if (!host->drop_target) host->drop_target = new DropTarget(host);
        if (SUCCEEDED(RegisterDragDrop(host->hwnd, host->drop_target)))
            host->drop_registered = true;
    } else {
        if (!host->drop_registered) return;
        RevokeDragDrop(host->hwnd);
        host->drop_registered = false;
    }
}

// ---- Win32 window -----------------------------------------------------------

static const wchar_t *kWindowClass = L"VerveWv2SpikeWindow";

// Bind `hwnd` to the host window, early-returning VAL if there is none.
#define WV2_REQUIRE_HWND(host, VAL) \
    HWND hwnd = (host) ? (host)->hwnd : nullptr; \
    if (!hwnd) return VAL;

// Bind `wv` to the host's ICoreWebView2, early-returning VAL if there is none
// (host null, or the controller/webview not yet created). Parallel to
// WV2_REQUIRE_HWND; used by the navigation + event-routing methods.
#define WV2_REQUIRE_WEBVIEW(host, VAL) \
    ICoreWebView2 *wv = (host) ? (host)->webview : nullptr; \
    if (!wv) return VAL;

static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    WV2Host *host =
        (WV2Host *)GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    switch (msg) {
    case WM_SIZE:
        if (host && host->controller) {
            RECT rc;
            GetClientRect(hwnd, &rc);
            host->controller->put_Bounds(rc);
        }
        // Then fire the app resize handler. lParam low word = client width,
        // high word = client height (matches legacy windows.zig WM_SIZE).
        if (host && host->resize_cb) {
            host->resize_cb(host->resize_ctx, (uint32_t)LOWORD(lp),
                            (uint32_t)HIWORD(lp));
        }
        return 0;
    case WM_GETMINMAXINFO:
        // Apply min/max track-size constraints when set; otherwise fall
        // through to default sizing behavior.
        if (host && (host->min_w || host->min_h || host->max_w || host->max_h)) {
            MINMAXINFO *mmi = (MINMAXINFO *)lp;
            if (host->min_w) mmi->ptMinTrackSize.x = (LONG)host->min_w;
            if (host->min_h) mmi->ptMinTrackSize.y = (LONG)host->min_h;
            if (host->max_w) mmi->ptMaxTrackSize.x = (LONG)host->max_w;
            if (host->max_h) mmi->ptMaxTrackSize.y = (LONG)host->max_h;
            return 0;
        }
        return DefWindowProcW(hwnd, msg, wp, lp);
    case WM_SETTINGCHANGE:
        // lp -> LPCWSTR area name. Windows broadcasts "ImmersiveColorSet" when
        // the user flips light/dark in Settings -> Personalization -> Colors.
        if (host && host->color_scheme_cb && lp) {
            const wchar_t *area = (const wchar_t *)lp;
            if (wcscmp(area, L"ImmersiveColorSet") == 0) {
                host->color_scheme_cb(host->color_scheme_ctx,
                                      read_color_scheme());
            }
        }
        return 0;
    case WM_ACTIVATE:
        // wParam low word: 0 = inactive (blur), non-zero = activated (focus).
        // Matches legacy windows.zig WM_ACTIVATE dispatch.
        if (host && host->focus_cb) {
            host->focus_cb(host->focus_ctx, (LOWORD(wp) != 0) ? 1 : 0);
        }
        return 0;
    case WM_CLOSE:
        // Title-bar X / system Close. Run the veto handler if present: a 0
        // return vetoes (keep the window alive, return 0 here). Otherwise fall
        // through to DefWindowProcW, which DestroyWindows -> WM_DESTROY ->
        // PostQuitMessage. Matches legacy windows.zig WM_CLOSE.
        if (host && host->close_cb) {
            if (host->close_cb(host->close_ctx) == 0) return 0; // vetoed
        }
        return DefWindowProcW(hwnd, msg, wp, lp);
    case WM_VERVE_BRIDGE: {
        // Deferred bridge delivery, posted from WebMessageHandler::Invoke so the
        // Zig handler runs outside WebView2's event callback (see note there).
        BridgeMsg *bm = (BridgeMsg *)lp;
        if (bm) {
            if (host && host->bridge)
                host->bridge(host->bridge_ctx, bm->data, bm->len);
            free(bm->data);
            free(bm);
        }
        return 0;
    }
    case WM_DESTROY:
        if (host && host->drop_registered) {
            RevokeDragDrop(hwnd);
            host->drop_registered = false;
        }
        // Release the UIA provider here too: WM_DESTROY fires when the window
        // goes away regardless of how (X, close(), Alt+F4); wv2_destroy covers
        // the explicit-teardown path.
        if (host && host->a11y_provider) {
            host->a11y_provider->Release();
            host->a11y_provider = nullptr;
        }
        PostQuitMessage(0);
        return 0;
    case WM_GETOBJECT:
        // Hand assistive tech (Narrator/NVDA) our server-side UIA provider for
        // the window root; all other object ids fall through to default. The
        // provider is created once and cached on the host (released in
        // WM_DESTROY / wv2_destroy). Ports legacy windows.zig WM_GETOBJECT.
        if (host && (DWORD)lp == (DWORD)UiaRootObjectId) {
            if (!host->a11y_provider)
                host->a11y_provider = new RawElementProvider(host);
            return UiaReturnRawElementProvider(
                hwnd, wp, lp,
                static_cast<IRawElementProviderSimple *>(
                    static_cast<RawElementProvider *>(host->a11y_provider)));
        }
        return DefWindowProcW(hwnd, msg, wp, lp);
    case WM_COMMAND: {
        // Tray menu IDs live in the 0xC000 block (mirrors legacy windows.zig).
        // Forward them to the Zig tray dispatch; everything else is not ours.
        uint16_t id = (uint16_t)(wp & 0xFFFF);
        if ((id & 0xF000) == 0xC000 && g_tray_command) {
            g_tray_command((void *)hwnd, id);
            return 0;
        }
        return DefWindowProcW(hwnd, msg, wp, lp);
    }
    case WM_VERVE_TRAY:
        // Shell32 fires this on tray-icon mouse events once desktop.tray has
        // installed the NOTIFYICONDATAW callback. No-op if no tray exists.
        if (g_tray_message)
            g_tray_message((void *)hwnd, (size_t)wp, (intptr_t)lp);
        return 0;
    default:
        return DefWindowProcW(hwnd, msg, wp, lp);
    }
}

static HWND create_window(WV2Host *host, const wchar_t *title, int w, int h) {
    HINSTANCE inst = GetModuleHandleW(nullptr);
    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = WndProc;
    wc.hInstance = inst;
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.lpszClassName = kWindowClass;
    RegisterClassExW(&wc); // ignore "already registered" on re-entry

    HWND hwnd = CreateWindowExW(
        0, kWindowClass, title, WS_OVERLAPPEDWINDOW, CW_USEDEFAULT,
        CW_USEDEFAULT, w, h, nullptr, nullptr, inst, nullptr);
    if (hwnd) SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)host);
    return hwnd;
}

// ---- WebView2 loader (resolve entry point at runtime) -----------------------

typedef HRESULT(STDAPICALLTYPE *PFN_CreateEnv)(
    PCWSTR browserExecutableFolder, PCWSTR userDataFolder,
    ICoreWebView2EnvironmentOptions *environmentOptions,
    ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *handler);

// ---- Bundle 6: cookie helpers (static) --------------------------------------

// Acquire the per-profile cookie manager off the webview. The CookieManager
// hangs off ICoreWebView2_2 (a later interface version than the base webview),
// reached via QueryInterface. Returns a +1 cookie-manager ref (caller Releases)
// and Releases the ICoreWebView2_2 it queried before returning. NULL when the
// webview isn't ready or the QI / get_CookieManager fails.
static ICoreWebView2CookieManager *cookie_manager(WV2Host *host) {
    if (!host || !host->webview) return nullptr;
    ICoreWebView2_2 *wv2 = nullptr;
    if (FAILED(host->webview->QueryInterface(IID_ICoreWebView2_2,
                                             (void **)&wv2)) ||
        !wv2)
        return nullptr;
    ICoreWebView2CookieManager *mgr = nullptr;
    HRESULT hr = wv2->get_CookieManager(&mgr);
    wv2->Release();
    if (FAILED(hr) || !mgr) return nullptr;
    return mgr;
}

// Spin a nested Win32 message pump until `done` flips. Matches the legacy
// pumpMsgUntilDone: GetMessageW blocks for the next message and we dispatch it,
// so the GetCookies completion (posted to this UI thread) runs and sets `done`.
// A GetMessageW return of <= 0 (WM_QUIT / error) breaks the loop so a failed
// GetCookies can't hang the wait forever.
static void pump_until(const bool *done) {
    MSG msg;
    while (!*done) {
        BOOL got = GetMessageW(&msg, nullptr, 0, 0);
        if (got <= 0) break;
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
}

// Fetch the full cookie list synchronously (kick off async GetCookies, pump to
// completion). Returns a +1 list ref (caller Releases) or NULL. `uri` NULL =>
// all cookies, matching legacy fetchAllCookies.
static ICoreWebView2CookieList *fetch_all_cookies(ICoreWebView2CookieManager *mgr) {
    auto *handler = new GetCookiesHandler();
    if (FAILED(mgr->GetCookies(nullptr, handler))) {
        handler->Release();
        return nullptr;
    }
    pump_until(&handler->done_);
    ICoreWebView2CookieList *list = handler->list_; // +1 from Invoke (or NULL)
    handler->Release();
    return list;
}

// True when `cookie`'s name equals the UTF-8 span (`want`,`wlen`). Compares in
// UTF-16 by widening the wanted name, avoiding a per-cookie narrow alloc.
static bool cookie_name_is(ICoreWebView2Cookie *cookie, const wchar_t *want_w) {
    LPWSTR name = nullptr;
    if (FAILED(cookie->get_Name(&name)) || !name) return false;
    bool eq = (wcscmp(name, want_w) == 0);
    CoTaskMemFree(name);
    return eq;
}

// ---- Bundle 7: clipboard helpers (static) -----------------------------------
//
// Win32 clipboard text/HTML is straight HGLOBAL plumbing; the image path
// transcodes PNG<->32bpp-BGRA DIB through WIC. mingw only DEFINE_GUID-declares
// the WIC GUIDs (no definition, and we avoid __uuidof), so we define the few we
// need locally — same approach as the IUnknown IID above and the legacy Zig
// backend. Offsets/masks are ported byte-for-byte from windows.zig.

static const CLSID kCLSID_WICImagingFactory = {
    0xcacaf262, 0x9370, 0x4615, {0xa1, 0x3b, 0x9f, 0x55, 0x39, 0xda, 0x4c, 0x0a}};
static const IID kIID_IWICImagingFactory = {
    0xec5ec8a9, 0xc395, 0x4314, {0x9c, 0x77, 0x54, 0xd7, 0xa9, 0x35, 0xff, 0x70}};
static const GUID kGUID_WICPixelFormat32bppBGRA = {
    0x6fddc324, 0x4e03, 0x4bfe, {0xb1, 0x85, 0x3d, 0x77, 0x76, 0x8d, 0xc9, 0x0f}};
static const GUID kGUID_ContainerFormatPng = {
    0x1b7cfaf4, 0x713f, 0x473c, {0xbb, 0xcd, 0x61, 0x37, 0x42, 0x5f, 0xae, 0xaf}};

static const UINT kCF_DIB = 8;
static const UINT kCF_DIBV5 = 17;
static const DWORD kBI_RGB = 0;
static const DWORD kBI_BITFIELDS = 3;
static const DWORD kLCS_sRGB = 0x73524742;  // 'sRGB'
static const DWORD kLCS_GM_IMAGES = 4;
// Reject absurd dimensions before any width*height*4 allocation.
static const size_t kMaxImageBytes = 256u * 1024u * 1024u;

// The registered "HTML Format" clipboard format id (process-wide, idempotent).
static UINT cf_html_format() {
    return RegisterClipboardFormatW(L"HTML Format");
}

// Copy `src[0..n]` into a fresh GMEM_MOVEABLE HGLOBAL. Returns NULL on failure.
// Caller GlobalFree's on failure of a subsequent step; SetClipboardData takes
// ownership on success.
static HGLOBAL hglobal_from_bytes(const void *src, size_t n) {
    HGLOBAL h = GlobalAlloc(GMEM_MOVEABLE, n ? n : 1);
    if (!h) return nullptr;
    void *p = GlobalLock(h);
    if (!p) {
        GlobalFree(h);
        return nullptr;
    }
    if (n) memcpy(p, src, n);
    GlobalUnlock(h);
    return h;
}

// Buffer-grow copy out of an HGLOBAL-backed clipboard handle: copies
// min(size,cap) into buf and returns the FULL byte size. `size` is the byte
// count to expose (caller computes it, e.g. GlobalSize or a NUL-trimmed length).
static size_t fill_from_ptr(const void *src, size_t size, uint8_t *buf, size_t cap) {
    size_t copy = size < cap ? size : cap;
    if (buf && copy) memcpy(buf, src, copy);
    return size;
}

// Acquire a +1 WIC imaging factory (caller Releases). The UI thread already
// CoInitializeEx'd its STA in wv2_run (bridge handlers run on that same thread
// via WM_VERVE_BRIDGE), so no COM init is needed or done here.
static IWICImagingFactory *wic_factory() {
    IWICImagingFactory *f = nullptr;
    HRESULT hr = CoCreateInstance(kCLSID_WICImagingFactory, nullptr,
                                  CLSCTX_INPROC_SERVER, kIID_IWICImagingFactory,
                                  (void **)&f);
    if (FAILED(hr) || !f) return nullptr;
    return f;
}

#pragma pack(push, 1)
typedef struct {
    DWORD bV5Size;
    LONG bV5Width;
    LONG bV5Height;
    WORD bV5Planes;
    WORD bV5BitCount;
    DWORD bV5Compression;
    DWORD bV5SizeImage;
    LONG bV5XPelsPerMeter;
    LONG bV5YPelsPerMeter;
    DWORD bV5ClrUsed;
    DWORD bV5ClrImportant;
    DWORD bV5RedMask;
    DWORD bV5GreenMask;
    DWORD bV5BlueMask;
    DWORD bV5AlphaMask;
    DWORD bV5CSType;
    LONG bV5Endpoints[9];  // CIEXYZTRIPLE (3 * 3 LONG)
    DWORD bV5GammaRed;
    DWORD bV5GammaGreen;
    DWORD bV5GammaBlue;
    DWORD bV5Intent;
    DWORD bV5ProfileData;
    DWORD bV5ProfileSize;
    DWORD bV5Reserved;
} VERVE_BITMAPV5HEADER;
#pragma pack(pop)

static_assert(sizeof(VERVE_BITMAPV5HEADER) == 124,
              "BITMAPV5HEADER must be 124 bytes");

// Pack a top-down 32bpp-BGRA buffer into a CF_DIBV5 blob (124-byte header +
// bottom-up rows). Returns a malloc'd buffer (caller frees) and sets *out_len.
static uint8_t *build_dibv5(UINT w, UINT h, const uint8_t *bgra_topdown,
                            size_t *out_len) {
    size_t stride = (size_t)w * 4;
    size_t pixels = stride * (size_t)h;
    size_t total = 124 + pixels;
    uint8_t *out = (uint8_t *)malloc(total);
    if (!out) return nullptr;

    VERVE_BITMAPV5HEADER hdr;
    memset(&hdr, 0, sizeof(hdr));
    hdr.bV5Size = 124;
    hdr.bV5Width = (LONG)w;
    hdr.bV5Height = (LONG)h;  // positive => bottom-up rows
    hdr.bV5Planes = 1;
    hdr.bV5BitCount = 32;
    hdr.bV5Compression = kBI_BITFIELDS;
    hdr.bV5SizeImage = (DWORD)pixels;
    hdr.bV5RedMask = 0x00FF0000;
    hdr.bV5GreenMask = 0x0000FF00;
    hdr.bV5BlueMask = 0x000000FF;
    hdr.bV5AlphaMask = 0xFF000000;
    hdr.bV5CSType = kLCS_sRGB;
    hdr.bV5Intent = kLCS_GM_IMAGES;
    memcpy(out, &hdr, 124);

    for (UINT y = 0; y < h; ++y) {
        size_t src_off = (size_t)y * stride;                  // top-down src row
        size_t dst_off = 124 + (size_t)(h - 1 - y) * stride;  // bottom-up dst
        memcpy(out + dst_off, bgra_topdown + src_off, stride);
    }
    *out_len = total;
    return out;
}

// Decode a packed DIB (CF_DIB / CF_DIBV5 payload) into a top-down 32bpp-BGRA
// buffer. Supports 24/32bpp BI_RGB and BI_BITFIELDS; paletted/compressed inputs
// return NULL. A 32bpp source with all-zero alpha is treated as opaque BGRX.
// Returns a malloc'd buffer (caller frees) and sets *ow/*oh.
static uint8_t *dib_to_bgra(const uint8_t *bytes, size_t len, UINT *ow, UINT *oh) {
    if (len < 40) return nullptr;
    DWORD header_size = *(const DWORD *)(bytes + 0);
    if (header_size < 40 || header_size > len) return nullptr;

    LONG width_raw = *(const LONG *)(bytes + 4);
    LONG height_raw = *(const LONG *)(bytes + 8);
    WORD bit_count = *(const WORD *)(bytes + 14);
    DWORD compression = *(const DWORD *)(bytes + 16);
    if (width_raw <= 0 || height_raw == 0) return nullptr;
    if (bit_count != 24 && bit_count != 32) return nullptr;

    bool top_down = height_raw < 0;
    UINT width = (UINT)width_raw;
    UINT height = (UINT)(height_raw < 0 ? -height_raw : height_raw);

    // Reject absurd dimensions up front so the stride/size multiplies below
    // cannot overflow size_t (clipboard DIB content is untrusted). 0xFFFF px per
    // side is far above any real screenshot and keeps width*height*4 < 2^34.
    if (width > 0xFFFF || height > 0xFFFF) return nullptr;

    size_t pixel_off = header_size;
    if (header_size == 40 && compression == kBI_BITFIELDS) {
        pixel_off += 12;  // three DWORD masks follow a 40-byte BI_BITFIELDS hdr
    } else if (compression != kBI_RGB && compression != kBI_BITFIELDS) {
        return nullptr;
    }

    size_t src_stride = (((size_t)bit_count * width + 31) / 32) * 4;  // DWORD-aligned
    size_t need = pixel_off + src_stride * (size_t)height;
    if (need > len) return nullptr;

    size_t dst_stride = (size_t)width * 4;
    size_t dst_bytes = dst_stride * (size_t)height;
    if (dst_bytes > kMaxImageBytes) return nullptr;

    uint8_t *pixels = (uint8_t *)malloc(dst_bytes);
    if (!pixels) return nullptr;

    bool any_alpha = false;
    for (UINT y = 0; y < height; ++y) {
        UINT src_row = top_down ? y : (height - 1 - y);
        const uint8_t *s = bytes + pixel_off + (size_t)src_row * src_stride;
        uint8_t *d = pixels + (size_t)y * dst_stride;
        for (UINT x = 0; x < width; ++x) {
            if (bit_count == 32) {
                uint8_t b = s[x * 4 + 0], g = s[x * 4 + 1], r = s[x * 4 + 2],
                        a = s[x * 4 + 3];
                if (a != 0) any_alpha = true;
                d[x * 4 + 0] = b;
                d[x * 4 + 1] = g;
                d[x * 4 + 2] = r;
                d[x * 4 + 3] = a;
            } else {  // 24bpp BGR
                d[x * 4 + 0] = s[x * 3 + 0];
                d[x * 4 + 1] = s[x * 3 + 1];
                d[x * 4 + 2] = s[x * 3 + 2];
                d[x * 4 + 3] = 0xFF;
                any_alpha = true;
            }
        }
    }
    // A 32bpp DIB with no alpha at all is opaque BGRX.
    if (!any_alpha) {
        for (size_t i = 3; i < dst_bytes; i += 4) pixels[i] = 0xFF;
    }
    *ow = width;
    *oh = height;
    return pixels;
}

// PNG bytes -> top-down 32bpp-BGRA via WIC. Returns a malloc'd buffer (caller
// frees) and sets *ow/*oh. NULL on any failure.
static uint8_t *png_to_bgra(IWICImagingFactory *factory, const uint8_t *png,
                            size_t len, UINT *ow, UINT *oh) {
    IStream *stream = SHCreateMemStream(png, (UINT)len);
    if (!stream) return nullptr;

    IWICBitmapDecoder *decoder = nullptr;
    IWICBitmapFrameDecode *frame = nullptr;
    IWICFormatConverter *conv = nullptr;
    uint8_t *out = nullptr;

    if (FAILED(factory->CreateDecoderFromStream(
            stream, nullptr, WICDecodeMetadataCacheOnDemand, &decoder)) ||
        !decoder)
        goto done;
    if (FAILED(decoder->GetFrame(0, &frame)) || !frame) goto done;
    if (FAILED(factory->CreateFormatConverter(&conv)) || !conv) goto done;
    if (FAILED(conv->Initialize(frame, kGUID_WICPixelFormat32bppBGRA,
                                WICBitmapDitherTypeNone, nullptr, 0.0,
                                WICBitmapPaletteTypeCustom)))
        goto done;

    {
        UINT w = 0, h = 0;
        if (FAILED(conv->GetSize(&w, &h)) || w == 0 || h == 0) goto done;
        size_t stride = (size_t)w * 4;
        size_t pixel_bytes = stride * (size_t)h;
        if (pixel_bytes > kMaxImageBytes) goto done;
        out = (uint8_t *)malloc(pixel_bytes);
        if (!out) goto done;
        if (FAILED(conv->CopyPixels(nullptr, (UINT)stride, (UINT)pixel_bytes,
                                    out))) {
            free(out);
            out = nullptr;
            goto done;
        }
        *ow = w;
        *oh = h;
    }

done:
    if (conv) conv->Release();
    if (frame) frame->Release();
    if (decoder) decoder->Release();
    if (stream) stream->Release();
    return out;
}

// top-down 32bpp-BGRA -> PNG bytes via WIC. Returns a malloc'd buffer (caller
// frees) and sets *out_len. NULL on any failure.
static uint8_t *bgra_to_png(IWICImagingFactory *factory, UINT w, UINT h,
                            const uint8_t *bgra, size_t *out_len) {
    UINT stride = w * 4;
    UINT buf_size = stride * h;

    IWICBitmap *bitmap = nullptr;
    IStream *ostream = nullptr;
    IWICBitmapEncoder *encoder = nullptr;
    IWICBitmapFrameEncode *enc_frame = nullptr;
    IPropertyBag2 *bag = nullptr;
    uint8_t *out = nullptr;

    if (FAILED(factory->CreateBitmapFromMemory(
            w, h, kGUID_WICPixelFormat32bppBGRA, stride, buf_size,
            (BYTE *)bgra, &bitmap)) ||
        !bitmap)
        goto done;
    if (FAILED(CreateStreamOnHGlobal(nullptr, TRUE, &ostream)) || !ostream)
        goto done;
    if (FAILED(factory->CreateEncoder(kGUID_ContainerFormatPng, nullptr,
                                      &encoder)) ||
        !encoder)
        goto done;
    if (FAILED(encoder->Initialize(ostream, WICBitmapEncoderNoCache))) goto done;
    if (FAILED(encoder->CreateNewFrame(&enc_frame, &bag)) || !enc_frame)
        goto done;
    if (FAILED(enc_frame->Initialize(bag))) goto done;
    if (FAILED(enc_frame->SetSize(w, h))) goto done;
    if (FAILED(enc_frame->WriteSource(bitmap, nullptr))) goto done;
    if (FAILED(enc_frame->Commit())) goto done;
    if (FAILED(encoder->Commit())) goto done;

    {
        HGLOBAL hmem = nullptr;
        if (FAILED(GetHGlobalFromStream(ostream, &hmem)) || !hmem) goto done;
        void *p = GlobalLock(hmem);
        if (!p) goto done;
        size_t n = GlobalSize(hmem);
        if (n) {
            out = (uint8_t *)malloc(n);
            if (out) {
                memcpy(out, p, n);
                *out_len = n;
            }
        }
        GlobalUnlock(hmem);
    }

done:
    if (bag) bag->Release();
    if (enc_frame) enc_frame->Release();
    if (encoder) encoder->Release();
    if (ostream) ostream->Release();
    if (bitmap) bitmap->Release();
    return out;
}

// ---- Public C ABI -----------------------------------------------------------

extern "C" {

WV2Host *wv2_create(const char *title, int width, int height) {
    WV2Host *host = new WV2Host();
    if (!host) return nullptr;
    wchar_t *wtitle = widen(title, title ? (int)strlen(title) : 0);
    host->hwnd = create_window(host, wtitle ? wtitle : L"Verve", width, height);
    free(wtitle);
    if (!host->hwnd) {
        delete host;
        return nullptr;
    }
    return host;
}

void wv2_load_html(WV2Host *host, const char *html, size_t len) {
    if (!host) return;
    if (host->ready && host->webview) {
        wchar_t *w = widen(html, (int)len);
        if (w) {
            host->webview->NavigateToString(w);
            free(w);
        }
    } else {
        free(host->pending_html);
        host->pending_html = widen(html, (int)len);
    }
}

void wv2_load_url(WV2Host *host, const char *url, size_t len) {
    if (!host) return;
    if (host->ready && host->webview) {
        wchar_t *w = widen(url, (int)len);
        if (w) {
            host->webview->Navigate(w);
            free(w);
        }
    } else {
        free(host->pending_url);
        host->pending_url = widen(url, (int)len);
    }
}

void wv2_eval_js(WV2Host *host, const char *js, size_t len) {
    if (!host || !host->webview) return;
    wchar_t *w = widen(js, (int)len);
    if (!w) return;
    auto *esh = new ExecScriptHandler();
    host->webview->ExecuteScript(w, esh);
    esh->Release();
    free(w);
}

void wv2_set_bridge(WV2Host *host, verve_bridge_cb cb, void *ctx) {
    if (!host) return;
    host->bridge = cb;
    host->bridge_ctx = ctx;
}

void wv2_set_scheme_handler(WV2Host *host, const char *scheme, size_t scheme_len,
                             verve_scheme_cb cb, void *ctx) {
    if (!host) return;
    free(host->scheme_filter);
    host->scheme_filter = nullptr;
    host->scheme_cb = cb;
    host->scheme_ctx = ctx;
    if (!scheme || scheme_len == 0) return;
    // Build wide "scheme://*" filter string.
    const char *suffix = "://*";
    size_t flen = scheme_len + 4;
    char *filter_u8 = (char *)malloc(flen + 1);
    if (!filter_u8) return;
    memcpy(filter_u8, scheme, scheme_len);
    memcpy(filter_u8 + scheme_len, suffix, 5); // 4 chars + NUL
    host->scheme_filter = widen(filter_u8, (int)flen);
    free(filter_u8);
}

// ---- Custom scheme registration (verve://) ----------------------------------
// WebView2 requires custom schemes to be registered in the environment options
// at creation time (ICoreWebView2EnvironmentOptions4::SetCustomSchemeRegistrations).
// Without this, top-level Navigate("verve://...") fails silently regardless of
// AddWebResourceRequestedFilter — that filter only intercepts sub-resource
// requests from existing http/https pages, not the navigation document itself.

// Strip "://*" suffix to recover bare scheme name from host->scheme_filter.
static wchar_t *schemeFromFilter(const wchar_t *filter) {
    if (!filter) return nullptr;
    size_t flen = wcslen(filter);
    if (flen <= 4) return nullptr;
    if (wcsncmp(filter + flen - 4, L"://*", 4) != 0) return nullptr;
    size_t nlen = flen - 4;
    wchar_t *name = (wchar_t *)malloc((nlen + 1) * sizeof(wchar_t));
    if (!name) return nullptr;
    memcpy(name, filter, nlen * sizeof(wchar_t));
    name[nlen] = 0;
    return name;
}

class CustomSchemeRegistration : public ICoreWebView2CustomSchemeRegistration {
    wchar_t *name_;
    LONG ref_ = 1;

public:
    explicit CustomSchemeRegistration(const wchar_t *name) {
        int n = (int)wcslen(name);
        name_ = (wchar_t *)malloc((n + 1) * sizeof(wchar_t));
        if (name_) { memcpy(name_, name, n * sizeof(wchar_t)); name_[n] = 0; }
    }
    ~CustomSchemeRegistration() { free(name_); }

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **ppv) override {
        if (IsEqualIID(riid, IID_IUnknown) ||
            IsEqualIID(riid, IID_ICoreWebView2CustomSchemeRegistration))
            { *ppv = this; AddRef(); return S_OK; }
        *ppv = nullptr; return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef()  override { return (ULONG)InterlockedIncrement(&ref_); }
    ULONG STDMETHODCALLTYPE Release() override {
        ULONG r = (ULONG)InterlockedDecrement(&ref_);
        if (!r) delete this;
        return r;
    }

    HRESULT STDMETHODCALLTYPE get_SchemeName(LPWSTR *out) override {
        if (!out) return E_POINTER;
        if (!name_) { *out = nullptr; return E_OUTOFMEMORY; }
        size_t n = wcslen(name_);
        *out = (LPWSTR)CoTaskMemAlloc((n + 1) * sizeof(WCHAR));
        if (!*out) return E_OUTOFMEMORY;
        memcpy(*out, name_, (n + 1) * sizeof(WCHAR));
        return S_OK;
    }
    // TreatAsSecure = TRUE: makes verve:// a secure context (WASM, crypto, etc.)
    HRESULT STDMETHODCALLTYPE get_TreatAsSecure(BOOL *out) override
        { if (out) *out = TRUE; return S_OK; }
    HRESULT STDMETHODCALLTYPE put_TreatAsSecure(BOOL) override { return S_OK; }
    // Empty allowed-origins = allow from any origin.
    HRESULT STDMETHODCALLTYPE GetAllowedOrigins(UINT32 *cnt, LPWSTR **origins) override
        { if (cnt) *cnt = 0; if (origins) *origins = nullptr; return S_OK; }
    HRESULT STDMETHODCALLTYPE SetAllowedOrigins(UINT32, LPWSTR *) override { return S_OK; }
    // HasAuthorityComponent = TRUE: verve://app/... — "app" is the host/authority.
    HRESULT STDMETHODCALLTYPE get_HasAuthorityComponent(BOOL *out) override
        { if (out) *out = TRUE; return S_OK; }
    HRESULT STDMETHODCALLTYPE put_HasAuthorityComponent(BOOL) override { return S_OK; }
};

// Minimal env-options implementation covering v1–v4. Only v4 (custom scheme
// registrations) needs a real body; everything else returns safe defaults.
// WebView2 QIs through the version chain and uses whatever is present.
class VerveEnvironmentOptions
    : public ICoreWebView2EnvironmentOptions
    , public ICoreWebView2EnvironmentOptions2
    , public ICoreWebView2EnvironmentOptions3
    , public ICoreWebView2EnvironmentOptions4
{
    ICoreWebView2CustomSchemeRegistration *scheme_reg_;
    LONG ref_ = 1;

public:
    explicit VerveEnvironmentOptions(ICoreWebView2CustomSchemeRegistration *reg)
        : scheme_reg_(reg) { if (reg) reg->AddRef(); }
    ~VerveEnvironmentOptions() { if (scheme_reg_) scheme_reg_->Release(); }

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **ppv) override {
        if (IsEqualIID(riid, IID_IUnknown) ||
            IsEqualIID(riid, IID_ICoreWebView2EnvironmentOptions))
            { *ppv = static_cast<ICoreWebView2EnvironmentOptions *>(this); AddRef(); return S_OK; }
        if (IsEqualIID(riid, IID_ICoreWebView2EnvironmentOptions2))
            { *ppv = static_cast<ICoreWebView2EnvironmentOptions2 *>(this); AddRef(); return S_OK; }
        if (IsEqualIID(riid, IID_ICoreWebView2EnvironmentOptions3))
            { *ppv = static_cast<ICoreWebView2EnvironmentOptions3 *>(this); AddRef(); return S_OK; }
        if (IsEqualIID(riid, IID_ICoreWebView2EnvironmentOptions4))
            { *ppv = static_cast<ICoreWebView2EnvironmentOptions4 *>(this); AddRef(); return S_OK; }
        *ppv = nullptr; return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef()  override { return (ULONG)InterlockedIncrement(&ref_); }
    ULONG STDMETHODCALLTYPE Release() override {
        ULONG r = (ULONG)InterlockedDecrement(&ref_);
        if (!r) delete this;
        return r;
    }

    // ICoreWebView2EnvironmentOptions (v1) — all defaults
    HRESULT STDMETHODCALLTYPE get_AdditionalBrowserArguments(LPWSTR *out) override {
        if (!out) return E_POINTER;
        *out = (LPWSTR)CoTaskMemAlloc(sizeof(WCHAR));
        if (*out) (*out)[0] = 0;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE put_AdditionalBrowserArguments(LPCWSTR) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE get_Language(LPWSTR *out) override {
        if (!out) return E_POINTER;
        *out = (LPWSTR)CoTaskMemAlloc(sizeof(WCHAR));
        if (*out) (*out)[0] = 0;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE put_Language(LPCWSTR) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE get_TargetCompatibleBrowserVersion(LPWSTR *out) override {
        if (!out) return E_POINTER;
        *out = (LPWSTR)CoTaskMemAlloc(sizeof(WCHAR));
        if (*out) (*out)[0] = 0;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE put_TargetCompatibleBrowserVersion(LPCWSTR) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE get_AllowSingleSignOnUsingOSPrimaryAccount(BOOL *out) override
        { if (out) *out = FALSE; return S_OK; }
    HRESULT STDMETHODCALLTYPE put_AllowSingleSignOnUsingOSPrimaryAccount(BOOL) override { return S_OK; }

    // ICoreWebView2EnvironmentOptions2 (v2)
    HRESULT STDMETHODCALLTYPE get_ExclusiveUserDataFolderAccess(BOOL *out) override
        { if (out) *out = FALSE; return S_OK; }
    HRESULT STDMETHODCALLTYPE put_ExclusiveUserDataFolderAccess(BOOL) override { return S_OK; }

    // ICoreWebView2EnvironmentOptions3 (v3)
    HRESULT STDMETHODCALLTYPE get_IsCustomCrashReportingEnabled(BOOL *out) override
        { if (out) *out = FALSE; return S_OK; }
    HRESULT STDMETHODCALLTYPE put_IsCustomCrashReportingEnabled(BOOL) override { return S_OK; }

    // ICoreWebView2EnvironmentOptions4 (v4) — the reason this class exists
    HRESULT STDMETHODCALLTYPE GetCustomSchemeRegistrations(
        UINT32 *cnt, ICoreWebView2CustomSchemeRegistration ***regs) override
    {
        if (!cnt || !regs) return E_POINTER;
        if (!scheme_reg_) { *cnt = 0; *regs = nullptr; return S_OK; }
        *cnt = 1;
        *regs = (ICoreWebView2CustomSchemeRegistration **)CoTaskMemAlloc(
            sizeof(ICoreWebView2CustomSchemeRegistration *));
        if (!*regs) return E_OUTOFMEMORY;
        (*regs)[0] = scheme_reg_;
        scheme_reg_->AddRef();
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE SetCustomSchemeRegistrations(
        UINT32 cnt, ICoreWebView2CustomSchemeRegistration **regs) override
    {
        if (scheme_reg_) { scheme_reg_->Release(); scheme_reg_ = nullptr; }
        if (cnt > 0 && regs && regs[0]) {
            scheme_reg_ = regs[0];
            scheme_reg_->AddRef();
        }
        return S_OK;
    }
};

void wv2_run(WV2Host *host) {
    if (!host) return;
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

    HMODULE loader = LoadLibraryW(L"WebView2Loader.dll");
    if (!loader) {
        MessageBoxW(host->hwnd,
                    L"WebView2Loader.dll not found. Install the WebView2 "
                    L"Runtime / place the loader next to the exe.",
                    L"Verve", MB_OK | MB_ICONERROR);
        return;
    }
    auto create_env = (PFN_CreateEnv)GetProcAddress(
        loader, "CreateCoreWebView2EnvironmentWithOptions");
    if (!create_env) return;

    ShowWindow(host->hwnd, SW_SHOW);
    UpdateWindow(host->hwnd);

    // Register the custom scheme so WebView2 accepts top-level verve:// navigation.
    VerveEnvironmentOptions *env_opts = nullptr;
    if (host->scheme_filter && host->scheme_cb) {
        wchar_t *scheme_name = schemeFromFilter(host->scheme_filter);
        if (scheme_name) {
            auto *reg = new CustomSchemeRegistration(scheme_name);
            free(scheme_name);
            env_opts = new VerveEnvironmentOptions(reg);
            reg->Release();
        }
    }

    auto *eh = new EnvHandler(host);
    HRESULT hr = create_env(nullptr, nullptr, env_opts, eh);
    eh->Release();
    if (env_opts) env_opts->Release();
    if (FAILED(hr)) {
        MessageBoxW(host->hwnd, L"CreateCoreWebView2Environment failed.",
                    L"Verve", MB_OK | MB_ICONERROR);
        return;
    }

    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
}

void wv2_destroy(WV2Host *host) {
    if (!host) return;
    if (host->webview) host->webview->Release();
    if (host->controller) {
        host->controller->Close();
        host->controller->Release();
    }
    if (host->drop_registered && host->hwnd) {
        RevokeDragDrop(host->hwnd);
        host->drop_registered = false;
    }
    if (host->drop_target) {
        host->drop_target->Release();
        host->drop_target = nullptr;
    }
    free(host->pending_html);
    free(host->pending_url);
    // Bundle 8: tear down the UIA provider + owned a11y strings. WM_DESTROY (via
    // DestroyWindow below) may have already released the provider; null-check.
    if (host->a11y_provider) {
        host->a11y_provider->Release();
        host->a11y_provider = nullptr;
    }
    free(host->a11y_help);
    free(host->a11y_role_desc);
    if (host->env) host->env->Release();
    free(host->scheme_filter);
    if (host->hwnd) DestroyWindow(host->hwnd);
    delete host;
}

// ---- Bundle 2: window geometry & state --------------------------------------

void wv2_set_title(WV2Host *host, const char *title, size_t len) {
    WV2_REQUIRE_HWND(host, );
    wchar_t *w = widen(title, (int)len);
    if (!w) return;
    SetWindowTextW(hwnd, w);
    free(w);
}

void wv2_set_always_on_top(WV2Host *host, int on) {
    WV2_REQUIRE_HWND(host, );
    SetWindowPos(hwnd, on ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE);
}

void wv2_set_opacity(WV2Host *host, double v) {
    WV2_REQUIRE_HWND(host, );
    // WS_EX_LAYERED must be set before SetLayeredWindowAttributes works.
    LONG_PTR ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
    if ((ex & WS_EX_LAYERED) == 0)
        SetWindowLongPtrW(hwnd, GWL_EXSTYLE, ex | WS_EX_LAYERED);
    if (v < 0.0) v = 0.0;
    if (v > 1.0) v = 1.0;
    BYTE alpha = (BYTE)(v * 255.0);
    SetLayeredWindowAttributes(hwnd, 0, alpha, LWA_ALPHA);
}

void wv2_set_size(WV2Host *host, uint32_t w, uint32_t h) {
    WV2_REQUIRE_HWND(host, );
    SetWindowPos(hwnd, nullptr, 0, 0, (int)w, (int)h,
                 SWP_NOMOVE | SWP_NOZORDER);
}

void wv2_set_position(WV2Host *host, int32_t x, int32_t y) {
    WV2_REQUIRE_HWND(host, );
    SetWindowPos(hwnd, nullptr, (int)x, (int)y, 0, 0,
                 SWP_NOSIZE | SWP_NOZORDER);
}

void wv2_center(WV2Host *host) {
    WV2_REQUIRE_HWND(host, );
    RECT wr;
    GetWindowRect(hwnd, &wr);
    int w = wr.right - wr.left;
    int h = wr.bottom - wr.top;
    HMONITOR mon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
    MONITORINFO mi;
    mi.cbSize = sizeof(mi);
    if (!GetMonitorInfoW(mon, &mi)) return;
    int x = mi.rcWork.left + ((mi.rcWork.right - mi.rcWork.left) - w) / 2;
    int y = mi.rcWork.top + ((mi.rcWork.bottom - mi.rcWork.top) - h) / 2;
    SetWindowPos(hwnd, nullptr, x, y, 0, 0,
                 SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
}

void wv2_minimize(WV2Host *host) {
    WV2_REQUIRE_HWND(host, );
    ShowWindow(hwnd, SW_MINIMIZE);
}

void wv2_maximize(WV2Host *host) {
    WV2_REQUIRE_HWND(host, );
    ShowWindow(hwnd, SW_MAXIMIZE);
}

void wv2_restore(WV2Host *host) {
    WV2_REQUIRE_HWND(host, );
    ShowWindow(hwnd, SW_RESTORE);
}

void wv2_show(WV2Host *host) {
    WV2_REQUIRE_HWND(host, );
    ShowWindow(hwnd, SW_SHOW);
    SetForegroundWindow(hwnd);
}

void wv2_hide(WV2Host *host) {
    WV2_REQUIRE_HWND(host, );
    ShowWindow(hwnd, SW_HIDE);
}

void wv2_focus(WV2Host *host) {
    WV2_REQUIRE_HWND(host, );
    ShowWindow(hwnd, SW_RESTORE);
    SetForegroundWindow(hwnd);
}

void wv2_set_min_size(WV2Host *host, uint32_t w, uint32_t h) {
    if (!host) return;
    host->min_w = w;
    host->min_h = h;
}

void wv2_set_max_size(WV2Host *host, uint32_t w, uint32_t h) {
    if (!host) return;
    host->max_w = w;
    host->max_h = h;
}

float wv2_scale_factor(WV2Host *host) {
    WV2_REQUIRE_HWND(host, 1.0f);
    // GetDpiForWindow is Win10 1607+. Resolve dynamically so the host still
    // links/runs on older systems, falling back to the device-context DPI.
    typedef UINT(WINAPI * PFN_GetDpiForWindow)(HWND);
    static PFN_GetDpiForWindow fn = nullptr;
    static bool resolved = false;
    if (!resolved) {
        HMODULE u = GetModuleHandleW(L"user32.dll");
        if (u)
            fn = (PFN_GetDpiForWindow)GetProcAddress(u, "GetDpiForWindow");
        resolved = true;
    }
    UINT dpi = 96;
    if (fn) {
        dpi = fn(hwnd);
    } else {
        HDC dc = GetDC(hwnd);
        if (dc) {
            dpi = (UINT)GetDeviceCaps(dc, LOGPIXELSX);
            ReleaseDC(hwnd, dc);
        }
    }
    if (dpi == 0) dpi = 96;
    return (float)dpi / 96.0f;
}

int wv2_is_minimized(WV2Host *host) {
    WV2_REQUIRE_HWND(host, 0);
    return IsIconic(hwnd) ? 1 : 0;
}

int wv2_is_maximized(WV2Host *host) {
    WV2_REQUIRE_HWND(host, 0);
    return IsZoomed(hwnd) ? 1 : 0;
}

int wv2_is_fullscreen(WV2Host *host) {
    return (host && host->is_fullscreen) ? 1 : 0;
}

void wv2_request_attention(WV2Host *host, int critical) {
    WV2_REQUIRE_HWND(host, );
    FLASHWINFO fwi = {};
    fwi.cbSize = sizeof(fwi);
    fwi.hwnd = hwnd;
    fwi.dwFlags = critical ? (FLASHW_ALL | FLASHW_TIMERNOFG) : FLASHW_ALL;
    fwi.uCount = critical ? 0 : 5;
    fwi.dwTimeout = 0;
    FlashWindowEx(&fwi);
}

void wv2_set_resizable(WV2Host *host, int on) {
    WV2_REQUIRE_HWND(host, );
    LONG_PTR style = GetWindowLongPtrW(hwnd, GWL_STYLE);
    LONG_PTR mask = WS_THICKFRAME | WS_MAXIMIZEBOX;
    LONG_PTR next = on ? (style | mask) : (style & ~mask);
    SetWindowLongPtrW(hwnd, GWL_STYLE, next);
    SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
}

void wv2_set_fullscreen(WV2Host *host, int on) {
    WV2_REQUIRE_HWND(host, );
    if (on) {
        if (host->is_fullscreen) return;
        // Save the current style + placement, strip the frame, expand to the
        // monitor's full bounds.
        host->saved_style = (LONG)GetWindowLongPtrW(hwnd, GWL_STYLE);
        host->saved_exstyle = (LONG)GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
        host->saved_placement.length = sizeof(host->saved_placement);
        GetWindowPlacement(hwnd, &host->saved_placement);

        MONITORINFO mi = {};
        mi.cbSize = sizeof(mi);
        HMONITOR mon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
        if (GetMonitorInfoW(mon, &mi)) {
            SetWindowLongPtrW(hwnd, GWL_STYLE,
                              host->saved_style & ~(LONG)WS_OVERLAPPEDWINDOW);
            SetWindowPos(hwnd, HWND_TOP, mi.rcMonitor.left,
                         mi.rcMonitor.top,
                         mi.rcMonitor.right - mi.rcMonitor.left,
                         mi.rcMonitor.bottom - mi.rcMonitor.top,
                         SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
            host->is_fullscreen = true;
        }
    } else {
        if (!host->is_fullscreen) return;
        SetWindowLongPtrW(hwnd, GWL_STYLE, host->saved_style);
        SetWindowLongPtrW(hwnd, GWL_EXSTYLE, host->saved_exstyle);
        SetWindowPlacement(hwnd, &host->saved_placement);
        SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER |
                         SWP_FRAMECHANGED);
        host->is_fullscreen = false;
    }
}

// ---- Bundle 3: navigation & webview state -----------------------------------

void wv2_reload(WV2Host *host) {
    WV2_REQUIRE_WEBVIEW(host, );
    wv->Reload();
}

void wv2_go_back(WV2Host *host) {
    WV2_REQUIRE_WEBVIEW(host, );
    wv->GoBack();
}

void wv2_go_forward(WV2Host *host) {
    WV2_REQUIRE_WEBVIEW(host, );
    wv->GoForward();
}

int wv2_can_go_back(WV2Host *host) {
    WV2_REQUIRE_WEBVIEW(host, 0);
    BOOL b = FALSE;
    wv->get_CanGoBack(&b);
    return b ? 1 : 0;
}

int wv2_can_go_forward(WV2Host *host) {
    WV2_REQUIRE_WEBVIEW(host, 0);
    BOOL b = FALSE;
    wv->get_CanGoForward(&b);
    return b ? 1 : 0;
}

// Copy a CoTaskMem-owned LPWSTR getter result into `buf` as UTF-8. Returns the
// full UTF-8 byte length (sans NUL); copies min(len, cap). Frees the LPWSTR.
static size_t fill_utf8_from_wide(LPWSTR w, uint8_t *buf, size_t cap) {
    if (!w) return 0;
    int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
    if (n <= 1) {
        CoTaskMemFree(w);
        return 0;
    }
    size_t full = (size_t)(n - 1); // exclude trailing NUL
    char *tmp = (char *)malloc((size_t)n);
    if (!tmp) {
        CoTaskMemFree(w);
        return 0;
    }
    WideCharToMultiByte(CP_UTF8, 0, w, -1, tmp, n, nullptr, nullptr);
    size_t copy = full < cap ? full : cap;
    if (buf && copy) memcpy(buf, tmp, copy);
    free(tmp);
    CoTaskMemFree(w);
    return full;
}

// Copy a caller-owned NUL-terminated wide string into `buf` as UTF-8 (no NUL),
// following the same buffer-grow contract as fill_utf8_from_wide but WITHOUT
// freeing the source (it is not CoTaskMem-owned). Used by the file dialogs.
static size_t fill_utf8_from_wide_noNUL(const wchar_t *w, uint8_t *buf,
                                        size_t cap) {
    if (!w) return 0;
    int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
    if (n <= 1) return 0;
    size_t full = (size_t)(n - 1); // exclude trailing NUL
    char *tmp = (char *)malloc((size_t)n);
    if (!tmp) return 0;
    WideCharToMultiByte(CP_UTF8, 0, w, -1, tmp, n, nullptr, nullptr);
    size_t copy = full < cap ? full : cap;
    if (buf && copy) memcpy(buf, tmp, copy);
    free(tmp);
    return full;
}

size_t wv2_current_url(WV2Host *host, uint8_t *buf, size_t cap) {
    WV2_REQUIRE_WEBVIEW(host, 0);
    LPWSTR src = nullptr;
    if (FAILED(wv->get_Source(&src)) || !src) return 0;
    return fill_utf8_from_wide(src, buf, cap);
}

size_t wv2_current_title(WV2Host *host, uint8_t *buf, size_t cap) {
    WV2_REQUIRE_WEBVIEW(host, 0);
    LPWSTR title = nullptr;
    if (FAILED(wv->get_DocumentTitle(&title)) || !title) return 0;
    return fill_utf8_from_wide(title, buf, cap);
}

void wv2_set_zoom(WV2Host *host, double level) {
    if (host && host->controller) host->controller->put_ZoomFactor(level);
}

double wv2_get_zoom(WV2Host *host) {
    if (!host || !host->controller) return 1.0;
    double z = 1.0;
    host->controller->get_ZoomFactor(&z);
    return z;
}

int wv2_color_scheme(WV2Host *host) {
    (void)host;
    return read_color_scheme();
}

void wv2_set_color_scheme_cb(WV2Host *host, verve_color_scheme_cb cb,
                             void *ctx) {
    if (!host) return;
    host->color_scheme_cb = cb;
    host->color_scheme_ctx = ctx;
}

// ---- Bundle 4: event handlers & lifecycle -----------------------------------

void wv2_set_resize_cb(WV2Host *host, verve_resize_cb cb, void *ctx) {
    if (!host) return;
    host->resize_cb = cb;
    host->resize_ctx = ctx;
}

void wv2_set_focus_cb(WV2Host *host, verve_focus_cb cb, void *ctx) {
    if (!host) return;
    host->focus_cb = cb;
    host->focus_ctx = ctx;
}

void wv2_set_close_cb(WV2Host *host, verve_close_cb cb, void *ctx) {
    if (!host) return;
    host->close_cb = cb;
    host->close_ctx = ctx;
}

void wv2_set_drag_drop_cb(WV2Host *host, verve_drag_drop_cb cb, void *ctx) {
    if (!host) return;
    host->drag_drop_cb = cb;
    host->drag_drop_ctx = ctx;
    // Register the HWND as a drop target on first non-null handler; revoke when
    // cleared. Mirrors legacy setDragDropHandler.
    drop_register(host, cb != nullptr);
}

void wv2_close(WV2Host *host) {
    WV2_REQUIRE_HWND(host, );
    // Send WM_CLOSE synchronously so the close path (incl. any veto handler)
    // runs, exactly as legacy windows.zig close() does via SendMessageW.
    SendMessageW(hwnd, WM_CLOSE, 0, 0);
}

void wv2_set_tray_dispatch(verve_tray_command_cb cmd, verve_tray_message_cb msg) {
    g_tray_command = cmd;
    g_tray_message = msg;
}

void *wv2_hwnd(WV2Host *host) {
    return host ? (void *)host->hwnd : nullptr;
}

// ---- Bundle 5: dialogs & child windows --------------------------------------

// Build the OPENFILENAMEW filter buffer from the Zig-side pattern string. The
// format is a sequence of NUL-separated "<description>\0<pattern>\0" pairs,
// double-NUL terminated. We wrap the (already ';'-joined) pattern under a single
// "Allowed types" description, mirroring legacy runFileDialogWindows. Returns a
// malloc'd wide buffer (caller frees) or NULL when `patterns` is empty/NULL —
// NULL lStrFilter means "no filter" (allow any), which is what we want.
static wchar_t *build_ofn_filter(const char *patterns, size_t plen) {
    if (!patterns || plen == 0) return nullptr;
    static const wchar_t kDesc[] = L"Allowed types";
    const size_t desc_len = (sizeof(kDesc) / sizeof(wchar_t)) - 1; // sans NUL
    int pat_n = MultiByteToWideChar(CP_UTF8, 0, patterns, (int)plen, nullptr, 0);
    if (pat_n <= 0) return nullptr;
    // Layout: desc \0 pattern \0 \0
    size_t total = desc_len + 1 + (size_t)pat_n + 1 + 1;
    wchar_t *buf = (wchar_t *)malloc(total * sizeof(wchar_t));
    if (!buf) return nullptr;
    size_t i = 0;
    memcpy(buf + i, kDesc, desc_len * sizeof(wchar_t));
    i += desc_len;
    buf[i++] = 0;
    MultiByteToWideChar(CP_UTF8, 0, patterns, (int)plen, buf + i, pat_n);
    i += (size_t)pat_n;
    buf[i++] = 0;
    buf[i++] = 0; // double-NUL terminate
    return buf;
}

// Shared driver for the open/save dialogs. `save` selects GetSaveFileNameW +
// OFN_OVERWRITEPROMPT; otherwise GetOpenFileNameW + FILEMUSTEXIST (+ optional
// OFN_ALLOWMULTISELECT). The selected path is returned UTF-8 via the buffer-grow
// contract; 0 on cancel.
static size_t run_file_dialog(WV2Host *host, bool save, const char *title,
                              size_t title_len, const char *default_path,
                              size_t default_path_len, const char *default_name,
                              size_t default_name_len, const char *filters,
                              size_t filters_len, int allow_multiple,
                              uint8_t *buf, size_t cap) {
    HWND owner = host ? host->hwnd : nullptr;

    // GetOpen/SaveFileNameW writes the chosen path back into lpstrFile, so it
    // must be a large mutable wide buffer. MAX_PATH is too small for modern
    // long paths; use a generous fixed buffer like the legacy std.fs.max_path.
    const size_t kFileBufLen = 4096;
    wchar_t *file_buf = (wchar_t *)malloc(kFileBufLen * sizeof(wchar_t));
    if (!file_buf) return 0;
    file_buf[0] = 0;

    // Pre-populate save dialogs with the suggested file name.
    if (save && default_name && default_name_len) {
        MultiByteToWideChar(CP_UTF8, 0, default_name, (int)default_name_len,
                            file_buf, (int)kFileBufLen - 1);
        // MultiByteToWideChar with explicit src len does NOT NUL-terminate.
        int wn2 = MultiByteToWideChar(CP_UTF8, 0, default_name,
                                      (int)default_name_len, nullptr, 0);
        if (wn2 > 0 && (size_t)wn2 < kFileBufLen) file_buf[wn2] = 0;
    }

    wchar_t *wtitle =
        (title && title_len) ? widen(title, (int)title_len) : nullptr;
    wchar_t *wdir = (default_path && default_path_len)
                        ? widen(default_path, (int)default_path_len)
                        : nullptr;
    wchar_t *wfilter = build_ofn_filter(filters, filters_len);

    OPENFILENAMEW ofn = {};
    ofn.lStructSize = sizeof(ofn);
    ofn.hwndOwner = owner;
    ofn.lpstrFile = file_buf;
    ofn.nMaxFile = (DWORD)kFileBufLen;
    ofn.lpstrFilter = wfilter;
    ofn.lpstrInitialDir = wdir;
    ofn.lpstrTitle = wtitle;
    ofn.Flags = OFN_EXPLORER;
    if (save) {
        ofn.Flags |= OFN_OVERWRITEPROMPT | OFN_PATHMUSTEXIST;
    } else {
        ofn.Flags |= OFN_PATHMUSTEXIST | OFN_FILEMUSTEXIST;
        if (allow_multiple) ofn.Flags |= OFN_ALLOWMULTISELECT;
    }

    BOOL ok = save ? GetSaveFileNameW(&ofn) : GetOpenFileNameW(&ofn);

    size_t full = 0;
    if (ok) {
        // Single-select returns one NUL-terminated path. (Multi-select returns
        // dir\0file1\0file2\0\0 which we don't unpack here — same limitation as
        // legacy: callers get the leading dir/path string.)
        full = fill_utf8_from_wide_noNUL(file_buf, buf, cap);
    }

    free(file_buf);
    free(wtitle);
    free(wdir);
    free(wfilter);
    return full;
}

size_t wv2_open_file_dialog(WV2Host *host, const char *title, size_t title_len,
                            const char *default_path, size_t default_path_len,
                            const char *filters, size_t filters_len,
                            int allow_multiple, uint8_t *buf, size_t cap) {
    return run_file_dialog(host, /*save=*/false, title, title_len, default_path,
                           default_path_len, nullptr, 0, filters, filters_len,
                           allow_multiple, buf, cap);
}

size_t wv2_save_file_dialog(WV2Host *host, const char *title, size_t title_len,
                            const char *default_path, size_t default_path_len,
                            const char *default_name, size_t default_name_len,
                            const char *filters, size_t filters_len,
                            uint8_t *buf, size_t cap) {
    return run_file_dialog(host, /*save=*/true, title, title_len, default_path,
                           default_path_len, default_name, default_name_len,
                           filters, filters_len, /*allow_multiple=*/0, buf, cap);
}

size_t wv2_show_alert(WV2Host *host, const char *title, size_t title_len,
                      const char *message, size_t message_len, int style,
                      size_t button_count) {
    HWND owner = host ? host->hwnd : nullptr;

    UINT icon;
    switch (style) {
    case 1:
        icon = MB_ICONWARNING;
        break;
    case 2:
        icon = MB_ICONERROR;
        break;
    default:
        icon = MB_ICONINFORMATION;
        break;
    }

    // Win32 MessageBoxW has no arbitrary-label button support; map the button
    // COUNT onto the standard sets exactly as legacy showAlert does.
    size_t count = button_count == 0 ? 1 : button_count;
    UINT buttons;
    if (count == 1)
        buttons = MB_OK;
    else if (count == 2)
        buttons = MB_YESNO;
    else
        buttons = MB_YESNOCANCEL;

    wchar_t *wtitle =
        (title && title_len) ? widen(title, (int)title_len) : nullptr;
    wchar_t *wmsg =
        (message && message_len) ? widen(message, (int)message_len) : nullptr;

    int ret = MessageBoxW(owner, wmsg, wtitle, buttons | icon);
    free(wtitle);
    free(wmsg);

    // Map the Win32 return code back to the caller's button index in the same
    // order legacy used: 1-button => 0; 2-button => IDYES=0/IDNO=1; 3-button =>
    // IDYES=0/IDNO=1/IDCANCEL=2. Unexpected codes => 0.
    if (count == 1) return 0;
    if (count == 2) {
        switch (ret) {
        case IDYES:
            return 0;
        case IDNO:
            return 1;
        default:
            return 0;
        }
    }
    switch (ret) {
    case IDYES:
        return 0;
    case IDNO:
        return 1;
    case IDCANCEL:
        return 2;
    default:
        return 0;
    }
}

WV2Host *wv2_open_child(WV2Host *parent, const char *title, size_t title_len,
                        int width, int height) {
    (void)parent; // an independent top-level window, same as legacy.
    WV2Host *host = new WV2Host();
    if (!host) return nullptr;
    wchar_t *wtitle =
        (title && title_len) ? widen(title, (int)title_len) : nullptr;
    host->hwnd =
        create_window(host, wtitle ? wtitle : L"Verve", width, height);
    free(wtitle);
    if (!host->hwnd) {
        delete host;
        return nullptr;
    }
    return host;
}

// ---- Bundle 6: cookies ------------------------------------------------------

int wv2_cookie_set(WV2Host *host, const char *name, size_t nlen, const char *value,
                   size_t vlen, const char *domain, size_t dlen, const char *path,
                   size_t plen, int has_expiry, double expiry, int secure,
                   int http_only, int same_site) {
    ICoreWebView2CookieManager *mgr = cookie_manager(host);
    if (!mgr) return 1;

    // CreateCookie wants name/value/domain/path; empty domain/path let WebView2
    // apply its defaults (origin domain, "/" path), matching legacy buildNsCookie.
    wchar_t *wname = widen(name, (int)nlen);
    wchar_t *wval = widen(value, (int)vlen);
    wchar_t *wdom = (domain && dlen) ? widen(domain, (int)dlen) : nullptr;
    wchar_t *wpath = (path && plen) ? widen(path, (int)plen) : nullptr;

    ICoreWebView2Cookie *cookie = nullptr;
    HRESULT hr = mgr->CreateCookie(wname ? wname : L"", wval ? wval : L"",
                                   wdom, wpath, &cookie);
    free(wname);
    free(wval);
    free(wdom);
    free(wpath);

    if (FAILED(hr) || !cookie) {
        mgr->Release();
        return 2;
    }

    if (secure) cookie->put_IsSecure(TRUE);
    if (http_only) cookie->put_IsHttpOnly(TRUE);
    if (has_expiry) cookie->put_Expires(expiry);
    // The Zig cookie_codec maps Verve's SameSite to this int (none/lax/strict);
    // .default already coalesced to LAX there, so any value here is a real kind.
    cookie->put_SameSite((COREWEBVIEW2_COOKIE_SAME_SITE_KIND)same_site);

    HRESULT addhr = mgr->AddOrUpdateCookie(cookie);
    cookie->Release();
    mgr->Release();
    return FAILED(addhr) ? 3 : 0;
}

int wv2_cookie_delete(WV2Host *host, const char *name, size_t nlen,
                      const char *domain, size_t dlen, const char *path,
                      size_t plen) {
    (void)domain;
    (void)dlen;
    (void)path;
    (void)plen;
    ICoreWebView2CookieManager *mgr = cookie_manager(host);
    if (!mgr) return 1;

    wchar_t *wname = widen(name, (int)nlen);
    ICoreWebView2CookieList *list = fetch_all_cookies(mgr);
    if (!list) {
        free(wname);
        mgr->Release();
        return 0; // nothing to delete
    }

    UINT32 count = 0;
    list->get_Count(&count);
    for (UINT32 i = 0; i < count; ++i) {
        ICoreWebView2Cookie *c = nullptr;
        if (FAILED(list->GetValueAtIndex(i, &c)) || !c) continue;
        if (wname && cookie_name_is(c, wname)) {
            mgr->DeleteCookie(c);
            c->Release();
            break;
        }
        c->Release();
    }
    list->Release();
    free(wname);
    mgr->Release();
    return 0;
}

int wv2_cookie_clear(WV2Host *host) {
    ICoreWebView2CookieManager *mgr = cookie_manager(host);
    if (!mgr) return 1;
    HRESULT hr = mgr->DeleteAllCookies();
    mgr->Release();
    return FAILED(hr) ? 2 : 0;
}

int wv2_cookie_get(WV2Host *host, const char *name, size_t nlen,
                   uint8_t *value_buf, size_t value_cap, size_t *value_len,
                   uint8_t *domain_buf, size_t domain_cap, size_t *domain_len,
                   uint8_t *path_buf, size_t path_cap, size_t *path_len,
                   int *has_expiry, double *expiry, int *secure, int *http_only,
                   int *same_site) {
    ICoreWebView2CookieManager *mgr = cookie_manager(host);
    if (!mgr) return -1;

    wchar_t *wname = widen(name, (int)nlen);
    ICoreWebView2CookieList *list = fetch_all_cookies(mgr);
    if (!list) {
        free(wname);
        mgr->Release();
        return -1;
    }

    int rc = 0; // not found
    UINT32 count = 0;
    list->get_Count(&count);
    for (UINT32 i = 0; i < count; ++i) {
        ICoreWebView2Cookie *c = nullptr;
        if (FAILED(list->GetValueAtIndex(i, &c)) || !c) continue;
        if (!wname || !cookie_name_is(c, wname)) {
            c->Release();
            continue;
        }

        // Match — marshal every field out. WebView2 returns CoTaskMem strings.
        LPWSTR wval = nullptr, wdom = nullptr, wpath = nullptr;
        c->get_Value(&wval);
        c->get_Domain(&wdom);
        c->get_Path(&wpath);
        if (value_len) *value_len = fill_utf8_from_wide_noNUL(wval, value_buf, value_cap);
        if (domain_len) *domain_len = fill_utf8_from_wide_noNUL(wdom, domain_buf, domain_cap);
        if (path_len) *path_len = fill_utf8_from_wide_noNUL(wpath, path_buf, path_cap);
        if (wval) CoTaskMemFree(wval);
        if (wdom) CoTaskMemFree(wdom);
        if (wpath) CoTaskMemFree(wpath);

        double exp = -1;
        c->get_Expires(&exp);
        if (expiry) *expiry = exp;
        if (has_expiry) *has_expiry = (exp > 0) ? 1 : 0;

        BOOL sec = FALSE, http = FALSE;
        c->get_IsSecure(&sec);
        c->get_IsHttpOnly(&http);
        if (secure) *secure = sec ? 1 : 0;
        if (http_only) *http_only = http ? 1 : 0;

        COREWEBVIEW2_COOKIE_SAME_SITE_KIND ss =
            COREWEBVIEW2_COOKIE_SAME_SITE_KIND_LAX;
        c->get_SameSite(&ss);
        if (same_site) *same_site = (int)ss;

        rc = 1; // found
        c->Release();
        break;
    }
    list->Release();
    free(wname);
    mgr->Release();
    return rc;
}

// ---- Bundle 7: clipboard (Win32 clipboard + WIC) ----------------------------

int wv2_clip_write_text(WV2Host *host, const char *utf8, size_t len) {
    WV2_REQUIRE_HWND(host, 1);

    // UTF-8 -> NUL-terminated UTF-16LE. widen() appends the NUL.
    wchar_t *w = widen(utf8, (int)len);
    if (!w) return 2;
    size_t wlen = wcslen(w);
    HGLOBAL h = hglobal_from_bytes(w, (wlen + 1) * sizeof(wchar_t));
    free(w);
    if (!h) return 2;

    if (!OpenClipboard(hwnd)) {
        GlobalFree(h);
        return 3;
    }
    if (!EmptyClipboard()) {
        CloseClipboard();
        GlobalFree(h);
        return 3;
    }
    // SetClipboardData takes ownership of `h` on success; only free on failure.
    if (!SetClipboardData(CF_UNICODETEXT, h)) {
        GlobalFree(h);
        CloseClipboard();
        return 3;
    }
    CloseClipboard();
    return 0;
}

size_t wv2_clip_read_text(WV2Host *host, uint8_t *buf, size_t cap) {
    WV2_REQUIRE_HWND(host, 0);
    if (!IsClipboardFormatAvailable(CF_UNICODETEXT)) return 0;
    if (!OpenClipboard(hwnd)) return 0;

    size_t full = 0;
    HANDLE h = GetClipboardData(CF_UNICODETEXT);
    if (h) {
        const wchar_t *w = (const wchar_t *)GlobalLock(h);
        if (w) {
            full = fill_utf8_from_wide_noNUL(w, buf, cap);
            GlobalUnlock(h);
        }
    }
    CloseClipboard();
    return full;
}

int wv2_clip_write_html(WV2Host *host, const char *cf_html, size_t len) {
    WV2_REQUIRE_HWND(host, 1);
    UINT fmt = cf_html_format();
    if (!fmt) return 2;

    // The Zig clipboard_codec already built the full CF_HTML blob; we ship it
    // verbatim (plus a trailing NUL for tools that expect one).
    HGLOBAL h = GlobalAlloc(GMEM_MOVEABLE, len + 1);
    if (!h) return 2;
    void *p = GlobalLock(h);
    if (!p) {
        GlobalFree(h);
        return 2;
    }
    if (len) memcpy(p, cf_html, len);
    ((char *)p)[len] = '\0';
    GlobalUnlock(h);

    if (!OpenClipboard(hwnd)) {
        GlobalFree(h);
        return 3;
    }
    if (!EmptyClipboard()) {
        CloseClipboard();
        GlobalFree(h);
        return 3;
    }
    if (!SetClipboardData(fmt, h)) {
        GlobalFree(h);
        CloseClipboard();
        return 3;
    }
    CloseClipboard();
    return 0;
}

size_t wv2_clip_read_html(WV2Host *host, uint8_t *buf, size_t cap) {
    WV2_REQUIRE_HWND(host, 0);
    UINT fmt = cf_html_format();
    if (!fmt || !IsClipboardFormatAvailable(fmt)) return 0;
    if (!OpenClipboard(hwnd)) return 0;

    size_t full = 0;
    HANDLE h = GetClipboardData(fmt);
    if (h) {
        const void *p = GlobalLock(h);
        if (p) {
            // CF_HTML is ASCII bytes; expose them up to (but not past) any
            // trailing NUL so the Zig side parses clean header offsets.
            size_t n = GlobalSize(h);
            const char *s = (const char *)p;
            while (n > 0 && s[n - 1] == '\0') n--;
            full = fill_from_ptr(p, n, buf, cap);
            GlobalUnlock(h);
        }
    }
    CloseClipboard();
    return full;
}

int wv2_clip_write_image(WV2Host *host, const uint8_t *png, size_t len) {
    WV2_REQUIRE_HWND(host, 1);
    if (!png || len == 0) return 2;

    IWICImagingFactory *factory = wic_factory();
    if (!factory) return 2;

    UINT w = 0, h = 0;
    uint8_t *bgra = png_to_bgra(factory, png, len, &w, &h);
    factory->Release();
    if (!bgra) return 2;

    size_t dib_len = 0;
    uint8_t *dib = build_dibv5(w, h, bgra, &dib_len);
    free(bgra);
    if (!dib) return 2;

    HGLOBAL hg = hglobal_from_bytes(dib, dib_len);
    free(dib);
    if (!hg) return 2;

    if (!OpenClipboard(hwnd)) {
        GlobalFree(hg);
        return 3;
    }
    if (!EmptyClipboard()) {
        CloseClipboard();
        GlobalFree(hg);
        return 3;
    }
    if (!SetClipboardData(kCF_DIBV5, hg)) {
        GlobalFree(hg);
        CloseClipboard();
        return 3;
    }
    CloseClipboard();
    return 0;
}

size_t wv2_clip_read_image(WV2Host *host, uint8_t *buf, size_t cap) {
    WV2_REQUIRE_HWND(host, 0);

    UINT fmt;
    if (IsClipboardFormatAvailable(kCF_DIBV5))
        fmt = kCF_DIBV5;
    else if (IsClipboardFormatAvailable(kCF_DIB))
        fmt = kCF_DIB;
    else
        return 0;

    if (!OpenClipboard(hwnd)) return 0;

    // Copy the DIB out under the clipboard lock, then close the clipboard before
    // the (possibly slow) WIC encode so we never hold the global clipboard open
    // across a transcode.
    uint8_t *dib_copy = nullptr;
    size_t dib_len = 0;
    HANDLE h = GetClipboardData(fmt);
    if (h) {
        const void *p = GlobalLock(h);
        if (p) {
            dib_len = GlobalSize(h);
            if (dib_len) {
                dib_copy = (uint8_t *)malloc(dib_len);
                if (dib_copy) memcpy(dib_copy, p, dib_len);
            }
            GlobalUnlock(h);
        }
    }
    CloseClipboard();
    if (!dib_copy || dib_len < 40) {
        free(dib_copy);
        return 0;
    }

    UINT w = 0, ht = 0;
    uint8_t *bgra = dib_to_bgra(dib_copy, dib_len, &w, &ht);
    free(dib_copy);
    if (!bgra) return 0;

    IWICImagingFactory *factory = wic_factory();
    if (!factory) {
        free(bgra);
        return 0;
    }
    size_t png_len = 0;
    uint8_t *png = bgra_to_png(factory, w, ht, bgra, &png_len);
    factory->Release();
    free(bgra);
    if (!png) return 0;

    size_t full = fill_from_ptr(png, png_len, buf, cap);
    free(png);
    return full;
}

// ---- Bundle 8: print / a11y / snapshot / lifecycle --------------------------

int wv2_print(WV2Host *host, int dialog_kind) {
    if (!host || !host->webview) return 1; // not ready

    // ShowPrintUI lives on ICoreWebView2_16 (Edge runtime ~v111+). An older
    // runtime answers E_NOINTERFACE to the QI; report that as a distinct code
    // the Zig side maps to Unsupported.
    ICoreWebView2_16 *wv16 = nullptr;
    if (FAILED(host->webview->QueryInterface(IID_ICoreWebView2_16,
                                             (void **)&wv16)) ||
        !wv16)
        return 2; // unsupported runtime

    COREWEBVIEW2_PRINT_DIALOG_KIND kind =
        (dialog_kind == 1) ? COREWEBVIEW2_PRINT_DIALOG_KIND_SYSTEM
                           : COREWEBVIEW2_PRINT_DIALOG_KIND_BROWSER;
    HRESULT hr = wv16->ShowPrintUI(kind);
    wv16->Release();
    return FAILED(hr) ? 3 : 0; // backend failure vs ok
}

void wv2_set_a11y_label(WV2Host *host, const char *text, size_t len) {
    // The window's accessible Name is its window text, so the label channel
    // delegates to SetWindowTextW — same contract as legacy windows.zig's
    // setAccessibilityLabel -> setTitle.
    WV2_REQUIRE_HWND(host, );
    wchar_t *w = widen(text, (int)len);
    if (w) {
        SetWindowTextW(hwnd, w);
        free(w);
    }
}

void wv2_set_a11y_help(WV2Host *host, const char *text, size_t len) {
    // Publish UIA help text (UIA_HelpTextPropertyId) for the window root. Stored
    // live; the server-side RawElementProvider reads it on the next UIA query.
    // Ports legacy windows.zig setAccessibilityHelp.
    if (!host) return;
    wchar_t *w = widen(text, (int)len);
    free(host->a11y_help); // swap; failed widen leaves the slot null (default)
    host->a11y_help = w;
}

void wv2_set_a11y_role_desc(WV2Host *host, const char *text, size_t len) {
    // Override the spoken role name (UIA_LocalizedControlTypePropertyId) via the
    // server-side provider. Ports legacy windows.zig setAccessibilityRoleDescription.
    if (!host) return;
    wchar_t *w = widen(text, (int)len);
    free(host->a11y_role_desc);
    host->a11y_role_desc = w;
}

void wv2_set_a11y_subrole(WV2Host *host, int subrole) {
    // AccessibilitySubrole ordinal (0 standard, 1 dialog, 2 system_dialog, 3
    // floating). dialog/system_dialog surface as UIA_IsDialogPropertyId == true
    // through the provider. Ports legacy windows.zig setAccessibilitySubrole.
    if (!host) return;
    host->a11y_subrole = subrole;
}

int wv2_snapshot_png(WV2Host *host, const char *path, size_t len) {
    if (!host || !host->webview) return 1; // Unsupported

    // Growable HGLOBAL-backed stream; frees its memory on Release.
    IStream *stream = nullptr;
    if (FAILED(CreateStreamOnHGlobal(nullptr, TRUE, &stream)) || !stream)
        return 2; // CaptureFailed

    auto *handler = new CapturePreviewHandler();
    HRESULT hr = host->webview->CapturePreview(
        COREWEBVIEW2_CAPTURE_PREVIEW_IMAGE_FORMAT_PNG, stream, handler);
    if (FAILED(hr)) {
        handler->Release();
        stream->Release();
        return 2; // CaptureFailed
    }

    // Safe to nest-pump here: the bridge handler that triggers this runs from
    // WndProc (WM_VERVE_BRIDGE), not inside a WebView2 event callback, so the
    // CapturePreview completion can fire (see GetCookies note above).
    pump_until(&handler->done_);
    HRESULT cap_err = handler->error_;
    handler->Release();
    if (FAILED(cap_err)) {
        stream->Release();
        return 2; // CaptureFailed
    }

    // Pull the PNG bytes out of the HGLOBAL behind the stream.
    HGLOBAL hmem = nullptr;
    if (FAILED(GetHGlobalFromStream(stream, &hmem)) || !hmem) {
        stream->Release();
        return 3; // EncodeFailed
    }
    size_t n = GlobalSize(hmem);
    void *p = (n ? GlobalLock(hmem) : nullptr);
    if (!p || n == 0) {
        if (p) GlobalUnlock(hmem);
        stream->Release();
        return 3; // EncodeFailed
    }
    uint8_t *bytes = (uint8_t *)malloc(n);
    if (bytes) memcpy(bytes, p, n);
    GlobalUnlock(hmem);
    stream->Release();
    if (!bytes) return 3; // EncodeFailed

    // Write to disk: UTF-8 path -> UTF-16, CreateFileW + WriteFile.
    wchar_t *wpath = widen(path, (int)len);
    if (!wpath) {
        free(bytes);
        return 4; // WriteFailed
    }
    HANDLE fh = CreateFileW(wpath, GENERIC_WRITE, FILE_SHARE_READ, nullptr,
                            CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    free(wpath);
    if (fh == INVALID_HANDLE_VALUE) {
        free(bytes);
        return 4; // WriteFailed
    }
    int rc = 0;
    size_t off = 0;
    while (off < n) {
        DWORD chunk = (DWORD)((n - off > 0x40000000u) ? 0x40000000u : (n - off));
        DWORD wrote = 0;
        if (!WriteFile(fh, bytes + off, chunk, &wrote, nullptr) || wrote == 0) {
            rc = 4; // WriteFailed
            break;
        }
        off += wrote;
    }
    CloseHandle(fh);
    free(bytes);
    return rc;
}

void wv2_terminate(WV2Host *host) {
    // Unwind the wv2_run message loop. Matches legacy windows.zig terminate().
    (void)host;
    PostQuitMessage(0);
}

} // extern "C"
