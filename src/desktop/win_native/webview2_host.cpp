/*
 * webview2_host.cpp — native WebView2 host for the C-ABI spike.
 *
 * Goal: prove the native-host pattern (a la vercel-labs/zero-native) works for
 * Verve on Windows, as an alternative to the 4129-line pure-Zig hand-rolled COM
 * backend in src/desktop/windows.zig.
 *
 * The C++ compiler generates correct COM vtables from the vendored WebView2.h;
 * we never count offsets. We deliberately avoid WRL (so the file cross-compiles
 * from macOS under zig's bundled mingw clang with only the vendored header) and
 * avoid libc++ (raw malloc buffers, so the link stays dependency-light).
 *
 * Build: zig c++ -target x86_64-windows-gnu -fms-extensions -std=c++17
 *               -I vendor/webview2 -c src/desktop/win_spike/webview2_host.cpp
 */
#include <windows.h>
#include <objbase.h>
#include <ole2.h>      // OleInitialize / RegisterDragDrop / ReleaseStgMedium
#include <oleidl.h>    // IDropTarget
#include <shellapi.h>  // DragQueryFileW / CF_HDROP
#include <commdlg.h>   // GetOpenFileNameW / GetSaveFileNameW / OPENFILENAMEW

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

// ---- WebMessageReceived: JS -> host -> Zig ----------------------------------

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
                host_->bridge(host_->bridge_ctx, (const uint8_t *)utf8, len);
                free(utf8);
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
    case WM_DESTROY:
        if (host && host->drop_registered) {
            RevokeDragDrop(hwnd);
            host->drop_registered = false;
        }
        PostQuitMessage(0);
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

void wv2_run(WV2Host *host) {
    if (!host) return;
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

    HMODULE loader = LoadLibraryW(L"WebView2Loader.dll");
    if (!loader) {
        MessageBoxW(host->hwnd,
                    L"WebView2Loader.dll not found. Install the WebView2 "
                    L"Runtime / place the loader next to the exe.",
                    L"Verve spike", MB_OK | MB_ICONERROR);
        return;
    }
    auto create_env = (PFN_CreateEnv)GetProcAddress(
        loader, "CreateCoreWebView2EnvironmentWithOptions");
    if (!create_env) return;

    ShowWindow(host->hwnd, SW_SHOW);
    UpdateWindow(host->hwnd);

    auto *eh = new EnvHandler(host);
    HRESULT hr = create_env(nullptr, nullptr, nullptr, eh);
    eh->Release();
    if (FAILED(hr)) {
        MessageBoxW(host->hwnd, L"CreateCoreWebView2Environment failed.",
                    L"Verve spike", MB_OK | MB_ICONERROR);
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

} // extern "C"
