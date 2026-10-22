///|
test "http2 ignores a late RST_STREAM after the response ended" {
  let response_headers = hpack_encode([
    (":status", "200"),
    ("content-length", "0"),
  ])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(
      H2_FRAME_HEADERS,
      H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM,
      1,
      response_headers,
    ),
    h2_test_frame(H2_FRAME_RST_STREAM, 0, 1, b"\x00\x00\x00\x08"),
    h2_test_frame(
      H2_FRAME_HEADERS,
      H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM,
      3,
      response_headers,
    ),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  assert_eq(connection.request(request).unwrap().status, 200)
  assert_true(connection.is_open())
  assert_eq(connection.request(request).unwrap().status, 200)
  assert_true(connection.is_open())
}

///|
test "http2 still rejects RST_STREAM on an idle stream after a response" {
  let response_headers = hpack_encode([(":status", "204")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(
      H2_FRAME_HEADERS,
      H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM,
      1,
      response_headers,
    ),
    h2_test_frame(H2_FRAME_RST_STREAM, 0, 3, b"\x00\x00\x00\x00"),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  assert_eq(connection.request(request).unwrap().status, 204)
  assert_false(connection.is_open())
}
