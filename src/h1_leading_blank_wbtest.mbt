/// RFC 9112 §2.2 permits a client to ignore empty lines received before the
/// response-line.
test "http1 ignores leading empty lines before the status line" {
  let raw = "\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
  let codec = H1Codec::new(regression_mock_stream(raw, 0, 0))
  let response = codec.decode_response().unwrap()
  assert_eq(response.status, 200)
  assert_eq(response.read_body().unwrap(), b"ok")
}

test "http1 still rejects a malformed first response line" {
  let raw = "BAD\r\nHTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
  let codec = H1Codec::new(regression_mock_stream(raw, 0, 0))
  match codec.decode_response() {
    Ok(_) => fail("malformed response line was accepted")
    Err(err) => assert_eq(err, ProtocolError("Invalid response line"))
  }
}
