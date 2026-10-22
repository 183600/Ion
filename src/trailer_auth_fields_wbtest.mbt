/// Authentication metadata is needed to interpret the response and therefore
/// cannot move to the trailer section (RFC 9110 §6.5.1).

test "http1 rejects authentication fields in chunked trailers" {
  let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" +
    "0\r\nAuthentication-Info: nextnonce=\"x\"\r\n\r\n"
  let stream = regression_mock_stream(raw, 0, 0)
  let response = H1Codec::new(stream).decode_response().unwrap()
  match response.read_body() {
    Err(NetworkError(ReadError(message))) =>
      assert_eq(message, "invalid chunked trailer")
    Ok(_) => fail("an authentication field was accepted as a trailer")
    Err(err) => fail("unexpected error: " + @debug.to_string(err))
  }
  assert_false(stream.is_open)
}

/// The same restriction applies to HTTP/2 trailers.
test "http2 rejects proxy authentication fields in trailers" {
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(
      H2_FRAME_HEADERS,
      H2_FLAG_END_HEADERS,
      1,
      hpack_encode([(":status", "200")]),
    ),
    h2_test_frame(H2_FRAME_DATA, 0, 1, @utf8.encode("ok")),
    h2_test_frame(
      H2_FRAME_HEADERS,
      H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM,
      1,
      hpack_encode([("proxy-authentication-info", "nextnonce=x")]),
    ),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  match h2_request(
    stream,
    Request::new(GET, Url::parse("https://example.com/").unwrap()),
  ) {
    Ok(_) => fail("an authentication field was accepted as an HTTP/2 trailer")
    Err(ProtocolError(message)) =>
      assert_eq(message, "Invalid HTTP/2 trailer field")
    Err(err) => fail("unexpected error: " + @debug.to_string(err))
  }
}
