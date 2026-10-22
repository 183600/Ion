test "explicit body limits can raise an HTTP/2 Content-Length cap" {
  let headers = hpack_encode([
    (":status", "200"),
    ("content-length", "6"),
  ])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, headers),
    h2_test_frame(H2_FRAME_DATA, H2_FLAG_END_STREAM, 1, b"abcdef"),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let request = Request::new(
    GET,
    Url::parse("https://example.com/content-length-limit").unwrap(),
  )
  let response = connection.request_streaming_with_limit(request, 4).unwrap()
  assert_eq(response.read_body_with_limit(8).unwrap(), b"abcdef")
  assert_true(connection.is_open())
  let _ = connection.close()
}

test "HTTP/2 Content-Length responses still enforce the configured cap" {
  let headers = hpack_encode([
    (":status", "200"),
    ("content-length", "6"),
  ])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, headers),
    h2_test_frame(H2_FRAME_DATA, H2_FLAG_END_STREAM, 1, b"abcdef"),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let request = Request::new(
    GET,
    Url::parse("https://example.com/content-length-capped").unwrap(),
  )
  let response = connection.request_streaming_with_limit(request, 4).unwrap()
  assert_true(response.read_body() is Err(_))
  assert_false(connection.is_open())

  let buffered = h2_frame_mock_stream(input, 0)
  let buffered_request = Request::new(
    GET,
    Url::parse("https://example.com/content-length-capped").unwrap(),
  )
  match h2_request_with_limit(buffered, buffered_request, 4) {
    Ok(_) => fail("HTTP/2 Content-Length body exceeded the configured cap")
    Err(err) => assert_eq(err, ProtocolError("HTTP/2 response body too large"))
  }
}
