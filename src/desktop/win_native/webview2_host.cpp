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

} // extern "C"
