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
test "invalid custom method tokens are rejected at the wire boundary" {
  // The `Custom` variant is public, so a caller can bypass
  // `HttpMethod::custom`. Both codecs must still refuse to serialize a token
  // containing a separator or whitespace.
  let url = Url::parse("http://example.com/").unwrap()
  let request = Request::new(Custom("BAD METHOD"), url)
  let stream = regression_mock_stream("", 0, 0)
  assert_true(H1Codec::new(stream).encode_request(request) is Err(InvalidMethod(_)))
  assert_true(h2_request_headers(request) is Err(InvalidMethod(_)))
}

///|
test "strict method parsing still rejects extension methods" {
  // Extension methods need `HttpMethod::custom` so a typo such as "breww"
  // cannot silently become a wire method in the strict parser/CLI path.
  assert_true(HttpMethod::parse("PROPFIND") is Err(InvalidMethod(_)))
  assert_eq(HttpMethod::custom("proppatch").unwrap().to_string(), "proppatch")
}

test "uppercase standard Custom methods keep H1 framing semantics" {
  let url = Url::parse("http://example.com/").unwrap()
  let head_stream = regression_mock_stream(
    "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello",
    4096,
    4096,
  )
  let head_codec = H1Codec::new(head_stream)
  head_codec.encode_request(Request::new(Custom("HEAD"), url)).unwrap()
  assert_eq(head_codec.decode_response().unwrap().read_body().unwrap(), b"")

  let connect_stream = regression_mock_stream("", 0, 0)
  let connect_codec = H1Codec::new(connect_stream)
  connect_codec.encode_request(Request::new(Custom("CONNECT"), url)).unwrap()
  let wire = @utf8.decode_lossy(connect_stream.output.to_bytes()[:])
  assert_true(wire.has_prefix("CONNECT example.com:80 HTTP/1.1\r\n"))

  let with_path = Url::parse("http://example.com/tunnel").unwrap()
  let codec = H1Codec::new(regression_mock_stream("", 0, 0))
  assert_true(
    codec.encode_request(Request::new(Custom("CONNECT"), with_path))
      is Err(InvalidUrl(_)),
  )
}

test "uppercase standard Custom methods keep H2 pseudo-header semantics" {
  let connect = h2_request_headers(
    Request::new(
      Custom("CONNECT"),
      Url::parse("https://example.com:443/").unwrap(),
    ),
  ).unwrap()
  assert_eq(h2_test_header_value(connect, ":method"), Some("CONNECT"))
  assert_eq(h2_test_header_value(connect, ":authority"), Some("example.com:443"))
  assert_eq(h2_test_header_value(connect, ":scheme"), None)
  assert_eq(h2_test_header_value(connect, ":path"), None)
  let options = h2_request_headers(
    Request::new(
      Custom("OPTIONS"),
      Url::parse("https://example.com").unwrap().with_path("*"),
    ),
  ).unwrap()
  assert_eq(h2_test_header_value(options, ":path"), Some("*"))
}
