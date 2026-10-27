///|
test "chunked body read returns at a chunk boundary without waiting" {
  let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n"
  let stream = partial_frame_stream(@utf8.encode(raw))
  let codec = H1Codec::new(stream)
  let response = codec.decode_response().unwrap()
  let buf = @buffer.new(size_hint=8)
  assert_eq(response.body.read(buf).unwrap(), 5)
  assert_eq(buf.to_bytes(), @utf8.encode("hello"))
}

///|
test "chunked body read returns after a buffered next chunk size" {
  let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n5\r\n"
  let stream = partial_frame_stream(@utf8.encode(raw))
  let codec = H1Codec::new(stream)
  let response = codec.decode_response().unwrap()
  let buf = @buffer.new(size_hint=8)
  assert_eq(response.body.read(buf).unwrap(), 5)
  assert_eq(buf.to_bytes(), @utf8.encode("hello"))
}
