/// SOCKS5 scheme semantics: plain `socks5` resolves destination names
/// locally, while `socks5h` delegates resolution to the proxy.

struct Socks5ResolvingDialer {
  stream : &Stream
  mut resolve_calls : Int
  mut resolved_host : String
  mut dialed_host : String
}

pub impl Dialer for Socks5ResolvingDialer with fn dial_tcp(
  self : Socks5ResolvingDialer,
  host : String,
  port : Int,
) -> Result[&Stream, NetError] {
  let _ = port
  self.dialed_host = host
  Ok(self.stream)
}

pub impl Dialer for Socks5ResolvingDialer with fn resolve(
  self : Socks5ResolvingDialer,
  host : String,
) -> Result[List[String], NetError] {
  self.resolve_calls = self.resolve_calls + 1
  self.resolved_host = host
  Ok(@list.List(["192.0.2.7"]))
}

fn socks5_dns_stream(
  input : Bytes,
) -> RegressionMockStream {
  RegressionMockStream::{
    input,
    offset: 0,
    output: @buffer.new(size_hint=128),
    max_read: 0,
    max_write: 0,
    is_open: true,
    last_timeout: 0,
  }
}

fn socks5_dns_reply() -> Bytes {
  let server = Buffer(size_hint=128)
  server.write_bytes(socks5_test_bytes([5, 0, 5, 0, 0, 1, 127, 0, 0, 1, 0, 80]))
  server.write_bytes(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
  server.to_bytes()
}

fn socks5_dns_prefix(output : Bytes, expected : Bytes) -> Bool {
  if output.length() < expected.length() {
    return false
  }
  let mut index = 0
  while index < expected.length() {
    if output[index] != expected[index] {
      return false
    }
    index = index + 1
  }
  true
}

fn socks5_dns_client(
  dialer : Socks5ResolvingDialer,
  proxy_url : String,
) -> UnifiedClient {
  let proxy = Proxy::new_socks5(proxy_url).unwrap()
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
    .with_proxy(proxy)
    .with_http2(false)
  UnifiedClient::{
    connector,
    options: ClientOptions::new().with_follow_redirects(false),
    redirect_count: 0,
  }
}

///|
test "socks5 resolves a destination name locally and sends its address" {
  let stream = socks5_dns_stream(socks5_dns_reply())
  let dialer = Socks5ResolvingDialer::{
    stream,
    resolve_calls: 0,
    resolved_host: "",
    dialed_host: "",
  }
  let client = socks5_dns_client(dialer, "socks5://proxy.example:1080")
  let response = client.get("http://origin.example/hello").unwrap()
  assert_eq(response.status, 200)
  assert_eq(response.read_body().unwrap(), b"ok")
  assert_eq(dialer.resolve_calls, 1)
  assert_eq(dialer.resolved_host, "origin.example")
  assert_eq(dialer.dialed_host, "proxy.example")
  let expected = Buffer(size_hint=32)
  expected.write_bytes(socks5_test_bytes([5, 1, 0]))
  // CONNECT 192.0.2.7:80 uses the IPv4 address type, not a domain name.
  expected.write_bytes(socks5_test_bytes([5, 1, 0, 1, 192, 0, 2, 7, 0, 80]))
  assert_true(socks5_dns_prefix(stream.output.to_bytes(), expected.to_bytes()))
}

///|
test "socks5h leaves the destination name for the proxy to resolve" {
  let stream = socks5_dns_stream(socks5_dns_reply())
  let dialer = Socks5ResolvingDialer::{
    stream,
    resolve_calls: 0,
    resolved_host: "",
    dialed_host: "",
  }
  let client = socks5_dns_client(dialer, "socks5h://proxy.example:1080")
  let response = client.get("http://origin.example/hello").unwrap()
  assert_eq(response.status, 200)
  assert_eq(response.read_body().unwrap(), b"ok")
  assert_eq(dialer.resolve_calls, 0)
  assert_eq(dialer.dialed_host, "proxy.example")
  let expected = Buffer(size_hint=32)
  expected.write_bytes(socks5_test_bytes([5, 1, 0]))
  expected.write_bytes(socks5_expected_request("origin.example", 80))
  assert_true(socks5_dns_prefix(stream.output.to_bytes(), expected.to_bytes()))
}

///|
test "socks5 skips local resolution for IP literals" {
  let stream = socks5_dns_stream(socks5_dns_reply())
  let dialer = Socks5ResolvingDialer::{
    stream,
    resolve_calls: 0,
    resolved_host: "",
    dialed_host: "",
  }
  let client = socks5_dns_client(dialer, "socks5://proxy.example:1080")
  let response = client.get("http://192.0.2.7/hello").unwrap()
  assert_eq(response.status, 200)
  assert_eq(dialer.resolve_calls, 0)
  let expected = Buffer(size_hint=32)
  expected.write_bytes(socks5_test_bytes([5, 1, 0]))
  expected.write_bytes(socks5_test_bytes([5, 1, 0, 1, 192, 0, 2, 7, 0, 80]))
  assert_true(socks5_dns_prefix(stream.output.to_bytes(), expected.to_bytes()))
}
