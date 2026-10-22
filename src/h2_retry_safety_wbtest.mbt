///|
test "HTTP/2 GOAWAY excludes the current stream even with an error code" {
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_GOAWAY, 0, 0, b"\x00\x00\x00\x00\x00\x00\x00\x01"),
  ])
  // Force the GOAWAY to be read after the request stream is opened.
  let stream = h2_frame_mock_stream(input, 1)
  let request = Request::new(POST, Url::parse("https://example.com/upload").unwrap())
    .with_body(b"payload")
  match h2_request(stream, request) {
    Ok(_) => fail("GOAWAY was ignored")
    Err(err) => assert_eq(
      err,
      ProtocolError("HTTP/2 connection closed by GOAWAY"),
    )
  }
}

///|
test "HTTP/2 does not classify a post-header reset as a safe refusal" {
  let response_headers = hpack_encode([(":status", "200")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, response_headers),
    h2_test_frame(H2_FRAME_RST_STREAM, 0, 1, b"\x00\x00\x00\x07"),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let request = Request::new(POST, Url::parse("https://example.com/").unwrap())
  match h2_request(stream, request) {
    Ok(_) => fail("post-header REFUSED_STREAM was ignored")
    Err(err) => assert_eq(err, ProtocolError("HTTP/2 stream reset by server"))
  }
}

///|
test "HTTP/2 does not classify GOAWAY after response headers as unprocessed" {
  let response_headers = hpack_encode([(":status", "200")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, response_headers),
    h2_test_frame(H2_FRAME_GOAWAY, 0, 0, b"\x00\x00\x00\x00\x00\x00\x00\x00"),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let request = Request::new(POST, Url::parse("https://example.com/").unwrap())
  match h2_request(stream, request) {
    Ok(_) => fail("contradictory GOAWAY was ignored")
    Err(err) => assert_eq(
      err,
      ProtocolError(
        "HTTP/2 connection closed by GOAWAY after response headers",
      ),
    )
  }
}
