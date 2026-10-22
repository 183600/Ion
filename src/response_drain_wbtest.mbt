test "Response::drain_body consumes chunked bodies and trailers" {
  let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" +
    "5\r\nhello\r\n0\r\nX-Done: yes\r\n\r\n"
  let codec = H1Codec::new(regression_mock_stream(raw, 0, 0))
  let response = codec.decode_response().unwrap()
  response.drain_body().unwrap()
  assert_eq(response.trailers().get("X-Done"), Some("yes"))
  let rest = Buffer(size_hint=1)
  assert_eq(response.body.read(rest).unwrap(), 0)
}

test "Response::drain_body enforces the body limit and closes the stream" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"
  let stream = regression_mock_stream(raw, 0, 0)
  let codec = H1Codec::new_with_limit(stream, 2)
  let response = codec.decode_response().unwrap()
  assert_true(response.drain_body() is Err(_))
  assert_false(stream.is_open)
}

test "Response::close discards unread body bytes" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"
  let stream = regression_mock_stream(raw, 0, 0)
  let codec = H1Codec::new(stream)
  let response = codec.decode_response().unwrap()
  response.close()
  let rest = Buffer(size_hint=1)
  assert_true(response.body.read(rest) is Err(NetError::Closed))
  assert_false(stream.is_open)
}
