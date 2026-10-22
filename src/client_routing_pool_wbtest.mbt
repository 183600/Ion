/// Changing routing on a UnifiedClient must not disturb the source client's
/// pooled connections. The derived client gets its own empty pool and closes
/// only connections it owns.

test "proxy builder derives an independent connection pool" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
  let stream = regression_mock_stream(raw, 4096, 4096)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let client = UnifiedClient::{
    connector,
    options: ClientOptions::new().with_follow_redirects(false),
    redirect_count: 0,
  }
  assert_eq(client.get("http://example.com/").unwrap().read_body().unwrap(), b"")
  assert_true(stream.is_open)

  let proxied = client.with_proxy(Proxy::new("http://proxy.example:3128").unwrap())
  assert_true(proxied.connector.proxy is Some(_))
  assert_true(stream.is_open)
  let _ = proxied.close_all()
  assert_true(stream.is_open)

  let _ = client.close_all()
  assert_false(stream.is_open)
}

test "proxy bypass builder derives an independent connection pool" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
  let stream = regression_mock_stream(raw, 4096, 4096)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let client = UnifiedClient::{
    connector,
    options: ClientOptions::new().with_follow_redirects(false),
    redirect_count: 0,
  }
  assert_eq(client.get("http://example.com/").unwrap().read_body().unwrap(), b"")
  assert_true(stream.is_open)

  let bypassed = client.with_proxy_bypass(["example.com"])
  assert_eq(bypassed.connector.proxy_bypass().length(), 1)
  assert_true(stream.is_open)
  let _ = bypassed.close_all()
  assert_true(stream.is_open)

  let _ = client.close_all()
  assert_false(stream.is_open)
}
