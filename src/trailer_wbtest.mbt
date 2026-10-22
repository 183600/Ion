///|
test "chunked trailers reject forbidden message fields" {
  for trailer in [
    "Content-Length: 5",
    "Transfer-Encoding: chunked",
    "Host: example.com",
    "Connection: close",
    "Trailer: X-Test",
    "TE: trailers",
    "Content-Encoding: gzip",
    "Content-Type: text/plain",
    "Content-Range: bytes 0-0/1",
    "Authorization: secret",
    "Proxy-Authorization: secret",
    "Cookie: session=1",
    "Set-Cookie: session=1",
    "Cache-Control: no-store",
    "Range: bytes=0-0",
  ] {
    let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n" +
      trailer + "\r\n\r\n"
    let codec = H1Codec::new(regression_mock_stream(raw, 0, 0))
    let response = codec.decode_response().unwrap()
    assert_true(response.read_body() is Err(NetworkError(ReadError(_))))
    assert_eq(response.trailers().length(), 0)
  }
}

///|
test "chunked trailers still expose ordinary fields" {
  let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nETag: \"v1\"\r\nDigest: sha-256=x\r\n\r\n"
  let codec = H1Codec::new(regression_mock_stream(raw, 0, 0))
  let response = codec.decode_response().unwrap()
  assert_eq(response.read_body().unwrap(), b"")
  assert_eq(response.trailers().get("etag"), Some("\"v1\""))
  assert_eq(response.trailers().get("digest"), Some("sha-256=x"))
}
