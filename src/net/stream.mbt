/// Error types for network operations
pub enum NetError {
  ConnectionFailed(String)
  ReadError(String)
  WriteError(String)
  Timeout
  Closed
  InvalidAddress(String)
  IoError(String)
}

/// Stream interface for reading and writing bytes
pub trait Stream {
  // Read data into buffer, returns number of bytes read
  fn read(self : Stream, buf : Buffer) -> Result[Int, NetError]
  
  // Write data from buffer, returns number of bytes written
  fn write(self : Stream, buf : Buffer) -> Result[Int, NetError]
  
  // Flush any buffered data
  fn flush(self : Stream) -> Result[Unit, NetError]
  
  // Close the stream
  fn close(self : Stream) -> Result[Unit, NetError]
  
  // Optional: Set read/write timeout
  fn set_timeout(self : Stream, timeout_ms : Int) -> Result[Unit, NetError]
  
  // Optional: Get peer address
  fn peer_addr(self : Stream) -> Result[String, NetError]
  
  // Optional: Get local address
  fn local_addr(self : Stream) -> Result[String, NetError]
}

/// TCP Stream implementation
pub struct TcpStream {
  // In a real implementation, this would hold the actual socket handle
  host : String
  port : Int
  mut is_open : Bool
}

pub fn TcpStream::new(host : String, port : Int) -> TcpStream {
  TcpStream::{ host, port, is_open: false }
}

pub fn TcpStream::open(self : TcpStream) -> Result[TcpStream, NetError] {
  // In real implementation, this would open a TCP connection
  self.is_open = true
  Ok(self)
}

pub impl Stream for TcpStream with fn read(self : TcpStream, buf : Buffer) -> Result[Int, NetError] {
  if not(self.is_open) {
    return Err(Closed)
  }
  // Placeholder implementation
  Ok(0)
}

pub impl Stream for TcpStream with fn write(self : TcpStream, buf : Buffer) -> Result[Int, NetError] {
  if not(self.is_open) {
    return Err(Closed)
  }
  // Placeholder implementation
  Ok(buf.length())
}

pub impl Stream for TcpStream with fn flush(self : TcpStream) -> Result[Unit, NetError] {
  if not(self.is_open) {
    return Err(Closed)
  }
  Ok(())
}

pub impl Stream for TcpStream with fn close(self : TcpStream) -> Result[Unit, NetError] {
  self.is_open = false
  Ok(())
}

pub impl Stream for TcpStream with fn set_timeout(self : TcpStream, timeout_ms : Int) -> Result[Unit, NetError] {
  if not(self.is_open) {
    return Err(Closed)
  }
  Ok(())
}

pub impl Stream for TcpStream with fn peer_addr(self : TcpStream) -> Result[String, NetError] {
  if not(self.is_open) {
    return Err(Closed)
  }
  Ok(self.host + ":" + self.port.to_string())
}

pub impl Stream for TcpStream with fn local_addr(self : TcpStream) -> Result[String, NetError] {
  if not(self.is_open) {
    return Err(Closed)
  }
  Ok("0.0.0.0:0")
}
