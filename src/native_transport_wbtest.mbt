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
test "native dial hosts strip IPv6 brackets" {
  assert_eq(tcp_dial_host("[::1]"), "::1")
  assert_eq(tcp_dial_host("[fe80::1%eth0]"), "fe80::1%eth0")
  assert_eq(tcp_dial_host("[fe80::1%25eth0]"), "fe80::1%eth0")
  assert_eq(tcp_dial_host("fe80::1%25eth0"), "fe80::1%eth0")
  assert_eq(tcp_dial_host("example.com"), "example.com")
  assert_eq(tcp_dial_host("[v1.foo]"), "[v1.foo]")
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

  for address in ["127.0.0.1", "[::1]", "fe80::1%eth0"] {
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
