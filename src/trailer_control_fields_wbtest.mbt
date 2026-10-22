///|
test "chunked trailers reject Pragma request-control fields" {
  let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nPragma: no-cache\r\n\r\n"
  let codec = H1Codec::new(regression_mock_stream(raw, 0, 0))
  let response = codec.decode_response().unwrap()
  assert_true(response.read_body() is Err(NetworkError(ReadError(_))))
  assert_eq(response.trailers().length(), 0)
}

///|
test "HTTP/2 trailers reject Pragma request-control fields" {
  let response_headers = hpack_encode([(":status", "200")])
  let trailers = hpack_encode([("pragma", "no-cache")])
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
    Ok(_) => fail("HTTP/2 Pragma trailer was accepted")
    Err(err) => assert_eq(err, ProtocolError("Invalid HTTP/2 trailer field"))
  }
}
