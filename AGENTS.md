# Feather (Ion) — build & test notes

MoonBit network stack: unified `Stream` / `Dialer` / `TlsProvider` / `HttpClient`
abstraction (TCP, TLS via OpenSSL, HTTP/1.1, unified client). See `PLAN.md`.

## Layout

All sources live flat under `src/`:

- `net_stream.mbt`, `net_dialer.mbt` — `Stream` / `Dialer` abstraction (portable).
- `native_tcp.mbt`, `tcp_native_stub.c` — native POSIX socket transport.
- `native_tls.mbt`, `tls_native_stub.c` — native OpenSSL TLS provider.
- `tls_types.mbt`, `tls_provider.mbt` — TLS config and mock provider.
- `http_types.mbt`, `h1_codec.mbt` — HTTP types and HTTP/1.1 codec.
- `inflate.mbt` — DEFLATE / zlib / gzip decompression (puff-style).
- `cookies.mbt` — RFC 6265 cookie jar and matching.
- `proxy.mbt` — HTTP forward proxy and CONNECT tunnel support.
- `compat.mbt` — shared validation helpers (digits, charset checks, `List` alias).
- `unified_connector.mbt`, `unified_client.mbt` — pooling connector + client.
- `main.mbt` — CLI entry point.

## Gates

Run both of these before committing:

```sh
moon check --target all   # compiles wasm, wasm-gc, js and native sources
moon test                 # default-backend tests
moon test --target native # native-only tests (FFI, sockets, TLS)
```

`moon check` (no `--target`) and `moon test` only build the default backend and
**skip** `#cfg(target="native")` files such as `native_tcp.mbt` /
`native_tls.mbt`. Always also run `moon check --target native` (or
`--target all`) so the native transport/TLS code is actually checked.

`scripts/typus_cabal_loop.sh` enforces `moon check --target native && moon test`.

## Notes

- Native builds link OpenSSL: `-lssl -lcrypto`.
- Tests use in-repo mock streams/dialers (`regression_wbtest.mbt`), so most of
  the suite runs without network access.
- Release profile / breaking API changes: this package is pre-1.0 (`0.1.0`).
