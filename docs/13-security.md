# 13 — Security: CSRF, CSP, Origin pinning

Verve enforces three lines of defense on every HTML response by
default. Each one is opt-out (with a CLI flag or a header override),
but the defaults are tuned for safety over flexibility.

## CSRF: HMAC-signed token round-trip

Every page render issues a per-session CSRF token:

```
Set-Cookie: __verve_csrf=<base64url-token>; HttpOnly; SameSite=Strict; Path=/
```

The token is `base64url(timestamp ‖ hmac_sha256(key, timestamp))`
truncated to 16 MAC bytes. The HMAC key is initialized at server
startup from `VERVE_CSRF_KEY` (hex-encoded 32 bytes, if set) or
drawn from the IO RNG.

Form-encoded POSTs to `/api/<name>` must include the SAME token in a
`__csrf` form field. Mismatch → 403. The `ctx.actionForm(opts)`
helper auto-injects the field; standalone `ctx.csrfField()` is
available for hand-built forms.

JSON POSTs skip the form-CSRF check because the `SameSite=Strict`
cookie already prevents cross-origin browsers from sending the
cookie alongside the request. The threat model: form-injection
attacks. The mitigation: cookie-stripping cross-site, plus per-form
HMAC.

### Disabling for tests

```sh
verve-server --csrf=disable
```

Integration tests use this. Don't enable it in production.

### Replaying the round-trip

```sh
# 1. GET a page that emits a form — capture cookie + token
COOKIES=$(mktemp)
TOKEN=$(curl -s -c "$COOKIES" http://localhost:8080/counter \
  | grep -o 'name="__csrf" value="[^"]*"' \
  | sed 's/.*value="\([^"]*\)".*/\1/')

# 2. POST with both
curl -X POST -b "$COOKIES" -d "__csrf=$TOKEN" \
  http://localhost:8080/api/incrementCount
# → 303 See Other, Location: /counter
```

### Origin pinning

When the request carries an `Origin` header, the dispatcher compares
its host portion against the `Host` header. Mismatch → 403. This
adds a second layer of defense against fetch-based form forgery
where SameSite happens to fail.

## CSP: per-request nonce

Every HTML response carries:

```
Content-Security-Policy: script-src 'nonce-<12-byte-hex>' 'strict-dynamic'; object-src 'none'; base-uri 'self'
```

The nonce is fresh per request. `strict-dynamic` means scripts that
the nonced script loads are also allowed (CSP-friendly script
loading without enumerating every CDN by hand).

Inline scripts on a page need the nonce attribute to load. Render
code accesses the current nonce via `ctx.csp_nonce`:

```zig
ctx.script("/verve.js")    // external, no nonce needed
ctx.el("script").attr("nonce", ctx.csp_nonce)
   .raw("console.log('inline ok');")
```

`object-src 'none'` blocks Flash / Java applets. `base-uri 'self'`
prevents injected `<base>` tags from rewriting relative URLs to
attacker-controlled origins.

## ProtectedRoute

Route-level auth/role gating runs as part of the routing layer:

```zig
verve.Route.init("/admin", renderAdmin).protect(adminGuard),

fn adminGuard(ctx: *verve.Context) ?verve.Redirect {
    const meta = ctx.request_meta orelse return .{ .to = "/login" };
    const cookie = meta.cookie("session") orelse return .{ .to = "/login" };
    if (!isAdmin(cookie)) return .{ .to = "/" };
    return null;
}
```

Guards run root-first through the chain — a layout's guard runs
before the matched child's. First Redirect wins.

## Cookies

`verve.RequestMeta` parses the `Cookie` header into name/value pairs:

```zig
const session = ctx.request_meta.?.cookie("session") orelse return ctx.redirect("/login");
```

The framework only writes one cookie (`__verve_csrf`); session
cookies are entirely yours to issue via additional Set-Cookie
headers from your render or action handler.

## Threat model checklist

| Vector | Mitigation |
|---|---|
| Reflected XSS via attr or text | Automatic escaping in renderer + raw_inner opt-out is explicit. |
| Stored XSS via JSON-LD | `jsonLd(bytes)` emits verbatim; validate on input. |
| CSRF via form POST | HMAC token + cookie+field round-trip + SameSite=Strict. |
| CSRF via fetch from foreign origin | SameSite=Strict drops the cookie. |
| Clickjacking | Set `X-Frame-Options: DENY` via your reverse proxy (Verve does not set this today). |
| Cookie theft via document.cookie | `HttpOnly` flag on the CSRF cookie. |
| Open redirect via `?next=` | Whitelist allowed targets before passing to `ctx.redirect`. |
| Inline-script injection | CSP nonce + `strict-dynamic`. |
| `<base>` injection | `base-uri 'self'`. |

## Customizing CSP

The default policy works for most apps. To customize, intercept the
response in `respondBufferedExtra` (in `src/server/main.zig`) and
replace the `csp_header` value. A future revision will expose this
as a CLI flag.

## Next

- [03 — Actions](03-actions.md) — the CSRF-protected POST surface.
- [05 — Reactivity](05-reactivity.md) — ErrorBoundary for sequestering
  per-widget failures so one bad subtree doesn't take the page down.
- [16 — SPA router](16-spa-router.md) — same-origin checks for
  client-side navigation.
