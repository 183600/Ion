/// A response that cannot carry a body still has to validate its framing
/// fields. When a completion callback is installed the response may be
/// released to the pool before the caller reads it, so decode must surface
/// those errors instead of returning a response with an already-poisoned
/// body stream.

test "bodyless framing errors surface during decode with a completion callback" {
  for raw in [
    "HTTP/1.1 304 Not Modified\r\nContent-Length: nope\r\n\r\n",
    "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n",
    "HTTP/1.1 304 Not Modified\r\nTransfer-Encoding: chunked;bad\r\n\r\n",
  ] {
    let stream = regression_mock_stream(raw, 0, 0)
    let mut released : Bool? = None
    let codec = H1Codec::new_with_completion(
      stream,
      fn(reusable) { released = Some(reusable) },
    )
    match codec.decode_response() {
      Ok(_) => fail("bodyless response with invalid framing was accepted")
      Err(err) => assert_true(err is NetworkError(ReadError(_)))
    }
    assert_eq(released, Some(false))
    assert_false(stream.is_open)
  }
}

test "zero-length framing errors surface during decode with a completion callback" {
  let stream = regression_mock_stream(
    "HTTP/1.1 205 Reset Content\r\nContent-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\n",
    0,
    0,
  )
  let codec = H1Codec::new_with_completion(stream, fn(_) { () })
  match codec.decode_response() {
    Ok(_) => fail("205 with transfer coding was accepted")
    Err(err) => assert_true(err is NetworkError(ReadError(_)))
  }
  assert_false(stream.is_open)
}

test "client reports bodyless framing errors before returning a response" {
  let stream = regression_mock_stream(
    "HTTP/1.1 304 Not Modified\r\nContent-Length: invalid\r\n\r\n",
    0,
    0,
  )
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let client = UnifiedClient::{
    connector,
    options: ClientOptions::new().with_follow_redirects(false),
    redirect_count: 0,
  }
  match client.get("http://example.com/") {
    Ok(_) => fail("client returned a bodyless response with invalid framing")
    Err(err) => assert_true(err is NetworkError(ReadError(_)))
  }
  assert_false(stream.is_open)
  assert_eq(dialer.count, 1)
  let _ = client.close_all()
}
