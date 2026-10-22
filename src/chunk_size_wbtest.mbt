///|
test "chunk sizes reject leading whitespace even with extensions" {
  for value in [" 5;foo=bar", "\t5;foo=bar", " 5 ;foo=\"bar\""] {
    let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" +
      value + "\r\nhello\r\n0\r\n\r\n"
    let codec = H1Codec::new(regression_mock_stream(raw, 0, 0))
    let response = codec.decode_response().unwrap()
    assert_true(response.body.read(@buffer.new(size_hint=8)) is Err(_))
  }
}

///|
test "chunk sizes still allow BWS before an extension" {
  for value in ["5;foo=bar", "5 ;foo=bar", "5\t; foo"] {
    let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" +
      value + "\r\nhello\r\n0\r\n\r\n"
    let codec = H1Codec::new(regression_mock_stream(raw, 0, 0))
    let response = codec.decode_response().unwrap()
    assert_eq(response.text().unwrap(), "hello")
  }
}
