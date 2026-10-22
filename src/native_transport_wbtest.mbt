///|
#cfg(target="native")
test "native TLS provider validates configuration before connecting" {
  let provider = OpenSslTlsProvider::new()
  assert_true(provider.new_client(TlsConfig::new("")) is Err(InvalidConfig(_)))
  assert_true(provider.new_client(TlsConfig::new("example.com")) is Ok(_))
}

///|
#cfg(target="native")
test "native dialer resolves local hostnames" {
  let dialer = NativeTcpDialer::new()
  let addresses = dialer.resolve("localhost").unwrap()
  assert_true(addresses.length() > 0)
  assert_true(dialer.resolve("bad host") is Err(InvalidAddress(_)))
}

///|
#cfg(target="native")
test "native streams reject invalid targets without dialing" {
  let invalid_host = NativeTcpStream::new("bad host", 80)
  assert_true(invalid_host.open() is Err(InvalidAddress(_)))
  let invalid_port = NativeTcpStream::new("127.0.0.1", 0)
  assert_true(invalid_port.open() is Err(InvalidAddress(_)))
  let missing = NativeTcpStream::new("127.0.0.1", 1)
  assert_true(missing.read(Buffer()) is Err(Closed))
}
///|
#cfg(target="native")
test "native DNS failures are classified as invalid addresses" {
  assert_true(native_tcp_address_error(10002) is InvalidAddress(_))
  assert_true(native_tcp_address_error(10110) is InvalidAddress(_))
}
///|
#cfg(target="native")
test "native TCP I/O errors report reset connections as closed" {
  assert_true(native_tcp_error(104, "TCP read") is Closed)
  assert_true(native_tcp_error(54, "TCP write") is Closed)
  assert_true(native_tcp_error(32, "TCP write") is Closed)
  assert_true(native_tcp_address_error(104) is ConnectionFailed(_))
}
///|
#cfg(target="native")
test "native dial hosts strip IPv6 brackets" {
  assert_eq(tcp_dial_host("[::1]"), "::1")
  assert_eq(tcp_dial_host("[fe80::1%eth0]"), "fe80::1%eth0")
  assert_eq(tcp_dial_host("[fe80::1%25eth0]"), "fe80::1%eth0")
  assert_eq(tcp_dial_host("fe80::1%25eth0"), "fe80::1%eth0")
  assert_eq(tcp_dial_host("[fe80::1%25eth%30]"), "fe80::1%eth0")
  assert_eq(tcp_dial_host("[fe80::1%eth%30]"), "fe80::1%eth0")
  assert_eq(tcp_dial_host("[fe80::1%25%25foo]"), "fe80::1%%foo")
  assert_eq(tcp_dial_host("example.com"), "example.com")
  assert_eq(tcp_dial_host("[v1.foo]"), "[v1.foo]")
}

///|
#cfg(target="native")
#borrow(host)
extern "C" fn feather_tcp_connect_nul_probe(
  host : Bytes,
  port : Int,
  timeout_ms : Int,
) -> Int = "feather_tcp_connect"

///|
#cfg(target="native")
#borrow(host, output)
extern "C" fn feather_tcp_resolve_nul_probe(
  host : Bytes,
  output : Bytes,
  capacity : Int,
) -> Int = "feather_tcp_resolve"

///|
#cfg(target="native")
#borrow(path, output)
extern "C" fn feather_read_file_nul_probe(
  path : Bytes,
  output : Bytes,
  capacity : Int,
) -> Int = "feather_read_file"

///|
#cfg(target="native")
#borrow(host, output)
extern "C" fn feather_tcp_resolve_capacity_probe(
  host : Bytes,
  output : Bytes,
  capacity : Int,
) -> Int = "feather_tcp_resolve"

///|
#cfg(target="native")
#borrow(path, output)
extern "C" fn feather_read_file_capacity_probe(
  path : Bytes,
  output : Bytes,
  capacity : Int,
) -> Int = "feather_read_file"

///|
#cfg(target="native")
test "native FFI rejects capacities beyond the output buffer" {
  let host = @utf8.encode("localhost")
  let output = Bytes::new(8)
  assert_eq(feather_tcp_resolve_capacity_probe(host, output, 9), -22)
  let path = @utf8.encode("/dev/null")
  assert_eq(feather_read_file_capacity_probe(path, output, 9), -22)
}

///|
#cfg(target="native")
test "native TCP FFI rejects embedded NUL bytes" {
  let host = @utf8.encode("localhost\u{0}evil")
  assert_eq(feather_tcp_connect_nul_probe(host, 1, 10), -22)
  let output = Bytes::new(256)
  assert_eq(feather_tcp_resolve_nul_probe(host, output, 256), -22)
  let path = @utf8.encode("/nonexistent-feather-nul\u{0}ignored")
  assert_eq(feather_read_file_nul_probe(path, output, 256), -22)
}

///|
#cfg(target="native")
#borrow(tls, buffer)
extern "C" fn feather_tls_sni_name(
  tls : NativeTlsHandle,
  buffer : Bytes,
  capacity : Int,
) -> Int = "feather_tls_sni_name"

///|
#cfg(target="native")
test "native TLS rejects an invalid CA bundle" {
  let roots = @utf8.encode("this is not a PEM certificate")
  let config = TlsConfig::new("example.com").with_root_store(
    RootStore::new().add_certificate(roots),
  )
  let provider = OpenSslTlsProvider::new()
  let ctx = provider.new_client(config).unwrap()
  let stream = regression_mock_stream("", 0, 0)
  match ctx.connect(stream) {
    Err(InvalidConfig(message)) =>
      assert_true(message.contains("CA bundle does not contain"))
    _ => abort("invalid CA bundle should fail before the handshake")
  }
}

///|
#cfg(target="native")
test "native TLS sends SNI only for host names" {
  let hostname = @utf8.encode("example.com")
  let tls = feather_tls_new(
    hostname,
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
  assert_eq(feather_tls_ready(tls), 1)
  let buffer = Bytes::new(128)
  let length = feather_tls_sni_name(tls, buffer, 128)
  assert_eq(@utf8.decode_lossy(buffer.exact_view(start=0, end=length)), "example.com")

  let dotted = feather_tls_new(
    @utf8.encode("example.com."),
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
  assert_eq(feather_tls_ready(dotted), 1)
  let length = feather_tls_sni_name(dotted, buffer, 128)
  assert_eq(@utf8.decode_lossy(buffer.exact_view(start=0, end=length)), "example.com")

  for address in ["127.0.0.1", "127.0.0.1.", "[::1]", "fe80::1%eth0", "[v1.foo]"] {
    let tls = feather_tls_new(
      @utf8.encode(address),
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
    assert_eq(feather_tls_ready(tls), 1)
    assert_eq(feather_tls_sni_name(tls, buffer, 128), 0)
  }
}

///|
#cfg(target="native")
test "native TLS rejects server names with embedded NUL bytes" {
  let tls = feather_tls_new(
    @utf8.encode("example.com\u{0}evil"),
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
  assert_eq(feather_tls_ready(tls), 0)
}

///|
#cfg(target="native")
struct ClosedTlsUnderlying {}

///|
#cfg(target="native")
pub impl Stream for ClosedTlsUnderlying with fn read(
  self : ClosedTlsUnderlying,
  buf : Buffer,
) -> Result[Int, NetError] {
  let _ = self
  let _ = buf
  Err(NetError::Closed)
}

///|
#cfg(target="native")
pub impl Stream for ClosedTlsUnderlying with fn write(
  self : ClosedTlsUnderlying,
  buf : Buffer,
) -> Result[Int, NetError] {
  let _ = self
  let _ = buf
  Err(NetError::Closed)
}

///|
#cfg(target="native")
pub impl Stream for ClosedTlsUnderlying with fn flush(
  self : ClosedTlsUnderlying,
) -> Result[Unit, NetError] {
  let _ = self
  Ok(())
}

///|
#cfg(target="native")
pub impl Stream for ClosedTlsUnderlying with fn close(
  self : ClosedTlsUnderlying,
) -> Result[Unit, NetError] {
  let _ = self
  Ok(())
}

///|
#cfg(target="native")
pub impl Stream for ClosedTlsUnderlying with fn set_timeout(
  self : ClosedTlsUnderlying,
  timeout_ms : Int,
) -> Result[Unit, NetError] {
  let _ = self
  let _ = timeout_ms
  Ok(())
}

///|
#cfg(target="native")
pub impl Stream for ClosedTlsUnderlying with fn peer_addr(
  self : ClosedTlsUnderlying,
) -> Result[String, NetError] {
  let _ = self
  Ok("mock:0")
}

///|
#cfg(target="native")
pub impl Stream for ClosedTlsUnderlying with fn local_addr(
  self : ClosedTlsUnderlying,
) -> Result[String, NetError] {
  let _ = self
  Ok("mock:0")
}

///|
#cfg(target="native")
fn closed_tls_stream() -> NativeTlsStream {
  let tls = feather_tls_new(
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
  let underlying : &Stream = ClosedTlsUnderlying::{}
  NativeTlsStream::{ tls, underlying, key_log: None, is_open: true }
}

///|
#cfg(target="native")
test "native TLS I/O reports a closed transport as Closed" {
  let reader = closed_tls_stream()
  assert_true(reader.read(Buffer()) is Err(Closed))
  let writer = closed_tls_stream()
  let data = Buffer(size_hint=1)
  data.write_byte(b'x')
  assert_true(writer.write(data) is Err(Closed))
  let flushing = closed_tls_stream()
  assert_true(flushing.flush() is Ok(_))
}

///|
#cfg(target="native")
struct RecordingUnderlying {
  mut output : Bytes
  mut read_calls : Int
}

///|
#cfg(target="native")
pub impl Stream for RecordingUnderlying with fn read(
  self : RecordingUnderlying,
  buf : Buffer,
) -> Result[Int, NetError] {
  let _ = buf
  self.read_calls = self.read_calls + 1
  Err(NetError::Timeout)
}

///|
#cfg(target="native")
pub impl Stream for RecordingUnderlying with fn write(
  self : RecordingUnderlying,
  buf : Buffer,
) -> Result[Int, NetError] {
  let data = buf.to_bytes()
  let combined = Buffer(size_hint=self.output.length() + data.length())
  combined.write_bytes(self.output)
  combined.write_bytes(data)
  self.output = combined.to_bytes()
  Ok(data.length())
}

///|
#cfg(target="native")
pub impl Stream for RecordingUnderlying with fn flush(
  self : RecordingUnderlying,
) -> Result[Unit, NetError] {
  let _ = self
  Ok(())
}

///|
#cfg(target="native")
pub impl Stream for RecordingUnderlying with fn close(
  self : RecordingUnderlying,
) -> Result[Unit, NetError] {
  let _ = self
  Ok(())
}

///|
#cfg(target="native")
pub impl Stream for RecordingUnderlying with fn set_timeout(
  self : RecordingUnderlying,
  timeout_ms : Int,
) -> Result[Unit, NetError] {
  let _ = self
  let _ = timeout_ms
  Ok(())
}

///|
#cfg(target="native")
pub impl Stream for RecordingUnderlying with fn peer_addr(
  self : RecordingUnderlying,
) -> Result[String, NetError] {
  let _ = self
  Ok("mock:0")
}

///|
#cfg(target="native")
pub impl Stream for RecordingUnderlying with fn local_addr(
  self : RecordingUnderlying,
) -> Result[String, NetError] {
  let _ = self
  Ok("mock:0")
}

///|
#cfg(target="native")
test "native TLS writes flush handshake records before reading on WANT_READ" {
  let tls = feather_tls_new(
    @utf8.encode("example.com"),
    b"",
    0,
    1,
    0,
    b"",
    0,
    b"",
    0,
    b"",
    0,
  )
  assert_eq(feather_tls_ready(tls), 1)
  let underlying = RecordingUnderlying::{ output: b"", read_calls: 0 }
  let stream = NativeTlsStream::{ tls, underlying, key_log: None, is_open: true }
  let data = Buffer(size_hint=5)
  data.write_bytes(b"hello")
  assert_true(stream.write(data) is Err(NetError::Timeout))
  assert_eq(underlying.read_calls, 1)
  assert_true(underlying.output.length() > 5)
  assert_eq(underlying.output[0], 0x16)
  assert_eq(underlying.output[1], 0x03)
}

///|
#cfg(target="native")
test "native TLS handshake reports close_notify as ConnectionClosed" {
  let provider = OpenSslTlsProvider::new()
  let config = TlsConfig::new("example.com").with_verify_mode(SkipVerification)
  let ctx = provider.new_client(config).unwrap()
  // A TLS alert record containing close_notify (warning, description 0).
  let alert = @utf8.decode_lossy(
    Bytes::from_array([0x15, 0x03, 0x03, 0x00, 0x02, 0x01, 0x00])[:],
  )
  let stream = regression_mock_stream(alert, 0, 0)
  match ctx.connect(stream) {
    Err(ConnectionClosed) => ()
    Err(err) => abort("expected ConnectionClosed, got " + @debug.to_string(err))
    Ok(_) => abort("handshake unexpectedly succeeded")
  }
}
