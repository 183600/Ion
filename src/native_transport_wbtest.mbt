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
