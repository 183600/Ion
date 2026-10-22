///|
test "connect timeout bounds dialing without shrinking the request timeout" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
  let stream = regression_mock_stream(raw, 4096, 4096)
  let dialer = RequestTimeoutDialer::{ stream, timeout_ms: 30000, dials: 0 }
  let options = ClientOptions::new()
    .with_timeout(10000)
    .with_connect_timeout(250)
    .with_follow_redirects(false)
  let client = UnifiedClient::with_transport(
    dialer,
    MockTlsProvider::new("test"),
    options,
  )
  let response = client.get("http://example.com/").unwrap()
  assert_eq(response.read_body().unwrap(), b"")
  assert_eq(dialer.timeout_ms, 250)
  assert_eq(dialer.dials, 1)
  assert_eq(stream.last_timeout, 10000)
  let _ = client.close_all()
}

///|
test "connect timeout never exceeds a shorter request timeout" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
  let stream = regression_mock_stream(raw, 4096, 4096)
  let dialer = RequestTimeoutDialer::{ stream, timeout_ms: 30000, dials: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
    .with_timeout(10000)
    .with_connect_timeout(5000)
  let client = UnifiedClient::{
    connector,
    options: ClientOptions::new().with_follow_redirects(false),
    redirect_count: 0,
  }
  let url = Url::parse("http://example.com/").unwrap()
  let response = client.request(Request::new(GET, url).with_timeout(100)).unwrap()
  assert_eq(response.read_body().unwrap(), b"")
  assert_eq(dialer.timeout_ms, 100)
  assert_eq(stream.last_timeout, 100)
  let _ = client.close_all()
}

///|
test "connector restores the request timeout after a connect-only deadline" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
  let stream = regression_mock_stream(raw, 4096, 4096)
  let dialer = RequestTimeoutDialer::{ stream, timeout_ms: 30000, dials: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
    .with_timeout(5000)
    .with_connect_timeout(200)
  assert_eq(connector.connect_timeout(), 200)
  let resolved = connector.connect(Url::parse("http://example.com/").unwrap()).unwrap()
  assert_eq(dialer.timeout_ms, 200)
  assert_eq(resolved.local_addr().unwrap(), "mock:0")
  assert_eq(stream.last_timeout, 5000)
  let _ = connector.close_all()
}
