///|
test "client default headers are applied without overriding request headers" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
  let stream = regression_mock_stream(raw, 1, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let options = ClientOptions::new()
    .with_follow_redirects(false)
    .with_default_header("X-Client", "feather")
    .with_default_header("User-Agent", "custom-agent")
  let client = UnifiedClient::{ connector, options, redirect_count: 0 }
  let url = Url::parse("http://example.com/defaults").unwrap()
  let request = Request::new(GET, url).with_header("X-Client", "request-specific")
  assert_true(client.request(request) is Ok(_))
  let wire = @utf8.decode_lossy(stream.output.to_bytes()[:])
  assert_true(wire.contains("X-Client: request-specific\r\n"))
  assert_false(wire.contains("X-Client: feather"))
  assert_true(wire.contains("User-Agent: custom-agent\r\n"))
  assert_false(wire.contains("Feather/0.1.0"))
}

///|
test "default headers survive same-origin redirects" {
  let raw = "HTTP/1.1 302 Found\r\nLocation: /next\r\nContent-Length: 0\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
  let stream = regression_mock_stream(raw, 1, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let client = UnifiedClient::{
    connector,
    options: ClientOptions::new().with_default_header("X-Client", "feather"),
    redirect_count: 0,
  }
  let url = Url::parse("http://example.com/start").unwrap()
  assert_true(client.request(Request::new(GET, url)) is Ok(_))
  let wire = @utf8.decode_lossy(stream.output.to_bytes()[:])
  let next_index = wire.find("GET /next HTTP/1.1").unwrap()
  let second_request = wire.substring(start=next_index)
  assert_true(second_request.contains("X-Client: feather\r\n"))
}

///|
test "cross-origin redirects drop client default headers" {
  let raw = "HTTP/1.1 302 Found\r\nLocation: http://other.example/next\r\nContent-Length: 0\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
  let stream = regression_mock_stream(raw, 1, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let client = UnifiedClient::{
    connector,
    options: ClientOptions::new()
      .with_default_header("X-Api-Key", "secret")
      .with_default_header("Authorization", "Bearer secret"),
    redirect_count: 0,
  }
  let url = Url::parse("http://example.com/start").unwrap()
  assert_true(client.request(Request::new(GET, url)) is Ok(_))
  let wire = @utf8.decode_lossy(stream.output.to_bytes()[:])
  let next_index = wire.find("GET /next HTTP/1.1").unwrap()
  let second_request = wire.substring(start=next_index)
  assert_true(!second_request.contains("X-Api-Key"))
  assert_true(!second_request.contains("Authorization"))
  assert_true(second_request.contains("Host: other.example\r\n"))
}

///|
test "repeated default header values are all preserved" {
  let options = ClientOptions::new()
    .with_default_header("X-Multi", "one")
    .with_default_header("X-Multi", "two")
  assert_eq(options.default_headers().get_all("X-Multi").length(), 2)

  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
  let stream = regression_mock_stream(raw, 1, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let client = UnifiedClient::{ connector, options, redirect_count: 0 }
  let url = Url::parse("http://example.com/multi").unwrap()
  assert_true(client.request(Request::new(GET, url)) is Ok(_))
  let wire = @utf8.decode_lossy(stream.output.to_bytes()[:])
  assert_true(wire.contains("X-Multi: one\r\n"))
  assert_true(wire.contains("X-Multi: two\r\n"))
}
