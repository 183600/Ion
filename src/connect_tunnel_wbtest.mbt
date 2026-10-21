/// Regression tests for proxy CONNECT tunnel handling.

test "CONNECT authority brackets IPvFuture hosts" {
  let url = Url::parse("https://[v1.foo]:8443/").unwrap()
  assert_eq(connect_authority(url), "[v1.foo]:8443")
}

test "connect response keeps bytes read past the head" {
  let head = "HTTP/1.1 200 Connection Established\r\n\r\n"
  let tunnel = "\x16\x03\x01\x00\x05hello"
  let stream = regression_mock_stream(head + tunnel, 0, 0)
  let leftover = read_connect_response(stream).unwrap()
  assert_eq(@utf8.decode_lossy(leftover[:]), tunnel)
}

test "prefix stream replays leftover bytes before the underlying stream" {
  let underlying = regression_mock_stream("REST", 0, 0)
  let stream = PrefixStream::new(@utf8.encode("TUNNELDATA"), underlying)
  let first = @buffer.new(size_hint=32)
  assert_eq(stream.read(first).unwrap(), 10)
  assert_eq(@utf8.decode_lossy(first.to_bytes()[:]), "TUNNELDATA")
  let second = @buffer.new(size_hint=32)
  assert_eq(stream.read(second).unwrap(), 4)
  assert_eq(@utf8.decode_lossy(second.to_bytes()[:]), "REST")
}

test "prefix stream with empty prefix delegates directly" {
  let underlying = regression_mock_stream("BODY", 0, 0)
  let stream = PrefixStream::new(b"", underlying)
  let buf = @buffer.new(size_hint=32)
  assert_eq(stream.read(buf).unwrap(), 4)
  assert_eq(@utf8.decode_lossy(buf.to_bytes()[:]), "BODY")
}
