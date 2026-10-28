///|
test "IPv6 zone-preserving folding canonicalizes the address" {
  let upper = cookie_canonical_host("FE80::1%25ETH0")
  assert_true(upper.has_suffix("%25ETH0"))
  assert_false(upper.has_suffix("%25eth0"))
  assert_eq(cookie_canonical_host("FE80::1"), "fe80::1")
  assert_eq(cookie_canonical_host("Example.COM."), "example.com")
  assert_true(
    cookie_canonical_host("fe80::1%25ETH0.").has_suffix("%25ETH0."),
  )
}

///|
test "IPv6 zone identifiers are case-sensitive for cookies" {
  let jar = CookieJar::new()
  let upper = Url::parse("http://[fe80::1%25ETH0]/").unwrap()
  let lower = Url::parse("http://[fe80::1%25eth0]/").unwrap()
  jar.store_at(upper, "sid=upper; Path=/", 1000)
  assert_eq(jar.cookie_header_at(upper, 1000), Some("sid=upper"))
  assert_eq(jar.cookie_header_at(lower, 1000), None)
  jar.store_at(lower, "sid=lower; Path=/", 1000)
  assert_eq(jar.length(), 2)
  assert_eq(jar.cookie_header_at(lower, 1000), Some("sid=lower"))
}

///|
test "connection keys distinguish IPv6 zone case" {
  let connector = Connector::new(TcpDialer::new(), MockTlsProvider::new("test"))
  let upper = Url::parse("http://[fe80::1%25ETH0]/").unwrap()
  let lower = Url::parse("http://[fe80::1%25eth0]/").unwrap()
  let upper_again = Url::parse("http://[FE80::1%25ETH0]/").unwrap()
  assert_true(connector.connection_key(upper) != connector.connection_key(lower))
  assert_eq(
    connector.connection_key(upper),
    connector.connection_key(upper_again),
  )
}

///|
test "proxy connection keys distinguish IPv6 zone case" {
  let url = Url::parse("http://example.com/").unwrap()
  let upper = Connector::new(TcpDialer::new(), MockTlsProvider::new("test"))
    .with_proxy(Proxy::parse("http://[fe80::1%25ETH0]:8080").unwrap())
  let lower = Connector::new(TcpDialer::new(), MockTlsProvider::new("test"))
    .with_proxy(Proxy::parse("http://[fe80::1%25eth0]:8080").unwrap())
  assert_true(upper.connection_key(url) != lower.connection_key(url))
}

///|
test "NO_PROXY IPv6 zone identifiers are case-sensitive" {
  assert_false(
    proxy_bypass_matches(
      "[fe80::1%25ETH0]",
      "fe80::1%25eth0",
      80,
      bracketed=true,
    ),
  )
  assert_true(
    proxy_bypass_matches(
      "[fe80::1%25ETH0]",
      "fe80::1%25ETH0",
      80,
      bracketed=true,
    ),
  )
  assert_true(proxy_bypass_matches("EXAMPLE.COM", "example.com", 80))
}

///|
test "same_request_target distinguishes IPv6 zone case" {
  let upper = Url::parse("http://[fe80::1%25ETH0]/x").unwrap()
  let lower = Url::parse("http://[fe80::1%25eth0]/x").unwrap()
  let upper_again = Url::parse("http://[FE80::1%25ETH0]/x").unwrap()
  assert_false(same_request_target(upper, lower))
  assert_true(same_request_target(upper, upper_again))
}

///|
test "redirects treat IPv6 zone case as cross-origin" {
  let raw = "HTTP/1.1 302 Found\r\nLocation: http://[fe80::1%25eth0]/next\r\nContent-Length: 0\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
  let stream = regression_mock_stream(raw, 1, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let client = UnifiedClient::{
    connector,
    options: ClientOptions::new(),
    redirect_count: 0,
  }
  let url = Url::parse("http://[fe80::1%25ETH0]/start").unwrap()
  let request = Request::new(GET, url).with_header(
    "Authorization",
    "Bearer token",
  )
  let response = client.request(request).unwrap()
  assert_eq(response.status, 200)
  assert_eq(response.text().unwrap(), "ok")
  let wire = @utf8.decode_lossy(stream.output.to_bytes()[:])
  let next_index = wire.find("GET /next HTTP/1.1").unwrap()
  let second_request = wire.substring(start=next_index)
  assert_false(second_request.contains("Authorization"))
  assert_true(second_request.contains("Host: [fe80::1%25eth0]"))
}

///|
test "CONNECT Host comparison preserves IPv6 zone case" {
  let url = Url::parse("http://[fe80::1%25ETH0]:443/").unwrap()
  let mismatch_stream = regression_mock_stream("", 0, 0)
  let mismatch = H1Codec::new(mismatch_stream)
  assert_true(
    mismatch.encode_request(
      Request::new(CONNECT, url).with_header(
        "Host",
        "[fe80::1%25eth0]:443",
      ),
    ) is Err(InvalidHeader(_)),
  )
  let matching_stream = regression_mock_stream("", 0, 0)
  let matching = H1Codec::new(matching_stream)
  assert_true(
    matching.encode_request(
      Request::new(CONNECT, url).with_header(
        "Host",
        "[fe80::1%25ETH0]:443",
      ),
    ) is Ok(_),
  )
}
