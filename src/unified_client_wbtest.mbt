test "ClientOptions creation" {
  let options = ClientOptions::new()
  assert_eq(options.user_agent, "Feather/0.1.0")
  assert_eq(options.timeout_ms, 30000)
  assert_eq(options.follow_redirects, true)
  assert_eq(options.max_redirects, 10)
}

test "ClientOptions customization" {
  let options = ClientOptions::new()
    .with_user_agent("CustomAgent/1.0")
    .with_timeout(5000)
    .with_follow_redirects(false)
    .with_max_redirects(5)
  
  assert_eq(options.user_agent, "CustomAgent/1.0")
  assert_eq(options.timeout_ms, 5000)
  assert_eq(options.follow_redirects, false)
  assert_eq(options.max_redirects, 5)
}

test "UnifiedClient creation" {
  let client = UnifiedClient::new()
  assert_eq(client.options.user_agent, "Feather/0.1.0")
  assert_eq(client.redirect_count, 0)
}

test "UnifiedClient with options" {
  let options = ClientOptions::new()
    .with_user_agent("TestAgent/1.0")
    .with_follow_redirects(false)
  
  let client = UnifiedClient::with_options(options)
  assert_eq(client.options.user_agent, "TestAgent/1.0")
  assert_eq(client.options.follow_redirects, false)
}

test "is_redirect function" {
  assert_eq(is_redirect(301), true)
  assert_eq(is_redirect(302), true)
  assert_eq(is_redirect(303), true)
  assert_eq(is_redirect(307), true)
  assert_eq(is_redirect(308), true)
  assert_eq(is_redirect(200), false)
  assert_eq(is_redirect(404), false)
  assert_eq(is_redirect(500), false)
}

test "Connector creation" {
  let dialer = TcpDialer::new()
  let tls_provider = MockTlsProvider::new("test")
  let connector = Connector::new(dialer, tls_provider)
  let _ = connector
  // Test that connector is created successfully
  assert_true(true) // If we got here, it worked
}

test "Connector close_all" {
  let dialer = TcpDialer::new()
  let tls_provider = MockTlsProvider::new("test")
  let connector = Connector::new(dialer, tls_provider)
  
  let result = connector.close_all()
  assert_true(result is Ok(_))
}

// Note: These are basic tests. In a real implementation, we would need mock servers
// to test the actual HTTP request/response flow without making real network calls.
test "UnifiedClient closes pooled connections" {
  let client = UnifiedClient::new()
  assert_true(client.close_all() is Ok(_))
}

test "free get/post helpers validate URLs before dialing" {
  assert_true(get("not a url") is Err(InvalidUrl(_)))
  assert_true(get("ftp://example.com/") is Err(InvalidUrl(_)))
  assert_true(post("not a url", b"body") is Err(InvalidUrl(_)))
}

test "ClientOptions exposes a configurable response body limit" {
  let options = ClientOptions::new()
  assert_eq(options.max_response_body_bytes, 67108864)
  let tightened = options.with_max_response_body_bytes(1024)
  assert_eq(tightened.max_response_body_bytes, 1024)
  let clamped = options.with_max_response_body_bytes(-1)
  assert_eq(clamped.max_response_body_bytes, 0)
}

test "response body limit rejects oversized bodies before reading them" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 200\r\n\r\n" + "a".repeat(200)
  let stream = regression_mock_stream(raw, 1, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let options = ClientOptions::new()
    .with_follow_redirects(false)
    .with_max_response_body_bytes(64)
  let client = UnifiedClient::{ connector, options, redirect_count: 0 }
  let response = client.request(Request::new(GET, Url::parse("http://example.com/").unwrap())).unwrap()
  assert_true(response.read_body() is Err(_))
}

test "response body limit allows bodies within the configured bound" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"
  let stream = regression_mock_stream(raw, 1, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let options = ClientOptions::new()
    .with_follow_redirects(false)
    .with_max_response_body_bytes(5)
  let client = UnifiedClient::{ connector, options, redirect_count: 0 }
  let response = client.request(Request::new(GET, Url::parse("http://example.com/").unwrap())).unwrap()
  assert_eq(response.read_body().unwrap(), b"hello")
}

test "UnifiedClient exposes pool tuning on the connector" {
  let client = UnifiedClient::new()
  let tuned = client
    .with_max_idle_per_host(3)
    .with_max_connections_per_host(4)
    .with_idle_timeout(1500)
  assert_eq(tuned.connector.max_idle_per_host(), 3)
  assert_eq(tuned.connector.max_connections_per_host(), 4)
  assert_eq(tuned.connector.idle_timeout(), 1500)
}

///|
test "one-shot helpers buffer the body before closing the client" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"
  let stream = regression_mock_stream(raw, 0, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let options = ClientOptions::new().with_follow_redirects(false)
  let client = UnifiedClient::{ connector, options, redirect_count: 0 }
  let response = client.get("http://example.com/").unwrap()
  let buffered = buffer_one_shot_response(client, Ok(response)).unwrap()
  assert_eq(buffered.text().unwrap(), "hello")
  assert_false(stream.is_open)
}

///|
test "one-shot helpers preserve chunked trailers" {
  let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" +
    "5\r\nhello\r\n0\r\nX-Checksum: abc\r\n\r\n"
  let stream = regression_mock_stream(raw, 0, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let options = ClientOptions::new().with_follow_redirects(false)
  let client = UnifiedClient::{ connector, options, redirect_count: 0 }
  let response = client.get("http://example.com/").unwrap()
  let buffered = buffer_one_shot_response(client, Ok(response)).unwrap()
  assert_eq(buffered.text().unwrap(), "hello")
  assert_eq(buffered.trailers().get("x-checksum"), Some("abc"))
}

///|
test "UnifiedClient exposes runtime option builders" {
  let client = UnifiedClient::new()
    .with_user_agent("Runtime/1.0")
    .with_timeout(-5)
    .with_follow_redirects(false)
    .with_max_redirects(-1)
    .with_max_response_body_bytes(-1)
    .with_http2(false)
  let options = client.client_options()
  assert_eq(options.user_agent, "Runtime/1.0")
  assert_eq(options.timeout_ms, 0)
  assert_eq(options.follow_redirects, false)
  assert_eq(options.max_redirects, 0)
  assert_eq(options.max_response_body_bytes, 0)
  assert_eq(options.http2, false)
  assert_false(client.connector.http2_enabled())

  let enabled = client.with_http2(true)
  assert_true(enabled.client_options().http2)
  assert_true(enabled.connector.http2_enabled())
}

///|
test "changing the client timeout also changes connection and handshake timeouts" {
  let client = UnifiedClient::new().with_timeout(1234)
  assert_eq(client.client_options().timeout_ms, 1234)
  assert_eq(client.connector.timeout(), 1234)
  let clamped = client.with_timeout(-1)
  assert_eq(clamped.client_options().timeout_ms, 0)
  assert_eq(clamped.connector.timeout(), 0)
  // The connector timeout setter is in-place, like the pool tuning setters, so
  // an ignored return value cannot leave new dials using the old timeout.
  let connector = Connector::new(TcpDialer::new(), MockTlsProvider::new("test"))
  let _ = connector.with_timeout(4321)
  assert_eq(connector.timeout(), 4321)
}

///|
test "client timeout builders do not mutate the source client" {
  let original = UnifiedClient::new()
  let changed = original.with_timeout(1234)
  assert_eq(changed.client_options().timeout_ms, 1234)
  assert_eq(changed.connector.timeout(), 1234)
  assert_eq(original.client_options().timeout_ms, 30000)
  assert_eq(original.connector.timeout(), 30000)
}
