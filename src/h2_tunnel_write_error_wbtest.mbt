/// A transport that serves a prepared HTTP/2 response but rejects the write
/// that carries tunnel DATA.
struct H2TunnelWriteFailStream {
  input : Bytes
  mut offset : Int
  mut writes : Int
  fail_on_write : Int
  mut is_open : Bool
}

///|
fn H2TunnelWriteFailStream::new(input : Bytes, fail_on_write : Int) -> H2TunnelWriteFailStream {
  H2TunnelWriteFailStream::{
    input,
    offset: 0,
    writes: 0,
    fail_on_write,
    is_open: true,
  }
}

///|
pub impl Stream for H2TunnelWriteFailStream with fn read(
  self : H2TunnelWriteFailStream,
  buf : Buffer,
) -> Result[Int, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  if self.offset >= self.input.length() {
    return Ok(0)
  }
  buf.write_bytes(self.input.exact_view(start=self.offset))
  let count = self.input.length() - self.offset
  self.offset = self.input.length()
  Ok(count)
}

///|
pub impl Stream for H2TunnelWriteFailStream with fn write(
  self : H2TunnelWriteFailStream,
  buf : Buffer,
) -> Result[Int, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  self.writes = self.writes + 1
  if self.writes == self.fail_on_write {
    return Err(NetError::WriteError("injected tunnel write failure"))
  }
  Ok(buf.length())
}

///|
pub impl Stream for H2TunnelWriteFailStream with fn flush(
  self : H2TunnelWriteFailStream,
) -> Result[Unit, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Ok(())
}

///|
pub impl Stream for H2TunnelWriteFailStream with fn close(
  self : H2TunnelWriteFailStream,
) -> Result[Unit, NetError] {
  self.is_open = false
  Ok(())
}

///|
pub impl Stream for H2TunnelWriteFailStream with fn set_timeout(
  self : H2TunnelWriteFailStream,
  timeout_ms : Int,
) -> Result[Unit, NetError] {
  let _ = timeout_ms
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Ok(())
}

///|
pub impl Stream for H2TunnelWriteFailStream with fn peer_addr(
  self : H2TunnelWriteFailStream,
) -> Result[String, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Ok("127.0.0.1:443")
}

///|
pub impl Stream for H2TunnelWriteFailStream with fn local_addr(
  self : H2TunnelWriteFailStream,
) -> Result[String, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Ok("127.0.0.1:50000")
}

///|
test "http2 CONNECT reports tunnel DATA write failures as write errors" {
  let headers = hpack_encode([(":status", "200")])
  // The preface, SETTINGS, WINDOW_UPDATE, SETTINGS ACK and request HEADERS are
  // writes 1-5; the sixth write is the tunnel DATA frame.
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, headers),
  ])
  let stream = H2TunnelWriteFailStream::new(input, 6)
  let response = h2_request(
    stream,
    Request::new(CONNECT, Url::parse("http://example.com:80/").unwrap()),
  ).unwrap()
  assert_eq(response.status, 200)
  let payload = Buffer(size_hint=4)
  payload.write_bytes(b"ping")
  assert_eq(
    response.body.write(payload),
    Err(NetError::WriteError("injected tunnel write failure")),
  )
  assert_eq(
    h2_tunnel_write_error(ProtocolError("invalid frame")),
    NetError::WriteError("invalid frame"),
  )
}
