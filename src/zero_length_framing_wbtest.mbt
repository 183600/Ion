/// A response that may be completed before the caller reads it still has to
/// validate framing fields. With a completion callback, malformed framing must
/// surface from decode instead of leaving the connection unreleased.

test "zero-length response framing errors surface during decode with a completion callback" {
  for raw in [
    "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nTransfer-Encoding: chunked;bad\r\n\r\n",
    "HTTP/1.1 200 OK\r\nContent-Length: nope\r\n\r\n",
    "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n",
  ] {
    let stream = regression_mock_stream(raw, 0, 0)
    let mut released : Bool? = None
    let codec = H1Codec::new_with_completion(
      stream,
      fn(reusable) { released = Some(reusable) },
    )
    match codec.decode_response() {
      Ok(_) => fail("response with invalid framing was accepted")
      Err(err) => assert_true(err is NetworkError(ReadError(_)))
    }
    assert_eq(released, Some(false))
    assert_false(stream.is_open)
  }
}

test "zero-length response with valid framing is still completed early" {
  let stream = regression_mock_stream(
    "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n",
    0,
    0,
  )
  let mut released : Bool? = None
  let codec = H1Codec::new_with_completion(
    stream,
    fn(reusable) { released = Some(reusable) },
  )
  let response = codec.decode_response().unwrap()
  assert_eq(released, Some(true))
  assert_eq(response.read_body().unwrap(), b"")
  assert_true(stream.is_open)
}
