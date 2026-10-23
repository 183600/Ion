test "http2 keeps the session after a reset of an answered stream" {
  let first_headers = hpack_encode([(":status", "200")])
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
    h2_test_frame(H2_FRAME_RST_STREAM, 0, 1, b"\x00\x00\x00\x08"),
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
  let body = Buffer(size_hint=16)
  assert_true(first.body_stream().read(body) is Err(_))
  assert_true(connection.is_open())
  let second = connection.request(Request::new(GET, url)).unwrap()
  assert_eq(second.status, 200)
  assert_eq(second.headers.get("x-request"), Some("second"))
  assert_true(connection.is_open())
}
