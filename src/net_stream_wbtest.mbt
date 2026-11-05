///|
test "TcpStream basic operations" {
  let stream = TcpStream::new("example.com", 80)
  assert_eq(stream.host, "example.com")
  assert_eq(stream.port, 80)
  assert_eq(stream.is_open, false)
}

///|
test "TcpStream open and close" {
  let stream = TcpStream::new("example.com", 80)
  let result = stream.open()
  assert_true(result is Ok(_))
  assert_eq(stream.is_open, true)

  let close_result = stream.close()
  assert_true(close_result is Ok(_))
  assert_eq(stream.is_open, false)
}

///|
test "TcpStream operations on closed stream" {
  let stream = TcpStream::new("example.com", 80)
  let buf = @buffer.new(size_hint=1024)

  let read_result = stream.read(buf)
  assert_true(read_result is Err(_))
  assert_eq(read_result.unwrap_err(), Closed)

  let write_result = stream.write(buf)
  assert_true(write_result is Err(_))
  assert_eq(write_result.unwrap_err(), Closed)

  let flush_result = stream.flush()
  assert_true(flush_result is Err(_))
  assert_eq(flush_result.unwrap_err(), Closed)
}

///|
test "TcpStream optional methods default implementations" {
  let stream = TcpStream::new("example.com", 80)
  let _ = stream.open()
  
  // get_timeout defaults to 0
  assert_eq(stream.get_timeout(), 0)
  
  // read_ready defaults to true
  assert_true(stream.read_ready())
  
  // has_buffered_input defaults to false
  assert_false(stream.has_buffered_input())
  
  // wait_readable defaults to read_ready
  let wait_result = stream.wait_readable(1000)
  assert_true(wait_result is Ok(_))
  assert_true(wait_result.unwrap())
  
  // is_alive defaults to peer_addr check
  assert_true(stream.is_alive())
  
  // set_body_limit is a no-op
  stream.set_body_limit(1024)
  
  // peer_addr and local_addr work
  let peer = stream.peer_addr()
  assert_true(peer is Ok(_))
  assert_eq(peer.unwrap(), "example.com:80")
  
  let _ = stream.local_addr()
  assert_true(stream.local_addr() is Ok(_))
  assert_eq(stream.local_addr().unwrap(), "0.0.0.0:0")
}

///|
test "TcpStream set_timeout on open stream" {
  let stream = TcpStream::new("example.com", 80)
  let _ = stream.open()
  
  let result = stream.set_timeout(5000)
  assert_true(result is Ok(_))
  
  // get_timeout still returns 0 (not stored in placeholder)
  assert_eq(stream.get_timeout(), 0)
}

///|
test "TcpStream set_timeout on closed stream fails" {
  let stream = TcpStream::new("example.com", 80)
  // Not opened
  
  let result = stream.set_timeout(5000)
  assert_true(result is Err(_))
  assert_eq(result.unwrap_err(), Closed)
}
