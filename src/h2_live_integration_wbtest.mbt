///|
#cfg(target="native")
fn h2_live_enabled() -> Bool {
  @env.get_env_var("FEATHER_LIVE_H2") is Some(_)
}

///|
#cfg(target="native")
test "live Go HTTP/2 streaming response preserves DATA order and trailers" {
  if h2_live_enabled() {
    let client = UnifiedClient::new()
      .with_tls_config(
        TlsConfig::new("localhost")
        .with_alpn(@list.List(["h2", "http/1.1"]))
        .with_verify_mode(SkipVerification),
      )
      .with_http2_streaming(true)
      .with_timeout(5000)
    let response = client.get("https://localhost:18443/stream").unwrap()
    assert_eq(response.version, "HTTP/2")
    assert_eq(response.status, 200)
    let first = Buffer(size_hint=16)
    assert_eq(response.body_stream().read(first).unwrap(), 5)
    assert_eq(@utf8.decode_lossy(first.to_bytes()[:]), "first")
    let second = Buffer(size_hint=16)
    assert_eq(response.body_stream().read(second).unwrap(), 7)
    assert_eq(@utf8.decode_lossy(second.to_bytes()[:]), "-second")
    let eof = Buffer(size_hint=1)
    assert_eq(response.body_stream().read(eof).unwrap(), 0)
    assert_eq(response.trailers().get("x-trailer"), Some("done"))
    assert_eq(client.active_connection_count(), 0)
    assert_eq(client.idle_connection_count(), 1)
    let _ = client.close_all()
  }
}

///|
#cfg(target="native")
test "live Go HTTP/2 buffered response has no trailers" {
  if h2_live_enabled() {
    let client = UnifiedClient::new()
      .with_tls_config(
        TlsConfig::new("localhost")
        .with_alpn(@list.List(["h2", "http/1.1"]))
        .with_verify_mode(SkipVerification),
      )
      .with_timeout(5000)
    let response = client.get("https://localhost:18443/plain").unwrap()
    assert_eq(response.version, "HTTP/2")
    assert_eq(response.text().unwrap(), "hello")
    assert_eq(response.trailers().length(), 0)
    let _ = client.close_all()
  }
}
