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
