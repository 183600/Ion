///|
test "http2 replenishes the active stream receive window" {
  let response_headers = hpack_encode([(":status", "200")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, response_headers),
    h2_test_frame(H2_FRAME_DATA, 0, 1, b"hello"),
    h2_test_frame(H2_FRAME_DATA, H2_FLAG_END_STREAM, 1, b""),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  let response = h2_request(stream, request).unwrap()
  assert_eq(response.read_body().unwrap(), b"hello")
  let mut stream_update = false
  let mut connection_update = false
  for frame in h2_test_client_frames(stream) {
    if frame.frame_type == H2_FRAME_WINDOW_UPDATE && frame.payload.length() == 4 {
      let increment = ((frame.payload[0].to_int() & 0x7f) << 24) |
        (frame.payload[1].to_int() << 16) |
        (frame.payload[2].to_int() << 8) |
        frame.payload[3].to_int()
      if frame.stream_id == 1 && increment == 5 {
        stream_update = true
      }
      if frame.stream_id == 0 && increment == 5 {
        connection_update = true
      }
    }
  }
  assert_true(stream_update)
  assert_true(connection_update)
}
