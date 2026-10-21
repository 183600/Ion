struct RecordingTlsProvider {
  configs : Array[TlsConfig]
}

pub impl TlsProvider for RecordingTlsProvider with fn new_client(
  self : RecordingTlsProvider,
  config : TlsConfig,
) -> Result[&TlsClientCtx, TlsError] {
  match config.validate() {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  self.configs.push(config)
  let ctx = MockTlsClientCtx::{ config, is_connected: false }
  Ok(ctx)
}

test "Proxy::new_https accepts HTTPS proxies" {
  let proxy = Proxy::new_https("https://user:secret@proxy.example:8443").unwrap()
  assert_true(proxy.is_secure())
  assert_eq(proxy.authority(), "proxy.example:8443")
  assert_eq(
    proxy.authorization(),
    Some("Basic " + @base64.encode(@utf8.encode("user:secret"))),
  )
  assert_false(Proxy::new("http://proxy.example:3128").unwrap().is_secure())
  assert_true(Proxy::new("ftp://proxy.example") is Err(_))
  assert_true(Proxy::new_https("http://proxy.example:8443") is Err(_))
  assert_true(Proxy::new_https("https://proxy.example/path") is Err(_))
}

test "with_proxy_url selects HTTPS for an https proxy URL" {
  let client = UnifiedClient::new()
  assert_true(client.with_proxy_url("https://proxy.example:8443") is Ok(_))
  assert_true(client.with_proxy_url("HTTPS://proxy.example:8443") is Ok(_))
  assert_true(client.with_proxy_url("https://proxy.example/path") is Err(_))
}

test "plain HTTP through an HTTPS proxy uses TLS and absolute-form" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
  let stream = regression_mock_stream(raw, 4096, 4096)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let provider = RecordingTlsProvider::{ configs: [] }
  let client = UnifiedClient::with_transport(
    dialer,
    provider,
    ClientOptions::new().with_follow_redirects(false),
  ).with_proxy(Proxy::new_https("https://proxy.example:8443").unwrap())
  let response = client.get("http://example.com/path?x=1").unwrap()
  assert_eq(response.text().unwrap(), "ok")
  let wire = @utf8.decode(stream.output.to_bytes()[:])
  assert_true(wire.has_prefix("GET http://example.com/path?x=1 HTTP/1.1\r\n"))
  assert_eq(provider.configs.length(), 1)
  assert_eq(provider.configs[0].server_name, "proxy.example")
  assert_eq(provider.configs[0].alpn, @list.List(["http/1.1"]))
}

test "HTTPS through an HTTPS proxy wraps both hops in TLS" {
  let raw = "HTTP/1.1 200 Connection Established\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
  let stream = regression_mock_stream(raw, 4096, 4096)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let provider = RecordingTlsProvider::{ configs: [] }
  let client = UnifiedClient::with_transport(
    dialer,
    provider,
    ClientOptions::new().with_follow_redirects(false),
  ).with_proxy(Proxy::new_https("https://proxy.example:8443").unwrap())
  let response = client.get("https://secure.example/path").unwrap()
  assert_eq(response.text().unwrap(), "ok")
  let wire = @utf8.decode(stream.output.to_bytes()[:])
  assert_true(wire.has_prefix("CONNECT secure.example:443 HTTP/1.1\r\n"))
  assert_true(wire.contains("GET /path HTTP/1.1\r\n"))
  assert_eq(provider.configs.length(), 2)
  assert_eq(provider.configs[0].server_name, "proxy.example")
  assert_eq(provider.configs[1].server_name, "secure.example")
}

test "HTTPS proxy connections do not inherit origin credentials or ALPN" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
  let stream = regression_mock_stream(raw, 4096, 4096)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let provider = RecordingTlsProvider::{ configs: [] }
  let origin_config = TlsConfig::new("ignored.example")
    .with_alpn(@list.List(["h2", "http/1.1"]))
    .with_client_auth(ClientCert::new(b"cert", b"key"))
  let client = UnifiedClient::with_transport(
    dialer,
    provider,
    ClientOptions::new().with_follow_redirects(false),
  )
    .with_tls_config(origin_config)
    .with_proxy(Proxy::new_https("https://proxy.example:8443").unwrap())
  let _ = client.get("http://example.com/").unwrap()
  assert_eq(provider.configs.length(), 1)
  assert_eq(provider.configs[0].server_name, "proxy.example")
  assert_eq(provider.configs[0].alpn, @list.List(["http/1.1"]))
  assert_true(provider.configs[0].client_auth is None)
}

test "proxy connection keys distinguish TLS and plaintext proxies" {
  let plain = Connector::new(TcpDialer::new(), MockTlsProvider::new("test"))
    .with_proxy(Proxy::new("http://proxy.example:8443").unwrap())
  let secure = Connector::new(TcpDialer::new(), MockTlsProvider::new("test"))
    .with_proxy(Proxy::new_https("https://proxy.example:8443").unwrap())
  let url = Url::parse("http://example.com/").unwrap()
  assert_true(plain.connection_key(url) != secure.connection_key(url))
}
