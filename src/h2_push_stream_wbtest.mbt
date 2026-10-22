///|
test "http2 rejects frames on a server-push stream" {
  let first = hpack_encode([(":status", "204")])
  let third = hpack_encode([(":status", "200")])
  let cases : Array[(Bytes, String)] = [
    (
      h2_test_frame(H2_FRAME_DATA, 0, 2, b"pushed"),
      "HTTP/2 DATA on a server-push stream",
    ),
    (
      h2_test_frame(
        H2_FRAME_WINDOW_UPDATE,
        0,
        2,
        h2_window_update_payload(1),
      ),
      "HTTP/2 WINDOW_UPDATE on a server-push stream",
    ),
    (
      h2_test_frame(H2_FRAME_RST_STREAM, 0, 2, b"\x00\x00\x00\x00"),
      "HTTP/2 RST_STREAM on a server-push stream",
    ),
  ]
  for entry in cases {
    let (frame, expected) = entry
    let input = h2_test_concat([
      h2_test_settings(),
      h2_test_frame(
        H2_FRAME_HEADERS,
        H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM,
        1,
        first,
      ),
      h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 3, third),
      frame,
    ])
    let stream = h2_frame_mock_stream(input, 0)
    let connection = H2ClientConnection::new(stream).unwrap()
    let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
    assert_eq(connection.request(request).unwrap().status, 204)
    match connection.request(request) {
      Ok(_) => fail("frame on a server-push stream was accepted")
      Err(err) => assert_eq(err, ProtocolError(expected))
    }
    assert_false(connection.is_open())
  }
}

///|
test "http2 does not pool a session with buffered push-stream data" {
  let headers = hpack_encode([(":status", "204")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(
      H2_FRAME_HEADERS,
      H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM,
      1,
      headers,
    ),
    h2_test_frame(H2_FRAME_DATA, 0, 2, b"pushed"),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  assert_eq(connection.request(request).unwrap().status, 204)
  assert_false(connection.is_open())
}
