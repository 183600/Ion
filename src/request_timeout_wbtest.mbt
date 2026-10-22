struct RequestTimeoutDialer {
  stream : &Stream
  mut timeout_ms : Int
  mut dials : Int
}

pub impl Dialer for RequestTimeoutDialer with fn dial_tcp(
  self : RequestTimeoutDialer,
  host : String,
  port : Int,
) -> Result[&Stream, NetError] {
  let _ = host
  let _ = port
  self.dials = self.dials + 1
  Ok(self.stream)
}

pub impl Dialer for RequestTimeoutDialer with fn resolve(
  self : RequestTimeoutDialer,
  host : String,
) -> Result[List[String], NetError] {
  let _ = self
  Ok(@list.List([host]))
}

pub impl Dialer for RequestTimeoutDialer with fn set_timeout(
  self : RequestTimeoutDialer,
  timeout_ms : Int,
) {
  self.timeout_ms = if timeout_ms < 0 { 0 } else { timeout_ms }
}

test "request timeout reaches the dialer" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
  let stream = regression_mock_stream(raw, 4096, 4096)
  let dialer = RequestTimeoutDialer::{ stream, timeout_ms: 30000, dials: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let options = ClientOptions::new()
    .with_timeout(1234)
    .with_follow_redirects(false)
  let client = UnifiedClient::{ connector, options, redirect_count: 0 }
  let url = Url::parse("http://example.com/").unwrap()
  let _ = client.request(Request::new(GET, url).with_timeout(4321)).unwrap()
  assert_eq(dialer.timeout_ms, 4321)
  assert_eq(stream.last_timeout, 4321)
  let _ = client.close_all()
}
