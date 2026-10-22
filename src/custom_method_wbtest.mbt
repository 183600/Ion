///|
test "custom methods validate RFC 9110 tokens" {
  assert_eq(HttpMethod::custom("PROPFIND"), Ok(Custom("PROPFIND")))
  assert_eq(HttpMethod::custom("PURGE"), Ok(Custom("PURGE")))
  // Standard methods keep their dedicated variants, including mixed case.
  assert_eq(HttpMethod::custom("get"), Ok(GET))
  assert_eq(HttpMethod::custom("CONNECT"), Ok(CONNECT))
  // Unknown methods are case-sensitive and preserve their spelling.
  assert_eq(HttpMethod::custom("propfind").unwrap().to_string(), "propfind")
  for invalid in ["", "BAD METHOD", "BAD\tMETHOD", "GET:", "prop/find", "méthod"] {
    assert_true(HttpMethod::custom(invalid) is Err(InvalidMethod(_)))
  }
}

///|
test "custom methods are encoded as HTTP/1.1 request methods" {
  let stream = regression_mock_stream("", 0, 0)
  let verb = HttpMethod::custom("PROPFIND").unwrap()
  let url = Url::parse("http://example.com/dav/resource").unwrap()
  let request = Request::new(verb, url)
  let codec = H1Codec::new(stream)
  assert_true(codec.encode_request(request) is Ok(_))
  let wire = @utf8.decode_lossy(stream.output.to_bytes()[:])
  assert_true(wire.has_prefix("PROPFIND /dav/resource HTTP/1.1\r\n"))
  assert_true(wire.contains("\r\nHost: example.com\r\n"))
}

///|
test "custom methods are encoded as HTTP/2 :method fields" {
  let verb = HttpMethod::custom("PROPFIND").unwrap()
  let url = Url::parse("http://example.com/dav/resource").unwrap()
  let fields = h2_request_headers(Request::new(verb, url)).unwrap()
  assert_true(fields.contains((":method", "PROPFIND")))
  assert_true(fields.contains((":path", "/dav/resource")))
}

///|
test "strict method parsing still rejects extension methods" {
  // Extension methods need `HttpMethod::custom` so a typo such as "breww"
  // cannot silently become a wire method in the strict parser/CLI path.
  assert_true(HttpMethod::parse("PROPFIND") is Err(InvalidMethod(_)))
  assert_eq(HttpMethod::custom("proppatch").unwrap().to_string(), "proppatch")
}
