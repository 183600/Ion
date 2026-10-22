/// A `Response` built by the caller may wrap a body stream with a smaller
/// limit than the new response's cap. `copy_body_to` must authorize the
/// response cap before reading, exactly like `read_body_with_limit`.
test "copy_body_to raises a wrapped HTTP/1 body stream limit" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 20\r\n\r\n" +
    "01234567890123456789"
  let source = regression_mock_stream(raw, 0, 0)
  let original = H1Codec::new_with_limit(source, 10).decode_response().unwrap()
  let wrapped = Response::new(original.status, original.headers, original.body_stream())
  let sink = regression_mock_stream("", 0, 0)
  assert_eq(wrapped.copy_body_to(sink).unwrap(), 20)
  assert_eq(
    @utf8.decode_lossy(sink.output.to_bytes()[:]),
    "01234567890123456789",
  )
}
