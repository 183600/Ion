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

test "H1 response stream readiness tracks its open state" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
  let codec = H1Codec::new(regression_mock_stream(raw, 0, 0))
  let response = codec.decode_response().unwrap()
  assert_true(response.body.read_ready())
  assert_true(response.body.wait_readable(0) is Ok(true))
  assert_eq(response.read_body().unwrap(), b"ok")
  assert_true(response.body.read_ready())
  assert_true(response.body.close() is Ok(_))
  assert_false(response.body.read_ready())
  assert_true(response.body.wait_readable(0) is Err(Closed))
}
