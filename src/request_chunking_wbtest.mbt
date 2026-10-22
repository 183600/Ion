///|
test "request chunked transfer coding parameters are recognized" {
  let url = Url::parse("http://example.com/upload").unwrap()
  for value in [
    "chunked;foo=bar",
    "CHUNKED ; foo=bar",
    "chunked;foo=\"a,b\"",
    "chunked; foo = \"a b\"",
    "chunked;foo=\"a\\\"b\"",
    "chunked ; foo=bar ; baz=qux",
    "chunked,",
    ", chunked",
    ",chunked, ,",
  ] {
    let stream = regression_mock_stream("", 0, 0)
    let codec = H1Codec::new(stream)
    let request = Request::new(POST, url)
      .with_header("Transfer-Encoding", value)
      .with_body(b"hello")
    assert_true(codec.encode_request(request) is Ok(_))
    let wire = @utf8.decode(stream.output.to_bytes()[:])
    assert_true(wire.contains("Transfer-Encoding: " + value + "\r\n"))
    assert_true(wire.ends_with("\r\n\r\n5\r\nhello\r\n0\r\n\r\n"))
  }
}

///|
test "request rejects unsupported or repeated transfer codings" {
  let url = Url::parse("http://example.com/upload").unwrap()
  for value in [
    "",
    "gzip",
    "gzip, chunked",
    "chunked, gzip",
    "chunked, chunked",
    "chunked;foo=\"a,b\", gzip",
    "chunked;foo",
    "chunked;foo=",
    "chunked;=bar",
    "chunked;foo=\"unterminated",
    "chunked;foo=bar baz",
  ] {
    let stream = regression_mock_stream("", 0, 0)
    let codec = H1Codec::new(stream)
    let request = Request::new(POST, url)
      .with_header("Transfer-Encoding", value)
      .with_body(b"hello")
    assert_true(codec.encode_request(request) is Err(InvalidHeader(_)))
  }
}

///|
test "request combines repeated Transfer-Encoding field lines" {
  let url = Url::parse("http://example.com/upload").unwrap()
  let stream = regression_mock_stream("", 0, 0)
  let codec = H1Codec::new(stream)
  let request = Request::new(POST, url)
    .with_header("Transfer-Encoding", "chunked")
    .with_header("Transfer-Encoding", "")
    .with_body(b"hello")
  assert_true(codec.encode_request(request) is Ok(_))
  let wire = @utf8.decode(stream.output.to_bytes()[:])
  assert_true(wire.ends_with("\r\n\r\n5\r\nhello\r\n0\r\n\r\n"))
}
