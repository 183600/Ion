#cfg(target="native")
struct IdleTlsUnderlying {}

#cfg(target="native")
pub impl Stream for IdleTlsUnderlying with fn read(
  self : IdleTlsUnderlying,
  buf : Buffer,
) -> Result[Int, NetError] {
  let _ = self
  let _ = buf
  Ok(0)
}

#cfg(target="native")
pub impl Stream for IdleTlsUnderlying with fn read_ready(
  self : IdleTlsUnderlying,
) -> Bool {
  let _ = self
  false
}

#cfg(target="native")
pub impl Stream for IdleTlsUnderlying with fn write(
  self : IdleTlsUnderlying,
  buf : Buffer,
) -> Result[Int, NetError] {
  let _ = self
  Ok(buf.length())
}

#cfg(target="native")
pub impl Stream for IdleTlsUnderlying with fn flush(
  self : IdleTlsUnderlying,
) -> Result[Unit, NetError] {
  let _ = self
  Ok(())
}

#cfg(target="native")
pub impl Stream for IdleTlsUnderlying with fn close(
  self : IdleTlsUnderlying,
) -> Result[Unit, NetError] {
  let _ = self
  Ok(())
}

#cfg(target="native")
pub impl Stream for IdleTlsUnderlying with fn set_timeout(
  self : IdleTlsUnderlying,
  timeout_ms : Int,
) -> Result[Unit, NetError] {
  let _ = self
  let _ = timeout_ms
  Ok(())
}

#cfg(target="native")
pub impl Stream for IdleTlsUnderlying with fn peer_addr(
  self : IdleTlsUnderlying,
) -> Result[String, NetError] {
  let _ = self
  Ok("mock:0")
}

#cfg(target="native")
pub impl Stream for IdleTlsUnderlying with fn local_addr(
  self : IdleTlsUnderlying,
) -> Result[String, NetError] {
  let _ = self
  Ok("mock:0")
}

#cfg(target="native")
fn partial_record_tls() -> NativeTlsHandle {
  feather_tls_new(
    @utf8.encode("example.com"),
    b"",
    0,
    0,
    0,
    b"",
    0,
    b"",
    0,
    b"",
    0,
  )
}

#cfg(target="native")
fn tls_stream_over_idle(tls : NativeTlsHandle) -> NativeTlsStream {
  let underlying : &Stream = IdleTlsUnderlying::{  }
  NativeTlsStream::{ tls, underlying, key_log: None, is_open: true }
}

/// A partial TLS record in the OpenSSL read BIO is still unread transport
/// state. It must make the connection non-reusable even though it does not
/// decode to application data yet.
#cfg(target="native")
test "native TLS reports a partial buffered record as unsafe to pool" {
  let tls = partial_record_tls()
  assert_eq(feather_tls_buffered_input(tls), 0)
  // First three bytes of an application-data record header, with the record
  // length and payload still missing.
  assert_eq(feather_tls_send_input(tls, b"\x17\x03\x03", 3), 3)
  // The readiness probe intentionally ignores incomplete records...
  assert_eq(feather_tls_pending(tls), 0)
  // ...but the pooling probe must not.
  assert_eq(feather_tls_buffered_input(tls), 1)
  let stream = tls_stream_over_idle(tls)
  assert_true(stream.has_buffered_input())
}

#cfg(target="native")
test "native TLS reports an empty read BIO as safe to pool" {
  let tls = partial_record_tls()
  assert_eq(feather_tls_buffered_input(tls), 0)
  let stream = tls_stream_over_idle(tls)
  assert_false(stream.has_buffered_input())
}
