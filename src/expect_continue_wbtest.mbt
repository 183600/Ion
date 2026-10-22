///|
fn expect_wire(stream : RegressionMockStream) -> String {
  @utf8.decode_lossy(stream.output.to_bytes()[:])
}

///|
test "expect 100-continue withholds a fixed-length body until acceptance" {
  let url = Url::parse("http://example.com/upload").unwrap()
  let stream = regression_mock_stream(
    "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok",
    1,
    0,
  )
  let codec = H1Codec::new(stream)
  let request = Request::new(POST, url)
    .with_header("Expect", "100-continue")
    .with_body(@utf8.encode("hello"))
  assert_true(codec.encode_request(request) is Ok(_))
  let head_only = expect_wire(stream)
  assert_true(head_only.contains("Expect: 100-continue\r\n"))
  assert_true(head_only.contains("Content-Length: 5\r\n"))
  assert_true(!head_only.contains("hello"))
  let response = codec.decode_response().unwrap()
  assert_eq(response.status, 200)
  assert_eq(response.text().unwrap(), "ok")
  let wire = expect_wire(stream)
  assert_true(wire.has_suffix("hello"))
  assert_eq(wire.find("hello"), wire.rev_find("hello"))
}

///|
test "a final response without 100 drops the deferred body" {
  let url = Url::parse("http://example.com/upload").unwrap()
  let stream = regression_mock_stream(
    "HTTP/1.1 417 Expectation Failed\r\nContent-Length: 0\r\n\r\n",
    0,
    0,
  )
  let codec = H1Codec::new(stream)
  let request = Request::new(POST, url)
    .with_header("Expect", "100-continue")
    .with_body(@utf8.encode("secret"))
  assert_true(codec.encode_request(request) is Ok(_))
  let response = codec.decode_response().unwrap()
  assert_eq(response.status, 417)
  assert_eq(response.read_body().unwrap(), b"")
  let wire = expect_wire(stream)
  assert_true(!wire.contains("secret"))
}

///|
test "early hints do not release the body but 100 sends it exactly once" {
  let url = Url::parse("http://example.com/upload").unwrap()
  let stream = regression_mock_stream(
    "HTTP/1.1 103 Early Hints\r\nLink: </style.css>; rel=preload\r\n\r\nHTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 204 No Content\r\n\r\n",
    2,
    0,
  )
  let codec = H1Codec::new(stream)
  let request = Request::new(POST, url)
    .with_header("Expect", "100-continue")
    .with_body(@utf8.encode("payload"))
  assert_true(codec.encode_request(request) is Ok(_))
  assert_true(!expect_wire(stream).contains("payload"))
  let response = codec.decode_response().unwrap()
  assert_eq(response.status, 204)
  let wire = expect_wire(stream)
  assert_true(wire.has_suffix("payload"))
  assert_eq(wire.find("payload"), wire.rev_find("payload"))
}

///|
test "expect 100-continue defers chunked bodies and trailers" {
  let url = Url::parse("http://example.com/upload").unwrap()
  let stream = regression_mock_stream(
    "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n",
    0,
    0,
  )
  let codec = H1Codec::new(stream)
  let request = Request::new(POST, url)
    .with_header("Expect", "100-continue")
    .with_header("Transfer-Encoding", "chunked")
    .with_body(@utf8.encode("abc"))
    .with_trailer("X-Checksum", "abc")
  assert_true(codec.encode_request(request) is Ok(_))
  let head_only = expect_wire(stream)
  assert_true(head_only.contains("Transfer-Encoding: chunked\r\n"))
  assert_true(head_only.contains("Trailer: X-Checksum\r\n"))
  assert_true(!head_only.contains("3\r\nabc"))
  let response = codec.decode_response().unwrap()
  assert_eq(response.status, 200)
  let wire = expect_wire(stream)
  assert_true(wire.has_suffix("3\r\nabc\r\n0\r\nX-Checksum: abc\r\n\r\n"))
}

///|
test "requests without an expectation still send the body immediately" {
  let url = Url::parse("http://example.com/upload").unwrap()
  let stream = regression_mock_stream("", 0, 0)
  let codec = H1Codec::new(stream)
  let request = Request::new(POST, url).with_body(@utf8.encode("body"))
  assert_true(codec.encode_request(request) is Ok(_))
  assert_true(expect_wire(stream).has_suffix("body"))
}

///|
test "client sends an expect body after 100 and keeps the exchange usable" {
  let stream = regression_mock_stream(
    "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok",
    0,
    0,
  )
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let options = ClientOptions::new().with_follow_redirects(false)
  let client = UnifiedClient::{ connector, options, redirect_count: 0 }
  let url = Url::parse("http://example.com/upload").unwrap()
  let request = Request::new(POST, url)
    .with_expect_continue()
    .with_body(@utf8.encode("client-body"))
  let response = client.request(request).unwrap()
  assert_eq(response.text().unwrap(), "ok")
  let wire = expect_wire(stream)
  assert_true(wire.has_suffix("client-body"))
  assert_eq(wire.find("client-body"), wire.rev_find("client-body"))
}

///|
test "a final response without 100 never reuses the connection" {
  let url = Url::parse("http://example.com/upload").unwrap()
  let stream = regression_mock_stream(
    "HTTP/1.1 417 Expectation Failed\r\nContent-Length: 0\r\n\r\n",
    0,
    0,
  )
  let codec = H1Codec::new(stream)
  let request = Request::new(POST, url)
    .with_expect_continue()
    .with_body(@utf8.encode("deferred"))
  assert_true(codec.encode_request(request) is Ok(_))
  let response = codec.decode_response().unwrap()
  assert_eq(response.read_body().unwrap(), b"")
  // Dropping the body leaves the request framing incomplete, so the socket
  // must be closed instead of being returned to a keep-alive pool.
  assert_false(stream.is_open)
}
