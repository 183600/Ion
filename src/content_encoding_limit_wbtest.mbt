fn nested_encoding_bytes(ints : Array[Int]) -> Bytes {
  let buf = @buffer.new(size_hint=ints.length())
  for i in ints {
    buf.write_byte(i.to_byte())
  }
  buf.to_bytes()
}

struct NestedEncodingMockStream {
  input : Bytes
  mut offset : Int
}

pub impl Stream for NestedEncodingMockStream with fn read(
  self : NestedEncodingMockStream,
  buf : Buffer,
) -> Result[Int, NetError] {
  if self.offset >= self.input.length() {
    return Ok(0)
  }
  buf.write_byte(self.input[self.offset])
  self.offset = self.offset + 1
  Ok(1)
}

pub impl Stream for NestedEncodingMockStream with fn write(
  self : NestedEncodingMockStream,
  buf : Buffer,
) -> Result[Int, NetError] {
  let _ = self
  let _ = buf
  Ok(0)
}

pub impl Stream for NestedEncodingMockStream with fn flush(
  self : NestedEncodingMockStream,
) -> Result[Unit, NetError] {
  let _ = self
  Ok(())
}

pub impl Stream for NestedEncodingMockStream with fn close(
  self : NestedEncodingMockStream,
) -> Result[Unit, NetError] {
  let _ = self
  Ok(())
}

pub impl Stream for NestedEncodingMockStream with fn set_timeout(
  self : NestedEncodingMockStream,
  timeout_ms : Int,
) -> Result[Unit, NetError] {
  let _ = self
  let _ = timeout_ms
  Ok(())
}

pub impl Stream for NestedEncodingMockStream with fn peer_addr(
  self : NestedEncodingMockStream,
) -> Result[String, NetError] {
  let _ = self
  Ok("mock:0")
}

pub impl Stream for NestedEncodingMockStream with fn local_addr(
  self : NestedEncodingMockStream,
) -> Result[String, NetError] {
  let _ = self
  Ok("mock:0")
}

test "nested Content-Encoding limits apply to the final decoded output" {
  // gzip(gzip("hello")): the outer member is 42 bytes, the inner member is
  // 25 bytes, and the final plaintext is 5 bytes. A 10-byte decoded-output
  // limit must accept this body even though the intermediate 25-byte member
  // exceeds the limit.
  let encoded = nested_encoding_bytes([
    31, 139, 8, 0, 0, 0, 0, 0, 2, 3, 147, 239, 230, 96, 0, 1, 38, 230, 211, 30,
    103, 79, 158, 100, 103, 104, 91, 38, 96, 198, 10, 20, 0, 0, 167, 111, 180,
    69, 25, 0, 0, 0,
  ])
  let stream : &Stream = NestedEncodingMockStream::{ input: encoded, offset: 0 }
  let headers = Headers::new().set("Content-Encoding", "gzip, gzip")
  let response = Response::new(200, headers, stream)
  assert_eq(response.read_body_decoded_with_limit(10).unwrap(), b"hello")

  let stream : &Stream = NestedEncodingMockStream::{ input: encoded, offset: 0 }
  let response = Response::new(200, headers, stream)
  assert_true(response.read_body_decoded_with_limit(4) is Err(_))
}
