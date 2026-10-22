test "H1Codec keeps a split pipelined response readable" {
  let stream = codec_reuse_stream([
    "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhelloHTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nb",
    "ye",
  ])
  let codec = H1Codec::new(stream)
  let first = codec.decode_response().unwrap()
  assert_eq(first.read_body().unwrap(), b"hello")
  assert_true(stream.is_open)
  let second = codec.decode_response().unwrap()
  assert_eq(second.read_body().unwrap(), b"bye")
}

test "H1Codec keeps a split pipelined bodyless response readable" {
  let stream = codec_reuse_stream([
    "HTTP/1.1 204 No Content\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nb",
    "ye",
  ])
  let codec = H1Codec::new(stream)
  let first = codec.decode_response().unwrap()
  assert_eq(first.read_body().unwrap(), b"")
  assert_true(stream.is_open)
  let second = codec.decode_response().unwrap()
  assert_eq(second.read_body().unwrap(), b"bye")
}
