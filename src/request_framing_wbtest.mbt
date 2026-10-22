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
  assert_eq(
    response.read_body().unwrap(),
    @utf8.encode("5\r\nhello\r\n0\r\n\r\n"),
  )
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
test "empty transfer encoding response header is rejected" {
  for value in ["", " ", ",", " , "] {
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
  assert_eq(
    response.read_body().unwrap(),
    @utf8.encode("5\r\nhello\r\n0\r\n\r\n"),
  )
}

///|
test "chunked response trailers are exposed after the body" {
  let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\nX-Checksum: abc\r\nX-Multi: one\r\nX-Multi: two\r\n\r\n"
  let codec = H1Codec::new(regression_mock_stream(raw, 4096, 4096))
  let response = codec.decode_response().unwrap()
  assert_eq(response.trailers().length(), 0)
  assert_eq(response.read_body().unwrap(), b"hello")
  assert_eq(response.trailers().get("x-checksum"), Some("abc"))
  assert_eq(response.trailers().get_all("X-Multi").nth(0), Some("one"))
  assert_eq(response.trailers().get_all("X-Multi").nth(1), Some("two"))
}

///|
test "chunk size accepts BWS before extensions" {
  let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5 \t;foo=bar\r\nhello\r\n0\r\n\r\n"
  let codec = H1Codec::new(regression_mock_stream(raw, 4096, 4096))
  let response = codec.decode_response().unwrap()
  assert_eq(response.read_body().unwrap(), b"hello")
}

///|
test "chunk size without extensions rejects trailing whitespace" {
  let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5 \r\nhello\r\n0\r\n\r\n"
  let codec = H1Codec::new(regression_mock_stream(raw, 4096, 4096))
  let response = codec.decode_response().unwrap()
  assert_true(response.read_body() is Err(NetworkError(ReadError(_))))
}

///|
test "chunk size rejects embedded control characters before extensions" {
  let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r;foo=bar\r\nhello\r\n0\r\n\r\n"
  let codec = H1Codec::new(regression_mock_stream(raw, 4096, 4096))
  let response = codec.decode_response().unwrap()
  assert_true(response.read_body() is Err(NetworkError(ReadError(_))))
}

///|
test "non-chunked responses have no trailers" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
  let codec = H1Codec::new(regression_mock_stream(raw, 4096, 4096))
  let response = codec.decode_response().unwrap()
  assert_eq(response.read_body().unwrap(), b"ok")
  assert_eq(response.trailers().length(), 0)
}

test "bodyless responses still validate framing fields" {
  for raw in [
    "HTTP/1.1 304 Not Modified\r\nContent-Length: nope\r\n\r\n",
    "HTTP/1.1 304 Not Modified\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\n",
    "HTTP/1.0 204 No Content\r\nTransfer-Encoding: chunked;bad\r\n\r\n",
  ] {
    let codec = H1Codec::new(regression_mock_stream(raw, 0, 0))
    let response = codec.decode_response().unwrap()
    assert_true(response.read_body() is Err(_))
  }
}

///|
test "informational responses must not include framing headers" {
  for raw in [
    "HTTP/1.1 100 Continue\r\nContent-Length: 0\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok",
    "HTTP/1.1 103 Early Hints\r\nTransfer-Encoding: chunked\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok",
    "HTTP/1.1 101 Switching Protocols\r\nContent-Length: 0\r\n\r\n",
  ] {
    let codec = H1Codec::new(regression_mock_stream(raw, 4096, 4096))
    match codec.decode_response() {
      Ok(_) => fail("informational response with framing headers was accepted")
      Err(err) =>
        assert_eq(
          err,
          ProtocolError("Informational response must not include framing headers"),
        )
    }
  }
}

///|
test "204 and 205 reject framing that implies a body" {
  for raw in [
    "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n",
    "HTTP/1.1 204 No Content\r\nContent-Length: 5\r\n\r\n",
    "HTTP/1.1 204 No Content\r\nTransfer-Encoding: chunked\r\n\r\n",
    "HTTP/1.1 205 Reset Content\r\nContent-Length: 1\r\n\r\n",
    "HTTP/1.1 205 Reset Content\r\nTransfer-Encoding: chunked\r\n\r\n",
  ] {
    let codec = H1Codec::new(regression_mock_stream(raw, 4096, 4096))
    let response = codec.decode_response().unwrap()
    match response.read_body() {
      Ok(_) => fail("bodyless response accepted body framing")
      Err(err) => assert_true(err is NetworkError(ReadError(_)))
    }
  }

  let empty_205 = "HTTP/1.1 205 Reset Content\r\nContent-Length: 0\r\n\r\n"
  let response = H1Codec::new(
    regression_mock_stream(empty_205, 4096, 4096),
  ).decode_response().unwrap()
  assert_eq(response.read_body().unwrap(), b"")

  // A 304 response can advertise the length of the selected representation.
  let not_modified = "HTTP/1.1 304 Not Modified\r\nContent-Length: 5\r\n\r\n"
  let response = H1Codec::new(
    regression_mock_stream(not_modified, 4096, 4096),
  ).decode_response().unwrap()
  assert_eq(response.read_body().unwrap(), b"")
}

///|
test "the whole response header section is bounded" {
  let raw = Buffer(size_hint=1100000)
  raw.write_bytes(@utf8.encode("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n"))
  let padding = "a".repeat(8000)
  let mut index = 0
  while index < 135 {
    raw.write_bytes(@utf8.encode("X-Pad-" + index.to_string() + ": " + padding + "\r\n"))
    index = index + 1
  }
  raw.write_bytes(@utf8.encode("\r\n"))
  let text = @utf8.decode(raw.to_bytes()[:])
  let codec = H1Codec::new(regression_mock_stream(text, 65536, 65536))
  match codec.decode_response() {
    Ok(_) => fail("oversized response header section was accepted")
    Err(err) => assert_eq(err, ProtocolError("Response header section too large"))
  }
}

///|
test "the whole chunked trailer section is bounded" {
  let raw = Buffer(size_hint=1100000)
  raw.write_bytes(
    @utf8.encode(
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n",
    ),
  )
  let padding = "a".repeat(8000)
  let mut index = 0
  while index < 135 {
    raw.write_bytes(@utf8.encode("X-Trailer-" + index.to_string() + ": " + padding + "\r\n"))
    index = index + 1
  }
  raw.write_bytes(@utf8.encode("\r\n"))
  let text = @utf8.decode(raw.to_bytes()[:])
  let response = H1Codec::new(
    regression_mock_stream(text, 65536, 65536),
  ).decode_response().unwrap()
  match response.read_body() {
    Ok(_) => fail("oversized chunked trailer section was accepted")
    Err(err) => assert_true(err is NetworkError(ReadError(_)))
  }
}

///|
test "304 responses with transfer coding are not pooled" {
  let raw = "HTTP/1.1 304 Not Modified\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
  let stream = regression_mock_stream(raw, 1, 0)
  let codec = H1Codec::new(stream)
  let response = codec.decode_response().unwrap()
  assert_eq(response.status, 304)
  assert_eq(response.read_body().unwrap(), b"")
  // The unread chunk framing must not be left on a reused connection.
  assert_false(stream.is_open)
  assert_true(codec.decode_response() is Err(_))
}
