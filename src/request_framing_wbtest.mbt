///|
test "body-less methods that define a body send Content-Length zero" {
  let url = Url::parse("http://example.com/submit").unwrap()
  for method in [POST, PUT, PATCH] {
    let stream = regression_mock_stream("", 0, 0)
    let codec = H1Codec::new(stream)
    assert_true(codec.encode_request(Request::new(method, url)) is Ok(_))
    let wire = @utf8.decode(stream.output.to_bytes()[:])
    assert_true(wire.contains("Content-Length: 0\r\n"))
  }
}

///|
test "body-less methods without a body semantic omit Content-Length" {
  let url = Url::parse("http://example.com/thing").unwrap()
  for method in [GET, DELETE, HEAD, OPTIONS] {
    let stream = regression_mock_stream("", 0, 0)
    let codec = H1Codec::new(stream)
    assert_true(codec.encode_request(Request::new(method, url)) is Ok(_))
    let wire = @utf8.decode(stream.output.to_bytes()[:])
    assert_true(!wire.contains("Content-Length"))
  }
}

///|
test "explicit Content-Length and chunked framing are preserved" {
  let url = Url::parse("http://example.com/submit").unwrap()
  let explicit = regression_mock_stream("", 0, 0)
  let explicit_codec = H1Codec::new(explicit)
  assert_true(
    explicit_codec.encode_request(
      Request::new(POST, url).with_header("Content-Length", "0"),
    ) is Ok(_),
  )
  assert_true(
    @utf8.decode(explicit.output.to_bytes()[:]).contains("Content-Length: 0\r\n"),
  )

  let chunked = regression_mock_stream("", 0, 0)
  let chunked_codec = H1Codec::new(chunked)
  assert_true(
    chunked_codec.encode_request(
      Request::new(POST, url).with_header("Transfer-Encoding", "chunked"),
    ) is Ok(_),
  )
  let wire = @utf8.decode(chunked.output.to_bytes()[:])
  assert_true(wire.contains("Transfer-Encoding: chunked\r\n"))
  assert_true(!wire.contains("Content-Length"))
}

///|
test "transfer coding lists ignore commas inside quoted parameters" {
  let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked;foo=\"a,b\"\r\nContent-Length: 5\r\n\r\n5\r\nhello\r\n0\r\n\r\n"
  let codec = H1Codec::new(regression_mock_stream(raw, 4096, 4096))
  let response = codec.decode_response().unwrap()
  assert_eq(response.read_body().unwrap(), b"hello")

  let not_final = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked;foo=\"a,b\", gzip\r\n\r\n5\r\nhello\r\n0\r\n\r\n"
  let codec = H1Codec::new(regression_mock_stream(not_final, 4096, 4096))
  let response = codec.decode_response().unwrap()
  assert_true(response.read_body() is Err(NetworkError(ReadError(_))))
}

///|
test "invalid transfer coding parameters are rejected" {
  for value in [
    "chunked;foo",
    "chunked;foo=",
    "chunked;=bar",
    "chunked;foo=\"unterminated",
    "chunked;foo=bar baz",
  ] {
    let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: " + value + "\r\n\r\n"
    let codec = H1Codec::new(regression_mock_stream(raw, 4096, 4096))
    let response = codec.decode_response().unwrap()
    assert_true(response.read_body() is Err(NetworkError(ReadError(_))))
  }
}

///|
test "chunked transfer coding parameters are recognized" {
  let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked;foo=bar\r\nContent-Length: 5\r\n\r\n5\r\nhello\r\n0\r\n\r\n"
  let codec = H1Codec::new(regression_mock_stream(raw, 4096, 4096))
  let response = codec.decode_response().unwrap()
  assert_eq(response.read_body().unwrap(), b"hello")

  let not_final = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked;foo=bar, gzip\r\n\r\n5\r\nhello\r\n0\r\n\r\n"
  let codec = H1Codec::new(regression_mock_stream(not_final, 4096, 4096))
  let response = codec.decode_response().unwrap()
  assert_true(response.read_body() is Err(NetworkError(ReadError(_))))
}
