///|
test "default dialer rejects malformed hosts on every target" {
  let dialer = default_dialer()
  assert_true(dialer.dial_tcp("bad host", 80) is Err(InvalidAddress(_)))
  assert_true(dialer.resolve("bad host") is Err(InvalidAddress(_)))
}

///|
#cfg(not(target="native"))
test "default dialer fails explicitly without a socket transport" {
  let dialer = default_dialer()
  assert_true(dialer.dial_tcp("example.com", 80) is Err(ConnectionFailed(_)))
  assert_true(dialer.resolve("example.com") is Err(ConnectionFailed(_)))
}
