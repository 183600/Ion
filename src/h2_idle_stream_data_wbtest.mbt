/// DATA on a stream that the client has not opened is a connection error
/// (RFC 9113 §5.1); the client must not pool such a session for another
/// request.
test "http2 does not pool a session with DATA on an idle stream" {
  let headers = hpack_encode([(":status", "204")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(
      H2_FRAME_HEADERS,
      H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM,
      1,
      headers,
    ),
    h2_test_frame(H2_FRAME_DATA, 0, 3, @utf8.encode("stale")),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  assert_eq(connection.request(request).unwrap().status, 204)
  assert_false(connection.is_open())
  assert_true(connection.request(request) is Err(ConnectionClosed))
}
