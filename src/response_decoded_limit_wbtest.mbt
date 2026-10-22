///|
test "decoded body reads the encoded input up to an explicit larger limit" {
  let compressed = inflate_bytes_of([
    31, 139, 8, 0, 142, 223, 215, 106, 2, 255, 203, 72, 205, 201, 201, 7, 0,
    134, 166, 16, 54, 5, 0, 0, 0,
  ])
  let stream : &Stream = InflateMockStream::{ input: compressed, offset: 0 }
  let headers = Headers::new().set("Content-Encoding", "gzip")
  let response = Response::new(200, headers, stream).with_max_body_bytes(10)
  assert_eq(response.read_body_decoded_with_limit(100).unwrap(), b"hello")
}

///|
test "http1 explicit larger limits raise the response stream cap" {
  let compressed = inflate_bytes_of([
    31, 139, 8, 0, 142, 223, 215, 106, 2, 255, 203, 72, 205, 201, 201, 7, 0,
    134, 166, 16, 54, 5, 0, 0, 0,
  ])
  let head = "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: " +
    compressed.length().to_string() + "\r\n\r\n"
  let raw = @buffer.new(size_hint=head.length() + compressed.length())
  raw.write_bytes(@utf8.encode(head))
  raw.write_bytes(compressed)
  let stream : &Stream = InflateMockStream::{ input: raw.to_bytes(), offset: 0 }
  let response = H1Codec::new_with_limit(stream, 10).decode_response().unwrap()
  assert_eq(response.read_body_decoded_with_limit(100).unwrap(), b"hello")

  let plain: &Stream = InflateMockStream::{
    input: @utf8.encode("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"),
    offset: 0,
  }
  let response = H1Codec::new_with_limit(plain, 4).decode_response().unwrap()
  assert_eq(response.read_body_with_limit(5).unwrap(), b"hello")
}
