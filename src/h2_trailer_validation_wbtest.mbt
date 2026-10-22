/// HTTP/2 trailers are subject to the same forbidden-field rules as HTTP/1.1:
/// framing, routing, authentication, and payload metadata cannot move to the
/// trailer section.

test "http2 rejects metadata and authentication fields in response trailers" {
  for name in [
    "content-encoding",
    "content-range",
    "authorization",
    "proxy-authorization",
    "www-authenticate",
    "set-cookie",
    "cookie",
    "if-match",
  ] {
    let response_headers = hpack_encode([(":status", "200")])
    let trailers = hpack_encode([(name, "value")])
    let input = h2_test_concat([
      h2_test_settings(),
      h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, response_headers),
      h2_test_frame(H2_FRAME_DATA, 0, 1, b"hello"),
      h2_test_frame(
        H2_FRAME_HEADERS,
        H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM,
        1,
        trailers,
      ),
    ])
    let stream = h2_frame_mock_stream(input, 0)
    let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
    match h2_request(stream, request) {
      Ok(_) => fail("HTTP/2 trailer field was accepted: " + name)
      Err(err) =>
        assert_eq(err, ProtocolError("Invalid HTTP/2 trailer field"))
    }
  }
}
