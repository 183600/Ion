test "TcpStream basic operations" {
  let stream = TcpStream::new("example.com", 80)
  assert_eq(stream.host, "example.com")
  assert_eq(stream.port, 80)
  assert_eq(stream.is_open, false)
}

test "TcpStream open and close" {
  let stream = TcpStream::new("example.com", 80)
  let result = stream.open()
  assert_true(result is Ok(_))
  assert_eq(stream.is_open, true)
  
  let close_result = stream.close()
  assert_true(close_result is Ok(_))
  assert_eq(stream.is_open, false)
}

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
