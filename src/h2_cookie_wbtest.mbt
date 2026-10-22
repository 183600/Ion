///|
test "http2 combines split cookie fields into one header" {
  let response_headers = hpack_encode([(":status", "204")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(
      H2_FRAME_HEADERS,
      H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM,
      1,
      response_headers,
    ),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
    .with_header("Cookie", "a=1")
    .with_header("Cookie", "b=2")
  let response = h2_request(stream, request).unwrap()
  assert_eq(response.status, 204)
  let frames = h2_test_client_frames(stream)
  let mut header_frame : H2Frame? = None
  for frame in frames {
    if frame.frame_type == H2_FRAME_HEADERS && header_frame is None {
      header_frame = Some(frame)
    }
  }
  let fields = HpackDecoder::new().decode(header_frame.unwrap().payload).unwrap()
  assert_eq(h2_test_header_value(fields, "cookie"), Some("a=1; b=2"))
  let mut cookie_fields = 0
  for field in fields {
    if field.0 == "cookie" {
      cookie_fields = cookie_fields + 1
    }
  }
  assert_eq(cookie_fields, 1)
}

///|
test "http2 keeps a single cookie field unchanged" {
  let response_headers = hpack_encode([(":status", "204")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(
      H2_FRAME_HEADERS,
      H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM,
      1,
      response_headers,
    ),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
    .with_header("Cookie", "session=abc")
  let _ = h2_request(stream, request).unwrap()
  let frames = h2_test_client_frames(stream)
  let mut header_frame : H2Frame? = None
  for frame in frames {
    if frame.frame_type == H2_FRAME_HEADERS && header_frame is None {
      header_frame = Some(frame)
    }
  }
  let fields = HpackDecoder::new().decode(header_frame.unwrap().payload).unwrap()
  assert_eq(h2_test_header_value(fields, "cookie"), Some("session=abc"))
}
