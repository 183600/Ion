/// When a zero WINDOW_UPDATE skips an unopened stream, any flow-control credit
/// that was already buffered for that stream must be discarded with it. Keeping
/// it would grant the same credit to the next (different) stream and could make
/// the client exceed the peer's advertised window.
test "http2 clears pending window credit when a stream is skipped" {
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(
      H2_FRAME_WINDOW_UPDATE,
      0,
      1,
      h2_window_update_payload(1000),
    ),
    h2_test_frame(
      H2_FRAME_WINDOW_UPDATE,
      0,
      1,
      h2_window_update_payload(0),
    ),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let flow = H2FlowState::new()
  // Reading the preface also pulls the following frames into the shared
  // reader, which is what makes the buffered settings drain see them.
  connection.read_initial_settings(flow).unwrap()
  match connection.drain_buffered_settings(flow) {
    Err(ProtocolError(message)) =>
      assert_eq(
        message,
        "HTTP/2 stream WINDOW_UPDATE increment is zero",
      )
    Ok(_) => fail("a zero stream WINDOW_UPDATE increment was accepted")
    Err(err) => fail("unexpected error: " + @debug.to_string(err))
  }
  // Stream 1 was skipped without ever being opened; the next request uses 3.
  assert_eq(connection.next_stream_id, 3)
  assert_eq(flow.pending_stream_window, 0)
  let _ = connection.close()
}
