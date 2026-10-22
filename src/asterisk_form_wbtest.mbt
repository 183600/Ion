///|
test "http1 encodes the asterisk-form OPTIONS target" {
  let stream = regression_mock_stream("", 0, 0)
  let codec = H1Codec::new(stream)
  let url = Url::parse("http://example.com").unwrap().with_path("*")
  let request = Request::new(OPTIONS, url)
  assert_true(codec.encode_request(request) is Ok(_))
  let wire = @utf8.decode_lossy(stream.output.to_bytes()[:])
  assert_true(wire.has_prefix("OPTIONS * HTTP/1.1\r\n"))
  assert_true(wire.contains("\r\nHost: example.com\r\n"))
}

///|
test "http1 rejects asterisk-form outside OPTIONS" {
  let stream = regression_mock_stream("", 0, 0)
  let codec = H1Codec::new(stream)
  let url = Url::parse("http://example.com").unwrap().with_path("*")
  let request = Request::new(GET, url)
  match codec.encode_request(request) {
    Ok(_) => fail("asterisk-form GET was accepted")
    Err(err) => assert_eq(err, InvalidUrl("Asterisk-form is only valid for OPTIONS"))
  }
  assert_eq(stream.output.to_bytes().length(), 0)
}

///|
test "http2 uses the asterisk-form path for OPTIONS" {
  let url = Url::parse("https://example.com").unwrap().with_path("*")
  let fields = h2_request_headers(Request::new(OPTIONS, url)).unwrap()
  let mut path = None
  for field in fields {
    if field.0 == ":path" {
      path = Some(field.1)
    }
  }
  assert_eq(path, Some("*"))

  let rejected = Url::parse("https://example.com").unwrap().with_path("*")
  match h2_request_headers(Request::new(GET, rejected)) {
    Ok(_) => fail("asterisk-form GET was accepted")
    Err(err) => assert_eq(err, InvalidUrl("Asterisk-form is only valid for OPTIONS"))
  }
}
