test "http2 discards reset-stream frames across a connection frame" {
  let first_headers = hpack_encode([(":status", "200")])
  let first_trailers = hpack_encode([("x-trailer", "done")])
  let second_headers = hpack_encode([
    (":status", "200"),
    ("x-request", "second"),
  ])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(
      H2_FRAME_HEADERS,
      H2_FLAG_END_HEADERS,
      1,
      first_headers,
    ),
    // A zero increment resets only stream 1.
    h2_test_frame(H2_FRAME_WINDOW_UPDATE, 0, 1, b"\x00\x00\x00\x00"),
    h2_test_frame(H2_FRAME_PING, 0, 0, b"12345678"),
    h2_test_frame(
      H2_FRAME_HEADERS,
      H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM,
      1,
      first_trailers,
    ),
    h2_test_frame(
      H2_FRAME_HEADERS,
      H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM,
      3,
      second_headers,
    ),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let url = Url::parse("https://example.com/").unwrap()
  let first = connection.request_streaming(Request::new(GET, url)).unwrap()
  match first.read_body() {
    Err(NetworkError(ReadError(_))) => ()
    Err(err) => fail("unexpected error: " + @debug.to_string(err))
    Ok(body) => fail("expected reset, got body: " + @debug.to_string(body))
  }
  let second = connection.request(Request::new(GET, url)).unwrap()
  assert_eq(second.status, 200)
  assert_eq(second.headers.get("x-request"), Some("second"))
  assert_true(connection.is_open())
}

///|
test "http2 ignores late DATA after resetting an answered stream" {
  let first_headers = hpack_encode([
    (":status", "200"),
    ("content-length", "0"),
  ])
  let second_headers = hpack_encode([(":status", "204")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, first_headers),
    h2_test_frame(H2_FRAME_RST_STREAM, 0, 1, b"\x00\x00\x00\x08"),
    h2_test_frame(H2_FRAME_DATA, 0, 1, b"x"),
    h2_test_frame(
      H2_FRAME_HEADERS,
      H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM,
      3,
      second_headers,
    ),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let url = Url::parse("https://example.com/").unwrap()
  let first = connection.request_streaming(Request::new(GET, url)).unwrap()
  assert_true(first.body_stream().read(Buffer(size_hint=16)) is Err(_))
  assert_true(connection.is_open())
  let second = connection.request(Request::new(GET, url)).unwrap()
  assert_eq(second.status, 204)
  assert_true(connection.is_open())
}
