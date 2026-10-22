/// A server-push stream id is even, and push is disabled, so no such stream can
/// ever exist. A buffered WINDOW_UPDATE for one is malformed even when its
/// increment is zero or when the id is older than the next client stream.
test "http2 rejects buffered WINDOW_UPDATE on a server-push stream" {
  for increment in [0, 1] {
    let input = h2_test_concat([
      h2_test_settings(),
      h2_test_frame(
        H2_FRAME_WINDOW_UPDATE,
        0,
        2,
        h2_window_update_payload(increment),
      ),
    ])
    let stream = h2_frame_mock_stream(input, 0)
    let connection = H2ClientConnection::new(stream).unwrap()
    // Pretend one client stream has already been opened, so the even id is
    // older than the next client stream instead of looking like an idle stream.
    connection.next_stream_id = 3
    let flow = H2FlowState::new()
    connection.read_initial_settings(flow).unwrap()
    match connection.drain_buffered_settings(flow) {
      Ok(_) => fail("a WINDOW_UPDATE for a server-push stream was accepted")
      Err(ProtocolError(message)) =>
        assert_eq(message, "HTTP/2 WINDOW_UPDATE on a server-push stream")
      Err(err) => fail("unexpected error: " + @debug.to_string(err))
    }
    assert_false(connection.is_open())
  }
}
