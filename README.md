# Ion

Ion is a MoonBit network stack built around a single idea: **one `Stream` +
`Dialer` abstraction with TLS as a pluggable decoration layer**, so that
HTTP(S) becomes just "a protocol running on some stream". On top of that it
provides an HTTP/1.1 codec, response decompression, a cookie jar, proxy and
CONNECT-tunnel support, a pooling connector, and a ready-to-use
`UnifiedClient` — plus a small `feather` CLI for ad-hoc requests.

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
  mTLS, optional key logging) plus a `MockTlsProvider` test double; TLS is a
  `TlsClientCtx` that wraps any underlying `Stream`.
- **HTTP/1.1** — strict request/response codec: rejects header line
  folding, `Content-Length` / `Transfer-Encoding` conflicts, oversized
  lines/headers, and enforces a 64 MiB body cap; 100-continue handling and
  chunked trailers included.
- **Decompression** — puff-style DEFLATE / zlib / gzip decoder with full
  validation (oversubplied trees, oversized alphabets, CRC-32 / Adler-32
  checks), so `Content-Encoding: gzip` responses decode transparently.
- **Cookies** — RFC 6265b cookie jar: parsing, domain/path/secure matching,
  `Max-Age` clamping, and expiry sweeps.
- **Proxy support** — HTTP forward proxy, CONNECT tunnels (including
  replaying bytes read past the tunnel head), and Basic proxy auth.
- **Pooling client** — `UnifiedConnector` with idle/active tracking, idle
  timeouts and capacity limits; `UnifiedClient` adds redirects (RFC
  semantics, cross-origin credential stripping), idempotent retries, and
  cookie integration.

## CLI

```sh
moon run src --target native -- <url>                 # GET
moon run src --target native -- post <url> <body>     # other methods: get post put delete head options patch

# Environment variables:
#   FEATHER_URL=<url>          default GET target
#   FEATHER_PROXY=<url>        route through an HTTP proxy
#   FEATHER_CA=<pem file>      extra CA bundle
#   FEATHER_CLIENT_CERT=<pem>  client certificate for mTLS
#   FEATHER_CLIENT_KEY=<pem>   client private key
#   FEATHER_INSECURE=1         DISABLE TLS verification (unsafe)
#   FEATHER_KEYLOG=1           print TLS key material (debug)
```

## Build and test

Requires a recent MoonBit toolchain. Because plain `moon check` /
`moon test` only build the default backend and skip
`#cfg(target="native")` files, both targets must be checked:

```sh
moon check --target all    # or at least --target native
moon test                  # default-backend tests
moon test --target native  # native-only tests (FFI, sockets, TLS)
```

`scripts/typus_cabal_loop.sh` enforces `moon check --target native && moon
test` for automation; `AGENTS.md` documents the full gate list and layout
notes, and `PLAN.md` holds the original design notes (HTTP/2 and
WASI/browser transports are planned but not yet implemented).
