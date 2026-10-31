/// A minimal in-memory stream used to exercise response body decoding without
/// opening a socket. Reads return one byte at a time so buffered and streaming
/// paths both see partial payloads.
struct AutoDecompressMockStream {
  input : Bytes
  mut offset : Int
  output : Buffer
}

pub impl Stream for AutoDecompressMockStream with fn read(
  self : AutoDecompressMockStream,
  buf : Buffer,
) -> Result[Int, NetError] {
  if self.offset >= self.input.length() {
    return Ok(0)
  }
  buf.write_byte(self.input[self.offset])
  self.offset = self.offset + 1
  Ok(1)
}

pub impl Stream for AutoDecompressMockStream with fn write(
  self : AutoDecompressMockStream,
  buf : Buffer,
) -> Result[Int, NetError] {
  let bytes = buf.to_bytes()
  self.output.write_bytes(bytes)
  Ok(bytes.length())
}

pub impl Stream for AutoDecompressMockStream with fn flush(
  self : AutoDecompressMockStream,
) -> Result[Unit, NetError] {
  let _ = self
  Ok(())
}

pub impl Stream for AutoDecompressMockStream with fn close(
  self : AutoDecompressMockStream,
) -> Result[Unit, NetError] {
  let _ = self
  Ok(())
}

pub impl Stream for AutoDecompressMockStream with fn set_timeout(
  self : AutoDecompressMockStream,
  timeout_ms : Int,
) -> Result[Unit, NetError] {
  let _ = self
  let _ = timeout_ms
  Ok(())
}

pub impl Stream for AutoDecompressMockStream with fn peer_addr(
  self : AutoDecompressMockStream,
) -> Result[String, NetError] {
  let _ = self
  Ok("mock:0")
}

pub impl Stream for AutoDecompressMockStream with fn local_addr(
  self : AutoDecompressMockStream,
) -> Result[String, NetError] {
  let _ = self
  Ok("mock:0")
}

fn auto_decompress_bytes(ints : Array[Int]) -> Bytes {
  let buf = @buffer.new(size_hint=ints.length())
  for i in ints {
    buf.write_byte(i.to_byte())
  }
  buf.to_bytes()
}

/// Standard gzip member containing "hello".
fn auto_decompress_gzip_hello() -> Bytes {
  auto_decompress_bytes([
    31, 139, 8, 0, 57, 223, 215, 106, 2, 255, 203, 72, 205, 201, 201, 7, 0,
    134, 166, 16, 54, 5, 0, 0, 0,
  ])
}

fn auto_decompress_response(input : Bytes) -> Response {
  let stream : &Stream = AutoDecompressMockStream::{
    input,
    offset: 0,
    output: Buffer(size_hint=0),
  }
  Response::new(200, Headers::new().set("Content-Encoding", "gzip"), stream)
}

test "automatic body decoding is opt-in" {
  let options = ClientOptions::new()
  assert_false(options.auto_decompress())
  assert_true(options.with_auto_decompress(true).auto_decompress())
  assert_false(options.with_auto_decompress(true).with_auto_decompress(false).auto_decompress())

  let client = UnifiedClient::new()
  assert_false(client.client_options().auto_decompress())
  assert_true(client.with_auto_decompress(true).client_options().auto_decompress())
}

test "read_body returns encoded bytes unless automatic decoding is enabled" {
  let encoded = auto_decompress_gzip_hello()

  let raw = auto_decompress_response(encoded)
  assert_eq(raw.read_body().unwrap(), encoded)

  let decoded = auto_decompress_response(encoded).with_auto_decompress(true)
  assert_true(decoded.auto_decompress())
  assert_eq(decoded.read_body().unwrap(), b"hello")
}

test "read_body_with_limit stays raw when automatic decoding is enabled" {
  let encoded = auto_decompress_gzip_hello()
  let response = auto_decompress_response(encoded).with_auto_decompress(true)
  assert_eq(response.read_body_with_limit(1024).unwrap(), encoded)
}

test "automatic decoding enforces the decoded body limit" {
  let encoded = auto_decompress_gzip_hello()
  let response = auto_decompress_response(encoded)
    .with_auto_decompress(true)
    .with_max_body_bytes(4)
  assert_true(response.read_body() is Err(_))
}

test "copy_body_to writes decoded bytes when automatic decoding is enabled" {
  let encoded = auto_decompress_gzip_hello()
  let response = auto_decompress_response(encoded).with_auto_decompress(true)
  let sink = AutoDecompressMockStream::{
    input: b"",
    offset: 0,
    output: Buffer(size_hint=16),
  }
  assert_eq(response.copy_body_to(sink).unwrap(), 5)
  assert_eq(sink.output.to_bytes(), b"hello")
}

test "unsupported content codings still fail with automatic decoding" {
  let stream : &Stream = AutoDecompressMockStream::{
    input: b"payload",
    offset: 0,
    output: Buffer(size_hint=0),
  }
  let response = Response::new(
    200,
    Headers::new().set("Content-Encoding", "br"),
    stream,
  ).with_auto_decompress(true)
  match response.read_body() {
    Ok(_) => fail("unsupported Content-Encoding was returned as a body")
    Err(err) =>
      assert_eq(err, ProtocolError("unsupported Content-Encoding: br"))
  }
}
