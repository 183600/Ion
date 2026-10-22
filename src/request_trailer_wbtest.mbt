///|
/// Request trailers are framed differently by HTTP/1.1 (chunked trailer
/// section) and HTTP/2 (a trailing HEADERS frame). These tests cover both
/// encoders and the validation that keeps forbidden fields off the wire.
test "http1 request trailers use chunked framing and are advertised" {
  let stream = regression_mock_stream("", 0, 0)
  let codec = H1Codec::new(stream)
  let url = Url::parse("http://example.com/upload").unwrap()
  let request = Request::new(POST, url)
    .with_body(@utf8.encode("hello"))
    .with_trailer("X-Checksum", "abc")
  assert_true(codec.encode_request(request) is Ok(_))
  assert_eq(
    stream.output.to_bytes(),
    @utf8.encode(
      "POST /upload HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\nTrailer: X-Checksum\r\nUser-Agent: Feather/0.1.0\r\n\r\n5\r\nhello\r\n0\r\nX-Checksum: abc\r\n\r\n",
    ),
  )
}

///|
test "http1 request trailers work with an explicit chunked coding" {
  let stream = regression_mock_stream("", 0, 0)
  let codec = H1Codec::new(stream)
  let url = Url::parse("http://example.com/upload").unwrap()
  let request = Request::new(POST, url)
    .with_header("Transfer-Encoding", "chunked")
    .with_body(@utf8.encode("hello"))
    .with_trailer("X-Checksum", "abc")
  assert_true(codec.encode_request(request) is Ok(_))
  let wire = @utf8.decode_lossy(stream.output.to_bytes()[:])
  assert_eq(wire.split("Transfer-Encoding: chunked").length(), 2)
  assert_true(wire.has_suffix("5\r\nhello\r\n0\r\nX-Checksum: abc\r\n\r\n"))
}

///|
test "http1 empty request body can still carry trailers" {
  let stream = regression_mock_stream("", 0, 0)
  let codec = H1Codec::new(stream)
  let url = Url::parse("http://example.com/").unwrap()
  let request = Request::new(POST, url).with_trailer("X-Done", "yes")
  assert_true(codec.encode_request(request) is Ok(_))
  assert_eq(
    stream.output.to_bytes(),
    @utf8.encode(
      "POST / HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\nTrailer: X-Done\r\nUser-Agent: Feather/0.1.0\r\n\r\n0\r\nX-Done: yes\r\n\r\n",
    ),
  )
}

///|
test "http1 request trailers reject content length and forbidden fields" {
  let url = Url::parse("http://example.com/").unwrap()
  let stream = regression_mock_stream("", 0, 0)
  let codec = H1Codec::new(stream)
  let framed = Request::new(POST, url)
    .with_header("Content-Length", "0")
    .with_trailer("X-Done", "yes")
  assert_true(codec.encode_request(framed) is Err(InvalidHeader(_)))
  assert_eq(stream.output.to_bytes().length(), 0)

  for name in ["Content-Length", "Host", "Authorization", "Set-Cookie"] {
    let stream = regression_mock_stream("", 0, 0)
    let codec = H1Codec::new(stream)
    let request = Request::new(POST, url)
      .with_body(@utf8.encode("body"))
      .with_trailer(name, "value")
    assert_true(codec.encode_request(request) is Err(InvalidHeader(_)))
    assert_eq(stream.output.to_bytes().length(), 0)
  }
}

///|
test "http1 request trailers reject header injection" {
  let stream = regression_mock_stream("", 0, 0)
  let codec = H1Codec::new(stream)
  let url = Url::parse("http://example.com/").unwrap()
  let request = Request::new(POST, url)
    .with_body(@utf8.encode("body"))
    .with_trailer("X-Test", "ok\r\nInjected: yes")
  assert_true(codec.encode_request(request) is Err(InvalidHeader(_)))
  assert_eq(stream.output.to_bytes().length(), 0)
}

///|
test "http2 request trailers use a trailing HEADERS frame" {
  let response_headers = hpack_encode([(":status", "200")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(
      H2_FRAME_HEADERS,
      H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM,
      1,
      response_headers,
    ),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let request = Request::new(
      POST,
      Url::parse("https://example.com/upload").unwrap(),
    )
    .with_body(@utf8.encode("hello"))
    .with_trailer("X-Checksum", "abc")
  assert_eq(h2_request(stream, request).unwrap().status, 200)

  let frames = h2_test_client_frames(stream)
  let header_frames : Array[H2Frame] = []
  for frame in frames {
    if frame.frame_type == H2_FRAME_HEADERS && frame.stream_id == 1 {
      header_frames.push(frame)
    }
  }
  assert_eq(header_frames.length(), 2)
  assert_eq(header_frames[0].flags & H2_FLAG_END_STREAM, 0)
  assert_eq(
    header_frames[1].flags & (H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM),
    H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM,
  )
  let decoder = HpackDecoder::new()
  let initial = decoder.decode(header_frames[0].payload).unwrap()
  assert_eq(h2_test_header_value(initial, ":method"), Some("POST"))
  assert_eq(h2_test_header_value(initial, "trailer"), Some("x-checksum"))
  let trailers = decoder.decode(header_frames[1].payload).unwrap()
  assert_eq(h2_test_header_value(trailers, "x-checksum"), Some("abc"))
  let mut saw_data = false
  for frame in frames {
    if frame.frame_type == H2_FRAME_DATA {
      saw_data = true
      assert_eq(frame.flags & H2_FLAG_END_STREAM, 0)
      assert_eq(@utf8.decode_lossy(frame.payload[:]), "hello")
    }
  }
  assert_true(saw_data)
}

///|
test "http2 empty request body can still carry trailers" {
  let response_headers = hpack_encode([(":status", "204")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(
      H2_FRAME_HEADERS,
      H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM,
      1,
      response_headers,
    ),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap()).with_trailer(
    "X-Done", "yes",
  )
  assert_eq(h2_request(stream, request).unwrap().status, 204)
  let frames = h2_test_client_frames(stream)
  let header_frames : Array[H2Frame] = []
  for frame in frames {
    if frame.frame_type == H2_FRAME_HEADERS && frame.stream_id == 1 {
      header_frames.push(frame)
    }
    assert_false(frame.frame_type == H2_FRAME_DATA)
  }
  assert_eq(header_frames.length(), 2)
  assert_eq(header_frames[0].flags & H2_FLAG_END_STREAM, 0)
  assert_eq(
    header_frames[1].flags & (H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM),
    H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM,
  )
}

///|
test "http2 request trailers reject forbidden fields and bad values" {
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap()).with_trailer(
    "Content-Length", "0",
  )
  assert_eq(
    h2_request_trailer_fields(request.trailers),
    Err(InvalidHeader("Content-Length")),
  )
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap()).with_trailer(
    "X-Test", " value",
  )
  assert_eq(
    h2_request_trailer_fields(request.trailers),
    Err(InvalidHeader("X-Test")),
  )
}
