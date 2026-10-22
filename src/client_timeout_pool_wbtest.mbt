///|
test "timeout builder derives an independent connection pool" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
  let stream = regression_mock_stream(raw, 4096, 4096)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let client = UnifiedClient::{
    connector,
    options: ClientOptions::new().with_follow_redirects(false),
    redirect_count: 0,
  }
  let response = client.get("http://example.com/").unwrap()
  assert_eq(response.read_body().unwrap(), b"")
  assert_true(stream.is_open)
  let tuned = client.with_timeout(1)
  let _ = tuned.close_all()
  // Closing the derived client must not close the source client's idle pool.
  assert_true(stream.is_open)
  let _ = client.close_all()
  assert_false(stream.is_open)
}

///|
test "http2 policy builder derives an independent connection pool" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
  let stream = regression_mock_stream(raw, 4096, 4096)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let client = UnifiedClient::{
    connector,
    options: ClientOptions::new().with_follow_redirects(false),
    redirect_count: 0,
  }
  let response = client.get("http://example.com/").unwrap()
  assert_eq(response.read_body().unwrap(), b"")
  assert_true(stream.is_open)
  let tuned = client.with_http2(false)
  assert_false(tuned.connector.http2_enabled())
  // Selecting a new HTTP/2 policy must not close the source pool either.
  assert_true(stream.is_open)
  let _ = tuned.close_all()
  assert_true(stream.is_open)
  let _ = client.close_all()
  assert_false(stream.is_open)
}

