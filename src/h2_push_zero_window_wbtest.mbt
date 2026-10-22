/// A zero WINDOW_UPDATE increment is malformed regardless of its value. When
/// it targets a server-push stream that can never exist (push is disabled), it
/// must not be silently ignored just because its increment is zero.
test "http2 rejects a zero WINDOW_UPDATE on a server-push stream" {
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(
      H2_FRAME_HEADERS,
      H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM,
      1,
      hpack_encode([(":status", "204")]),
    ),
    h2_test_frame(
      H2_FRAME_HEADERS,
      H2_FLAG_END_HEADERS,
      3,
      hpack_encode([(":status", "200")]),
    ),
    h2_test_frame(
      H2_FRAME_WINDOW_UPDATE,
      0,
      2,
      h2_window_update_payload(0),
    ),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  assert_eq(connection.request(request).unwrap().status, 204)
  match connection.request(request) {
    Ok(_) => fail("a zero WINDOW_UPDATE on a server-push stream was accepted")
    Err(err) =>
      assert_eq(
        err,
        ProtocolError("HTTP/2 WINDOW_UPDATE on a server-push stream"),
      )
  }
  assert_false(connection.is_open())
}
