test "http2 applies buffered connection frames after a next-stream window update" {
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(
      H2_FRAME_WINDOW_UPDATE,
      0,
      1,
      h2_window_update_payload(1),
    ),
    h2_test_frame(
      H2_FRAME_GOAWAY,
      0,
      0,
      h2_test_concat([
        b"\x00\x00\x00\x00",
        b"\x00\x00\x00\x00",
        @utf8.encode("closing"),
      ]),
    ),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  match connection.request(request) {
    Ok(_) => fail("buffered GOAWAY after WINDOW_UPDATE was ignored")
    Err(ProtocolError(message)) => assert_true(message.contains("GOAWAY"))
    Err(err) => fail("unexpected error: " + @debug.to_string(err))
  }
  for frame in h2_test_client_frames(stream) {
    assert_true(frame.frame_type != H2_FRAME_HEADERS)
  }
}
