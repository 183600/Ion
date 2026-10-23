test "opaque transfer coding leaves content encoding untouched" {
  let raw = "HTTP/1.1 200 OK\r\n" +
    "Transfer-Encoding: chunked, gzip\r\n" +
    "Content-Encoding: gzip\r\n\r\n" +
    "payload"
  let stream = regression_mock_stream(raw, 0, 0)
  let response = H1Codec::new(stream).decode_response().unwrap()
  assert_eq(response.read_body_decoded().unwrap(), b"payload")
}
