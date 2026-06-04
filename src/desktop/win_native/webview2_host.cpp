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

#include <WebView2.h>

#include "host.h"

#include <stdlib.h>
#include <string.h>

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
};

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

// ---- Win32 window -----------------------------------------------------------

static const wchar_t *kWindowClass = L"VerveWv2SpikeWindow";

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
        return 0;
    case WM_DESTROY:
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
    free(host->pending_html);
    free(host->pending_url);
    if (host->hwnd) DestroyWindow(host->hwnd);
    delete host;
}

} // extern "C"
