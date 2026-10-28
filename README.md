# Ion

Ion is a MoonBit network stack built around a single idea: **one `Stream` +
`Dialer` abstraction with TLS as a pluggable decoration layer**, so that
HTTP(S) becomes just "a protocol running on some stream". On top of that it
provides HTTP/1.1 and HTTP/2 codecs, response decompression and charset
decoding, a cookie jar, HTTP(S)/SOCKS5 proxy and CONNECT-tunnel support,
WebSocket framing, a pooling connector, and a ready-to-use `UnifiedClient`
— plus a small `feather` CLI for ad-hoc requests.

> Historical note: the module is still named `feather` (the project started
> as "Feather (Ion)"); the repository and README refer to it as Ion.

- Repository: <https://github.com/183600/Ion>
- Module: `feather` (source in `src/`, MoonBit `0.1.0`)
- License: MIT
- Targets: the library core compiles for all MoonBit targets; the real
  TCP/TLS transports (`native_tcp.mbt`, `native_tls.mbt` and their C stubs)
  are `#cfg(target="native")` and use POSIX sockets and OpenSSL. On
  non-native targets an explicit "unavailable" dialer/provider fails loudly
  instead of pretending to work.

## What is implemented

- **`Stream` / `Dialer` layer** — portable read/write/timeout/close
  interface plus a native POSIX socket transport (non-blocking connect with
  poll, `TCP_NODELAY`, socket timeouts).
- **TLS** — native OpenSSL provider (SNI, hostname verification, ALPN,
  mTLS, optional key logging) plus a `MockTlsProvider` test double; TLS is
  applied by a `TlsClientCtx` that wraps any underlying `Stream`.
- **HTTP/1.1** — strict request/response codec: rejects header line
  folding, `Content-Length` / `Transfer-Encoding` conflicts, oversized
  lines/headers, and enforces a 64 MiB body cap; 100-continue handling and
  chunked trailers included.
- **HTTP/2** — RFC 9113 framing, HPACK, flow control, optional streaming
  bodies, cleartext prior knowledge (`FEATHER_H2C`), and extended CONNECT;
  HTTPS negotiates `h2` through ALPN by default.
- **Decompression** — puff-style DEFLATE / zlib / gzip decoder with full
  validation (oversubscribed trees, oversized alphabets, CRC-32 / Adler-32
  checks), so `Content-Encoding: gzip` and `deflate` responses decode
  transparently.
- **Text decoding** — `Response::text()` honors the `Content-Type` charset
  (UTF-8, ASCII, Latin-1, Windows-1252, and UTF-16) and falls back to UTF-8
  for unknown charsets.
- **Cookies** — RFC 6265 / RFC 6265bis cookie jar: parsing,
  domain/path/secure matching, `Max-Age` clamping, and expiry sweeps.
- **Proxy support** — HTTP(S) forward proxies, CONNECT tunnels (including
  replaying bytes read past the tunnel head), SOCKS5/SOCKS5H tunnels, Basic
  proxy auth, and SOCKS5 username/password auth.
- **WebSocket** — RFC 6455 client/server framing with masking, fragmentation,
  control frames, size limits, and a composable HTTP/1.1 upgrade or HTTP/2
  extended CONNECT handshake.
- **Pooling client** — `Connector` (also exposed as `UnifiedConnector`) with
  idle/active tracking, idle timeouts, per-host/global capacity limits, and
  reusable HTTP/2 sessions; `UnifiedClient` adds redirects (RFC semantics,
  cross-origin credential stripping), idempotent retries, default headers,
  form/multipart helpers, and cookie integration.

## CLI

```sh
moon run src --target native -- <url>                 # GET
moon run src --target native -- post <url> <body>     # POST
# Methods: get post put delete head options patch trace connect,
#          or any valid extension token such as PROPFIND.

# Environment variables:
#   FEATHER_URL=<url>          default GET target
#   FEATHER_PROXY=<url>        route through an HTTP(S) or SOCKS5 proxy
#   FEATHER_NO_PROXY=<list>    comma-separated hosts to reach directly
#   HTTPS_PROXY/http_proxy/ALL_PROXY/NO_PROXY
#                              standard proxy variables when FEATHER_PROXY is unset
#   FEATHER_CA=<pem file>      extra CA bundle
#   FEATHER_CLIENT_CERT=<pem>  client certificate for mTLS
#   FEATHER_CLIENT_KEY=<pem>   client private key
#   FEATHER_INSECURE=1         DISABLE TLS verification (unsafe)
#   FEATHER_KEYLOG=1           print TLS key material (debug)
#   FEATHER_H2C=1              use HTTP/2 prior knowledge for http://
```

## Build and test

Requires a recent MoonBit toolchain; native builds also need OpenSSL
development headers (for example `libssl-dev` on Debian/Ubuntu). Because plain
`moon check` / `moon test` only build the default backend and skip
`#cfg(target="native")` files, both targets must be checked:

```sh
moon update                # resolve MoonBit dependencies
moon check --target all    # or at least --target native
moon test                  # default-backend tests
moon test --target native  # native-only tests (FFI, sockets, TLS)
```

`scripts/typus_cabal_loop.sh` enforces
`moon check --target all && moon test && moon test --target native` for
automation; `AGENTS.md` documents the full gate list and layout notes, and
`PLAN.md` holds the original design notes (WASI/browser transports remain
planned).
