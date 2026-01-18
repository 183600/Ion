test "TcpStream basic operations" {
  let stream = TcpStream::new("example.com", 80)
  assert_eq!(stream.host, "example.com")
  assert_eq!(stream.port, 80)
  assert_eq!(stream.is_open, false)
}

test "TcpStream open and close" {
  let stream = TcpStream::new("example.com", 80)
  let result = stream.open()
  assert!(result.is_ok())
  assert_eq!(stream.is_open, true)
  
  let close_result = stream.close()
  assert!(close_result.is_ok())
  assert_eq!(stream.is_open, false)
}

test "TcpStream operations on closed stream" {
  let stream = TcpStream::new("example.com", 80)
  let buf = Buffer::make(1024)
  
  let read_result = stream.read(buf)
  assert!(read_result.is_err())
  assert_eq!(read_result.unwrap_err(), Closed)
  
  let write_result = stream.write(buf)
  assert!(write_result.is_err())
  assert_eq!(write_result.unwrap_err(), Closed)
  
  let flush_result = stream.flush()
  assert!(flush_result.is_err())
  assert_eq!(flush_result.unwrap_err(), Closed)
}
