/// A codec reused for sequential keep-alive exchanges must share the bytes it
/// buffered while reading a response head with the body stream. Otherwise the
/// next decode starts inside the previous body.

struct CodecReuseStream {
  chunks : Array[Bytes]
  mut index : Int
  output : Buffer
  mut is_open : Bool
}

fn codec_reuse_stream(chunks : Array[String]) -> CodecReuseStream {
  let encoded : Array[Bytes] = []
  for chunk in chunks {
    encoded.push(@utf8.encode(chunk))
  }
  CodecReuseStream::{
    chunks: encoded,
    index: 0,
    output: @buffer.new(size_hint=4096),
    is_open: true,
  }
}

pub impl Stream for CodecReuseStream with fn read(
  self : CodecReuseStream,
  buf : Buffer,
) -> Result[Int, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  if self.index >= self.chunks.length() {
    return Ok(0)
  }
  let chunk = self.chunks[self.index]
  self.index = self.index + 1
  buf.write_bytes(chunk)
  Ok(chunk.length())
}

pub impl Stream for CodecReuseStream with fn write(
  self : CodecReuseStream,
  buf : Buffer,
) -> Result[Int, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  self.output.write_bytes(buf.to_bytes())
  Ok(buf.length())
}

pub impl Stream for CodecReuseStream with fn flush(
  self : CodecReuseStream,
) -> Result[Unit, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Ok(())
}

pub impl Stream for CodecReuseStream with fn close(
  self : CodecReuseStream,
) -> Result[Unit, NetError] {
  self.is_open = false
  Ok(())
}

pub impl Stream for CodecReuseStream with fn set_timeout(
  self : CodecReuseStream,
  timeout_ms : Int,
) -> Result[Unit, NetError] {
  let _ = timeout_ms
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Ok(())
}

pub impl Stream for CodecReuseStream with fn peer_addr(
  self : CodecReuseStream,
) -> Result[String, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Ok("mock:0")
}

pub impl Stream for CodecReuseStream with fn local_addr(
  self : CodecReuseStream,
) -> Result[String, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Ok("mock:0")
}

test "H1Codec reuses buffered bytes after a fixed-length response body" {
  let stream = codec_reuse_stream([
    "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\none",
    "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\ntwo",
  ])
  let codec = H1Codec::new(stream)
  let url = Url::parse("http://example.com/").unwrap()

  assert_true(codec.encode_request(Request::new(GET, url)) is Ok(_))
  assert_eq(codec.decode_response().unwrap().read_body().unwrap(), b"one")
  assert_true(codec.encode_request(Request::new(GET, url)) is Ok(_))
  assert_eq(codec.decode_response().unwrap().read_body().unwrap(), b"two")
}

test "H1Codec reuses buffered bytes after a chunked response body" {
  let stream = codec_reuse_stream([
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\none\r\n0\r\n\r\n",
    "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\ntwo",
  ])
  let codec = H1Codec::new(stream)
  let url = Url::parse("http://example.com/").unwrap()

  assert_true(codec.encode_request(Request::new(GET, url)) is Ok(_))
  assert_eq(codec.decode_response().unwrap().read_body().unwrap(), b"one")
  assert_true(codec.encode_request(Request::new(GET, url)) is Ok(_))
  assert_eq(codec.decode_response().unwrap().read_body().unwrap(), b"two")
}
