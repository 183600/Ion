/// SOCKS5 proxy support: URL parsing, handshake, authentication, and routing.

fn socks5_test_stream(input : Bytes, max_read : Int) -> RegressionMockStream {
  RegressionMockStream::{
    input,
    offset: 0,
    output: @buffer.new(size_hint=4096),
    max_read,
    max_write: 0,
    is_open: true,
    last_timeout: 0,
  }
}

fn socks5_test_bytes(values : Array[Int]) -> Bytes {
  let output = Buffer(size_hint=values.length())
  for value in values {
    output.write_byte(value.to_byte())
  }
  output.to_bytes()
}

fn socks5_expected_request(host : String, port : Int) -> Bytes {
  let output = Buffer(size_hint=host.length() + 8)
  output.write_byte(5)
  output.write_byte(1)
  output.write_byte(0)
  let name = @utf8.encode(host)
  output.write_byte(3)
  output.write_byte(name.length().to_byte())
  output.write_bytes(name)
  output.write_byte(((port >> 8) & 0xff).to_byte())
  output.write_byte((port & 0xff).to_byte())
  output.to_bytes()
}

test "SOCKS5 URL parsing applies the default port and decodes credentials" {
  let proxy = Proxy::new_socks5("socks5://user:pa%3Ass@proxy.example").unwrap()
  assert_true(proxy.is_socks5())
  assert_eq(proxy.authority(), "proxy.example:1080")
  assert_true(proxy.authorization() is None)
  let (username, password) = proxy.socks_credentials().unwrap()
  assert_eq(username, b"user")
  assert_eq(password, b"pa:ss")

  let explicit = Proxy::new_socks5("socks5h://[2001:db8::1]:1081").unwrap()
  assert_eq(explicit.authority(), "[2001:db8::1]:1081")
  assert_true(Proxy::new_socks5("http://proxy.example") is Err(_))
  assert_eq(Proxy::new_socks5("socks5://proxy.example:").unwrap().authority(), "proxy.example:1080")
  assert_true(Proxy::new_socks5("socks5://proxy.example/path") is Err(_))
  assert_true(Proxy::new_socks5("socks5://proxy.example?x") is Err(_))
  assert_true(Proxy::new("socks5://proxy.example:1080") is Err(_))
  assert_true(Proxy::parse("socks5://proxy.example:1080") is Ok(_))
  assert_true(Proxy::parse("https://proxy.example:8443") is Ok(_))
  assert_true(Proxy::parse("proxy.example:3128") is Ok(_))
}

test "SOCKS5 credentials must fit the one-byte length fields" {
  assert_true(Proxy::new_socks5("socks5://user@proxy.example") is Err(InvalidUrl(_)))
  assert_true(
    Proxy::new_socks5_with_auth("proxy.example", 1080, "", "pass") is
    Err(InvalidUrl(_)),
  )
  assert_true(
    Proxy::new_socks5_with_auth("proxy.example", 1080, "user", "") is
    Err(InvalidUrl(_)),
  )
  let too_long = "a".repeat(256)
  assert_true(
    Proxy::new_socks5_with_auth("proxy.example", 1080, too_long, "pass") is
    Err(InvalidUrl(_)),
  )
  assert_true(
    Proxy::new_socks5_with_auth("proxy.example", 1080, "user", "pass") is Ok(_),
  )
}

test "SOCKS5 no-auth handshake sends the target and returns early bytes" {
  let server = socks5_test_bytes([
    5, 0,
    5, 0, 0, 1, 127, 0, 0, 1, 0x1f, 0x90,
  ])
  let stream = socks5_test_stream(server, 0)
  let leftover = socks5_connect(
    stream,
    "example.com",
    80,
    false,
    None,
  ).unwrap()
  assert_eq(leftover, b"")
  let expected = Buffer(size_hint=32)
  expected.write_bytes(socks5_test_bytes([5, 1, 0]))
  expected.write_bytes(socks5_expected_request("example.com", 80))
  assert_eq(stream.output.to_bytes(), expected.to_bytes())
}

test "SOCKS5 handshake preserves bytes read past the reply" {
  let server = Buffer(size_hint=32)
  server.write_bytes(socks5_test_bytes([5, 0, 5, 0, 0, 1, 127, 0, 0, 1, 0, 80]))
  server.write_bytes(b"HTTP/1.1 200 OK\r\n\r\n")
  let stream = socks5_test_stream(server.to_bytes(), 0)
  let leftover = socks5_connect(stream, "127.0.0.1", 8080, false, None).unwrap()
  assert_eq(leftover, b"HTTP/1.1 200 OK\r\n\r\n")
}

test "SOCKS5 username/password authentication is sent when selected" {
  let server = Buffer(size_hint=32)
  server.write_bytes(socks5_test_bytes([5, 2, 1, 0]))
  server.write_bytes(socks5_test_bytes([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]))
  let stream = socks5_test_stream(server.to_bytes(), 0)
  let credentials = (b"user", b"pass")
  let leftover = socks5_connect(
    stream,
    "origin.example",
    443,
    false,
    Some(credentials),
  ).unwrap()
  assert_eq(leftover, b"")
  let expected = Buffer(size_hint=64)
  expected.write_bytes(socks5_test_bytes([5, 2, 0, 2]))
  expected.write_bytes(socks5_test_bytes([1, 4]))
  expected.write_bytes(b"user")
  expected.write_bytes(socks5_test_bytes([4]))
  expected.write_bytes(b"pass")
  expected.write_bytes(socks5_expected_request("origin.example", 443))
  assert_eq(stream.output.to_bytes(), expected.to_bytes())
}

test "SOCKS5 rejects a username/password request when no credentials exist" {
  let stream = socks5_test_stream(socks5_test_bytes([5, 2]), 0)
  match socks5_connect(stream, "example.com", 80, false, None) {
    Err(ProtocolError(message)) => assert_true(message.contains("requires"))
    _ => abort("expected missing SOCKS5 credentials to fail")
  }
}

test "SOCKS5 rejects all-unsupported authentication methods" {
  let stream = socks5_test_stream(socks5_test_bytes([5, 0xff]), 0)
  match socks5_connect(stream, "example.com", 80, false, None) {
    Err(ProtocolError(message)) => assert_true(message.contains("authentication"))
    _ => abort("expected SOCKS5 method rejection")
  }
}

test "SOCKS5 authentication failure is reported without leaking the reply" {
  let server = Buffer(size_hint=16)
  server.write_bytes(socks5_test_bytes([5, 2]))
  server.write_bytes(socks5_test_bytes([1, 1]))
  let stream = socks5_test_stream(server.to_bytes(), 0)
  match socks5_connect(
    stream,
    "example.com",
    80,
    false,
    Some((b"user", b"pass")),
  ) {
    Err(ProtocolError(message)) => assert_true(message.contains("authentication failed"))
    _ => abort("expected SOCKS5 authentication failure")
  }
}

test "SOCKS5 reply codes map to connection errors" {
  let stream = socks5_test_stream(
    socks5_test_bytes([5, 0, 5, 5, 0, 1, 0, 0, 0, 0, 0, 0]),
    0,
  )
  match socks5_connect(stream, "example.com", 80, false, None) {
    Err(NetworkError(ConnectionFailed(message))) =>
      assert_true(message.contains("refused"))
    _ => abort("expected SOCKS5 refusal")
  }
  let unsupported = socks5_test_stream(
    socks5_test_bytes([5, 0, 5, 7, 0, 1, 0, 0, 0, 0, 0, 0]),
    0,
  )
  match socks5_connect(unsupported, "example.com", 80, false, None) {
    Err(ProtocolError(message)) => assert_true(message.contains("CONNECT"))
    _ => abort("expected unsupported SOCKS5 command")
  }
}

test "SOCKS5 encodes IPv4 targets as binary addresses" {
  let server = socks5_test_bytes([5, 0, 5, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
  let stream = socks5_test_stream(server, 0)
  let _ = socks5_connect(stream, "127.0.0.1", 8080, false, None).unwrap()
  let expected = socks5_test_bytes([
    5, 1, 0,
    5, 1, 0, 1, 127, 0, 0, 1, 0x1f, 0x90,
  ])
  assert_eq(stream.output.to_bytes(), expected)
}

test "SOCKS5 routes plain HTTP through the tunnel without absolute-form" {
  let server = Buffer(size_hint=128)
  server.write_bytes(socks5_test_bytes([5, 0, 5, 0, 0, 1, 127, 0, 0, 1, 0, 80]))
  server.write_bytes(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
  let stream = socks5_test_stream(server.to_bytes(), 0)
  let dialer = RegressionProxyDialer::{ stream, host: "", port: 0 }
  let proxy = Proxy::new_socks5("socks5://proxy.example:1080").unwrap()
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
    .with_proxy(proxy)
    .with_http2(false)
  let client = UnifiedClient::{
    connector,
    options: ClientOptions::new().with_follow_redirects(false),
    redirect_count: 0,
  }
  let response = client.get("http://origin.example/hello").unwrap()
  assert_eq(response.status, 200)
  assert_eq(response.read_body().unwrap(), b"ok")
  assert_eq(dialer.host, "proxy.example")
  assert_eq(dialer.port, 1080)
  let wire = @utf8.decode_lossy(stream.output.to_bytes())
  assert_true(wire.contains("GET /hello HTTP/1.1\r\n"))
  assert_true(wire.contains("Host: origin.example\r\n"))
  assert_false(wire.contains("GET http://"))
  assert_false(wire.contains("Proxy-Authorization"))
}

test "SOCKS5 routes HTTPS through the tunnel before TLS" {
  let server = Buffer(size_hint=128)
  server.write_bytes(socks5_test_bytes([5, 0, 5, 0, 0, 1, 127, 0, 0, 1, 0, 443]))
  server.write_bytes(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
  let stream = socks5_test_stream(server.to_bytes(), 0)
  let dialer = RegressionProxyDialer::{ stream, host: "", port: 0 }
  let proxy = Proxy::new_socks5("socks5://proxy.example:1080").unwrap()
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
    .with_proxy(proxy)
    .with_http2(false)
  let client = UnifiedClient::{
    connector,
    options: ClientOptions::new().with_follow_redirects(false),
    redirect_count: 0,
  }
  let response = client.get("https://origin.example/secure").unwrap()
  assert_eq(response.status, 200)
  assert_eq(response.read_body().unwrap(), b"ok")
  let wire = @utf8.decode_lossy(stream.output.to_bytes())
  assert_true(wire.contains("GET /secure HTTP/1.1\r\n"))
  assert_false(wire.contains("CONNECT "))
}

test "SOCKS5 encodes IPv6 targets as binary addresses" {
  let server = Buffer(size_hint=24)
  server.write_bytes(socks5_test_bytes([5, 0, 5, 0, 0, 4]))
  let mut index = 0
  while index < 18 {
    server.write_byte(0)
    index = index + 1
  }
  let stream = socks5_test_stream(server.to_bytes(), 0)
  let _ = socks5_connect(stream, "2001:db8::1", 443, true, None).unwrap()
  let expected = socks5_test_bytes([
    5, 1, 0,
    5, 1, 0, 4,
    0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
    0x01, 0xbb,
  ])
  assert_eq(stream.output.to_bytes(), expected)
}

test "SOCKS5 builder normalizes bracketed IPv6 proxy and target hosts" {
  let proxy = Proxy::new_socks5_with_auth(
    "[2001:db8::1]",
    1080,
    "user",
    "pass",
  ).unwrap()
  assert_eq(proxy.url.host, "2001:db8::1")
  assert_true(proxy.url.bracketed)
  assert_eq(proxy.authority(), "[2001:db8::1]:1080")
  let output = Buffer(size_hint=20)
  socks5_append_target(output, proxy.url.host, 443, proxy.url.bracketed).unwrap()
  assert_eq(
    output.to_bytes(),
    socks5_test_bytes([
      4, 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
      0x01, 0xbb,
    ]),
  )
}

test "SOCKS5 credentials are used by the client without adding proxy headers" {
  let server = Buffer(size_hint=128)
  server.write_bytes(socks5_test_bytes([5, 2]))
  server.write_bytes(socks5_test_bytes([1, 0]))
  server.write_bytes(socks5_test_bytes([5, 0, 0, 1, 127, 0, 0, 1, 0, 80]))
  server.write_bytes(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
  let stream = socks5_test_stream(server.to_bytes(), 0)
  let dialer = RegressionProxyDialer::{ stream, host: "", port: 0 }
  let proxy = Proxy::new_socks5("socks5://user:pass@proxy.example:1080").unwrap()
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
    .with_proxy(proxy)
    .with_http2(false)
  let client = UnifiedClient::{
    connector,
    options: ClientOptions::new().with_follow_redirects(false),
    redirect_count: 0,
  }
  let response = client.get("http://origin.example/").unwrap()
  assert_eq(response.read_body().unwrap(), b"ok")
  let wire = @utf8.decode_lossy(stream.output.to_bytes())
  assert_true(wire.contains("user"))
  assert_true(wire.contains("pass"))
  assert_false(wire.contains("Proxy-Authorization"))
  assert_true(wire.contains("GET / HTTP/1.1\r\n"))
}

test "SOCKS5 successful reply requires a zero reserved byte" {
  let stream = socks5_test_stream(
    socks5_test_bytes([5, 0, 5, 0, 1, 1, 127, 0, 0, 1, 0, 80]),
    0,
  )
  match socks5_connect(stream, "example.com", 80, false, None) {
    Err(ProtocolError(message)) => assert_true(message.contains("reserved"))
    _ => abort("expected a non-zero SOCKS5 reserved byte to fail")
  }
}
