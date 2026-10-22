///|
test "Request::from_url sends URL userinfo as basic auth" {
  let request = Request::from_url(GET, "http://user:pass@example.com/path?q=1").unwrap()
  assert_eq(request.url.host, "example.com")
  assert_eq(request.url.path, "/path")
  assert_eq(request.get_header("Authorization").unwrap(), "Basic dXNlcjpwYXNz")
}

///|
test "Request::from_url decodes percent-encoded userinfo" {
  let request = Request::from_url(GET, "http://caf%C3%A9:s%C3%A9cret@example.com/").unwrap()
  let expected = "Basic " + @base64.encode(@utf8.encode("café:sécret"))
  assert_eq(request.get_header("Authorization").unwrap(), expected)
}

///|
test "Request::from_url handles user-only and empty passwords" {
  let user_only = Request::from_url(GET, "http://alice@example.com/").unwrap()
  assert_eq(user_only.get_header("Authorization").unwrap(), "Basic YWxpY2U6")
  let empty_password = Request::from_url(GET, "http://alice:@example.com/").unwrap()
  assert_eq(empty_password.get_header("Authorization").unwrap(), "Basic YWxpY2U6")
  let colon_in_password = Request::from_url(GET, "http://alice:a%3Ab@example.com/").unwrap()
  assert_eq(
    colon_in_password.get_header("Authorization").unwrap(),
    "Basic YWxpY2U6YTpi",
  )
}

///|
test "Request::from_url ignores absent and empty userinfo" {
  let plain = Request::from_url(GET, "http://example.com/").unwrap()
  assert_true(plain.get_header("Authorization") is None)
  let empty = Request::from_url(GET, "http://@example.com/").unwrap()
  assert_true(empty.get_header("Authorization") is None)
}

///|
test "Request::from_url reports URL errors" {
  assert_true(Request::from_url(GET, "http://example.com:0/") is Err(_))
}

///|
test "UnifiedClient convenience methods use URL credentials" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
  let stream = regression_mock_stream(raw, 0, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let client = UnifiedClient::{ connector, options: ClientOptions::new(), redirect_count: 0 }
  let response = client.get("http://user:pass@example.com/private").unwrap()
  assert_eq(response.status, 200)
  let wire = @utf8.decode(stream.output.to_bytes()[:])
  assert_true(wire.contains("Authorization: Basic dXNlcjpwYXNz\r\n"))
  assert_true(wire.contains("GET /private HTTP/1.1\r\n"))
}

///|
test "URL credentials do not leak across origins on redirect" {
  let first = regression_mock_stream(
    "HTTP/1.1 302 Found\r\nLocation: http://other.example/next\r\nContent-Length: 0\r\n\r\n",
    0,
    0,
  )
  let second = regression_mock_stream("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok", 0, 0)
  let dialer = RegressionQueueDialer::{ streams: [first, second], index: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let client = UnifiedClient::{ connector, options: ClientOptions::new(), redirect_count: 0 }
  let response = client.get("http://user:pass@example.com/start").unwrap()
  assert_eq(response.status, 200)
  let first_wire = @utf8.decode(first.output.to_bytes()[:])
  assert_true(first_wire.contains("Authorization: Basic dXNlcjpwYXNz\r\n"))
  let second_wire = @utf8.decode(second.output.to_bytes()[:])
  assert_true(!second_wire.contains("Authorization"))
}

///|
test "URL credentials work with form posts" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
  let stream = regression_mock_stream(raw, 0, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let client = UnifiedClient::{ connector, options: ClientOptions::new(), redirect_count: 0 }
  let _ = client.post_form("http://user:pass@example.com/form", [("a", "b")]).unwrap()
  let wire = @utf8.decode(stream.output.to_bytes()[:])
  assert_true(wire.contains("Authorization: Basic dXNlcjpwYXNz\r\n"))
  assert_true(wire.contains("a=b"))
}
