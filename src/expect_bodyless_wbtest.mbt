/// RFC 9110 §10.1.1: the 100-continue expectation only applies to requests
/// that carry content, so a bodyless request must not advertise it.
test "expect 100-continue is omitted from bodyless requests" {
  let url = Url::parse("http://example.com/").unwrap()
  let requests = [
    Request::new(GET, url).with_expect_continue(),
    Request::new(POST, url).with_expect_continue(),
    Request::new(GET, url).with_body(b"").with_expect_continue(),
    Request::new(GET, url)
      .set_header("Transfer-Encoding", "chunked")
      .with_expect_continue(),
  ]
  for request in requests {
    let stream = regression_mock_stream("", 0, 0)
    let codec = H1Codec::new(stream)
    assert_true(codec.encode_request(request) is Ok(_))
    let wire = @utf8.decode_lossy(stream.output.to_bytes()[:])
    assert_false(wire.to_lower().contains("expect:"))
  }
}

test "expect 100-continue is kept when the request has content" {
  let url = Url::parse("http://example.com/").unwrap()
  let stream = regression_mock_stream("", 0, 0)
  let codec = H1Codec::new(stream)
  let request = Request::new(POST, url)
    .with_body(b"payload")
    .with_expect_continue()
  assert_true(codec.encode_request(request) is Ok(_))
  let wire = @utf8.decode_lossy(stream.output.to_bytes()[:])
  assert_true(wire.contains("Expect: 100-continue\r\n"))
  assert_false(wire.contains("payload"))
}

test "non-continue expectations survive a bodyless request" {
  let url = Url::parse("http://example.com/").unwrap()
  let stream = regression_mock_stream("", 0, 0)
  let codec = H1Codec::new(stream)
  let request = Request::new(GET, url)
    .with_header("Expect", "100-continue, x-custom")
  assert_true(codec.encode_request(request) is Ok(_))
  let wire = @utf8.decode_lossy(stream.output.to_bytes()[:])
  assert_true(wire.contains("Expect: x-custom\r\n"))
  assert_false(wire.contains("100-continue"))
}
