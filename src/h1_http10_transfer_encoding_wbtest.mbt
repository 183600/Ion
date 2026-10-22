/// HTTP/1.0 did not define Transfer-Encoding. RFC 9112 §6.1 requires a client
/// that receives an HTTP/1.0 message with Transfer-Encoding to treat the
/// framing as faulty and close the connection after processing it, even when
/// `Connection: keep-alive` is present.

test "http1 does not pool an HTTP/1.0 response carrying Transfer-Encoding" {
  let raw = "HTTP/1.0 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: keep-alive\r\n\r\n" +
    "5\r\nhello\r\n0\r\n\r\n"
  let stream = regression_mock_stream(raw, 0, 0)
  let completions : Array[Bool] = []
  let codec = H1Codec::new_with_completion(
    stream,
    fn(reusable) { completions.push(reusable) },
  )
  let response = codec.decode_response().unwrap()
  assert_eq(response.read_body().unwrap(), b"hello")
  assert_eq(completions, [false])
  assert_false(stream.is_open)
}

/// The oversized/ambiguous peer should not be allowed to desynchronize a later
/// exchange even when the chunked body happens to be empty.
test "http1 closes an empty HTTP/1.0 chunked response instead of pooling it" {
  let raw = "HTTP/1.0 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: keep-alive\r\n\r\n" +
    "0\r\n\r\n"
  let stream = regression_mock_stream(raw, 0, 0)
  let completions : Array[Bool] = []
  let codec = H1Codec::new_with_completion(
    stream,
    fn(reusable) { completions.push(reusable) },
  )
  let response = codec.decode_response().unwrap()
  assert_eq(response.read_body().unwrap(), b"")
  assert_eq(completions, [false])
  assert_false(stream.is_open)
}
