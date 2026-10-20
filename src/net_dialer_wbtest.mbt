test "TcpDialer creation" {
  let dialer = TcpDialer::new()
  assert_eq(dialer.timeout_ms, 30000)
}

test "TcpDialer with custom timeout" {
  let dialer = TcpDialer::with_timeout(5000)
  assert_eq(dialer.timeout_ms, 5000)
}

test "TcpDialer dial_tcp" {
  let dialer = TcpDialer::new()
  let result = dialer.dial_tcp("example.com", 80)
  assert_true(result is Ok(_))
  
  let stream = result.unwrap()
  let peer_addr = stream.peer_addr()
  assert_true(peer_addr is Ok(_))
  assert_eq(peer_addr.unwrap(), "example.com:80")
}

test "TcpDialer resolve" {
  let dialer = TcpDialer::new()
  let result = dialer.resolve("example.com")
  assert_true(result is Ok(_))
  
  let addresses = result.unwrap()
  assert_eq(addresses.length(), 1)
  assert_eq(addresses.nth(0).unwrap(), "example.com")
}
