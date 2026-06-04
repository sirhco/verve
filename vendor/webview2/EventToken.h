/*
 * Minimal EventToken.h shim.
 *
 * The real header ships with the Windows SDK (winrt/) and is not present in
 * zig's bundled mingw-w64 sysroot. WebView2.h only needs the
 * EventRegistrationToken struct from it, so we provide just that. Definition
 * matches the SDK exactly (single 64-bit value).
 */
#ifndef _EVENTTOKEN_H_
#define _EVENTTOKEN_H_

typedef struct EventRegistrationToken {
    long long value;
} EventRegistrationToken;

#endif /* _EVENTTOKEN_H_ */
