/// A CONNECT tunnel has no response-body cap, so its stream receive window is
/// the memory bound for data the peer sends while the application is not
/// reading. Verify the advertised window is bounded and that tunnel DATA is
/// acknowledged only as the caller consumes it.
test "http2 advertises a bounded stream receive window" {
  let stream = h2_frame_mock_stream(b"", 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  assert_true(connection.is_open())
  let mut advertised : Int? = None
  for frame in h2_test_client_frames(stream) {
    if frame.frame_type == H2_FRAME_SETTINGS && (frame.flags & H2_FLAG_ACK) == 0 {
      let mut offset = 0
      while offset + 6 <= frame.payload.length() {
        let identifier = (frame.payload[offset].to_int() << 8) |
          frame.payload[offset + 1].to_int()
        let value = (frame.payload[offset + 2].to_int() << 24) |
          (frame.payload[offset + 3].to_int() << 16) |
          (frame.payload[offset + 4].to_int() << 8) |
          frame.payload[offset + 5].to_int()
        if identifier == H2_SETTINGS_INITIAL_WINDOW_SIZE {
          advertised = Some(value)
        }
        offset = offset + 6
      }
    }
  }
  assert_eq(advertised, Some(H2_STREAM_RECEIVE_WINDOW))
  connection.close()
}

/// The peer starts with a zero send window so the write path must read tunnel
/// DATA while waiting for a WINDOW_UPDATE. That buffered DATA must not have its
/// stream credit returned until the response body is actually read.
test "http2 CONNECT defers tunnel data credit until the body is read" {
  let settings = h2_test_frame(
    H2_FRAME_SETTINGS,
    0,
    0,
    h2_settings_payload([(H2_SETTINGS_INITIAL_WINDOW_SIZE, 0)]),
  )
  let headers = hpack_encode([(":status", "200")])
  let input = h2_test_concat([
    settings,
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, headers),
    h2_test_frame(H2_FRAME_DATA, 0, 1, @utf8.encode("received")),
    h2_test_frame(H2_FRAME_WINDOW_UPDATE, 0, 1, h2_window_update_payload(5)),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let response = h2_request(
    stream,
    Request::new(CONNECT, Url::parse("http://example.com:80/").unwrap()),
  ).unwrap()
  let payload = Buffer(size_hint=4)
  payload.write_bytes(b"ping")
  assert_eq(response.body.write(payload).unwrap(), 4)

  let mut credited_before_read = 0
  for frame in h2_test_client_frames(stream) {
    if frame.frame_type == H2_FRAME_WINDOW_UPDATE && frame.stream_id == 1 {
      credited_before_read = credited_before_read +
        ((frame.payload[0].to_int() & 0x7f) << 24) +
        (frame.payload[1].to_int() << 16) +
        (frame.payload[2].to_int() << 8) +
        frame.payload[3].to_int()
    }
  }
  assert_eq(credited_before_read, 0)

  let body = Buffer(size_hint=16)
  assert_eq(response.body.read(body).unwrap(), 8)
  assert_eq(body.to_bytes(), b"received")

  let mut credited_after_read = 0
  for frame in h2_test_client_frames(stream) {
    if frame.frame_type == H2_FRAME_WINDOW_UPDATE && frame.stream_id == 1 {
      credited_after_read = credited_after_read +
        ((frame.payload[0].to_int() & 0x7f) << 24) +
        (frame.payload[1].to_int() << 16) +
        (frame.payload[2].to_int() << 8) +
        frame.payload[3].to_int()
    }
  }
  assert_eq(credited_after_read, 8)
  response.body.close().unwrap()
}
