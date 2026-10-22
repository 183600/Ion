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

///|
test "connector reapplies the request timeout when reusing a pooled stream" {
  let stream = regression_mock_stream("", 0, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
    .with_timeout(5000)
  let url = Url::parse("http://example.com/").unwrap()
  let _ = connector.connect(url).unwrap()
  // Simulate a previous checkout with a shorter per-request timeout, then a
  // reconnect using the connector's current (longer) request timeout.
  assert_true(stream.set_timeout(250) is Ok(_))
  let _ = connector.with_timeout(9000)
  let _ = connector.connect(url).unwrap()
  assert_eq(dialer.count, 1)
  assert_eq(stream.last_timeout, 9000)
  let _ = connector.close_all()
}

struct FailingTimeoutStream {
  mut is_open : Bool
  fail_timeout : Int
}

impl Stream for FailingTimeoutStream with fn read(
  self : FailingTimeoutStream,
  buf : Buffer,
) -> Result[Int, NetError] {
  let _ = self
  let _ = buf
  Ok(0)
}

impl Stream for FailingTimeoutStream with fn write(
  self : FailingTimeoutStream,
  buf : Buffer,
) -> Result[Int, NetError] {
  let _ = self
  Ok(buf.length())
}

impl Stream for FailingTimeoutStream with fn flush(
  self : FailingTimeoutStream,
) -> Result[Unit, NetError] {
  let _ = self
  Ok(())
}

impl Stream for FailingTimeoutStream with fn close(
  self : FailingTimeoutStream,
) -> Result[Unit, NetError] {
  self.is_open = false
  Ok(())
}

impl Stream for FailingTimeoutStream with fn set_timeout(
  self : FailingTimeoutStream,
  timeout_ms : Int,
) -> Result[Unit, NetError] {
  if timeout_ms == self.fail_timeout {
    Err(NetError::Timeout)
  } else {
    Ok(())
  }
}

impl Stream for FailingTimeoutStream with fn peer_addr(
  self : FailingTimeoutStream,
) -> Result[String, NetError] {
  if self.is_open {
    Ok("mock:0")
  } else {
    Err(NetError::Closed)
  }
}

impl Stream for FailingTimeoutStream with fn local_addr(
  self : FailingTimeoutStream,
) -> Result[String, NetError] {
  if self.is_open {
    Ok("mock:0")
  } else {
    Err(NetError::Closed)
  }
}

struct FailingTimeoutDialer {
  stream : FailingTimeoutStream
  mut dials : Int
}

impl Dialer for FailingTimeoutDialer with fn dial_tcp(
  self : FailingTimeoutDialer,
  host : String,
  port : Int,
) -> Result[&Stream, NetError] {
  let _ = host
  let _ = port
  self.dials = self.dials + 1
  self.stream.is_open = true
  Ok(self.stream)
}

impl Dialer for FailingTimeoutDialer with fn resolve(
  self : FailingTimeoutDialer,
  host : String,
) -> Result[List[String], NetError] {
  let _ = self
  Ok(@list.List([host]))
}

test "connect does not pool a stream whose timeout update failed" {
  let dialer = FailingTimeoutDialer::{
    stream: FailingTimeoutStream::{ is_open: false, fail_timeout: 5000 },
    dials: 0,
  }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
    .with_timeout(5000)
    .with_connect_timeout(200)
  let url = Url::parse("http://example.com/").unwrap()
  match connector.connect(url) {
    Ok(_) => fail("connect accepted a stream whose timeout update failed")
    Err(err) => assert_eq(err, Timeout)
  }
  assert_eq(dialer.dials, 1)
  assert_false(dialer.stream.is_open)
  let key = connector.connection_key(url)
  assert_true(connector.pool.val.idle.get(key) is None)
}
