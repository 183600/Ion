/// Error types for network operations
pub enum NetError {
  IoError(String)
  ConnectionRefused
  ConnectionReset
  ConnectionAborted
  Timeout
  InvalidAddress(String)
  UnknownError(String)
}

/// Trait for readable/writable byte streams
pub trait Stream {
  // Read data into buffer, returns number of bytes read or error
  fn read(self : Stream, buf : Buffer) -> Result[Int, NetError]
  
  // Write data from buffer, returns number of bytes written or error
  fn write(self : Stream, buf : Buffer) -> Result[Int, NetError]
  
  // Flush any buffered data
  fn flush(self : Stream) -> Result[Unit, NetError]
  
  // Close the stream
  fn close(self : Stream) -> Result[Unit, NetError]
  
  // Get peer address if available
  fn peer_addr(self : Stream) -> Result[String, NetError]
  
  // Get local address if available
  fn local_addr(self : Stream) -> Result[String, NetError]
}

/// Mock stream implementation for testing
struct MockStream {
  mut data : Bytes
  mut position : Int
  mut closed : Bool
}

fn MockStream::new(data : Bytes) -> MockStream {
  { data, position: 0, closed: false }
}

fn MockStream::empty() -> MockStream {
  { data: Bytes::new(), position: 0, closed: false }
}

fn MockStream::from_string(s : String) -> MockStream {
  { data: s.to_bytes(), position: 0, closed: false }
}

fn MockStream::with_bytes(data : Bytes) -> MockStream {
  { data, position: 0, closed: false }
}

impl Stream for MockStream {
  fn read(self : MockStream, buf : Buffer) -> Result[Int, NetError] {
    if self.closed {
      return Err(ConnectionReset)
    }
    if self.position >= self.data.length() {
      return Ok(0) // EOF
    }
    let remaining = self.data.length() - self.position
    let to_read = buf.len().min(remaining)
    for i = 0; i < to_read; i = i + 1 {
      buf[i] = self.data[self.position + i]
    }
    self.position = self.position + to_read
    Ok(to_read)
  }
  
  fn write(self : MockStream, buf : Buffer) -> Result[Int, NetError] {
    if self.closed {
      return Err(ConnectionReset)
    }
    // Mock stream just appends to internal buffer for testing
    for i = 0; i < buf.length(); i = i + 1 {
      self.data.push(buf[i])
    }
    Ok(buf.length())
  }
  
  fn flush(self : MockStream) -> Result[Unit, NetError] {
    Ok(())
  }
  
  fn close(self : MockStream) -> Result[Unit, NetError] {
    self.closed = true
    Ok(())
  }
  
  fn peer_addr(self : MockStream) -> Result[String, NetError] {
    Ok("mock.peer.address:1234")
  }
  
  fn local_addr(self : MockStream) -> Result[String, NetError] {
    Ok("mock.local.address:5678")
  }
}

/// TCP stream implementation (placeholder for actual socket implementation)
struct TcpStream {
  mut closed : Bool
  host : String
  port : Int
}

fn TcpStream::new(host : String, port : Int) -> TcpStream {
  { closed: false, host, port }
}

impl Stream for TcpStream {
  fn read(self : TcpStream, buf : Buffer) -> Result[Int, NetError] {
    if self.closed {
      return Err(ConnectionReset)
    }
    // Placeholder - actual implementation would read from socket
    Err(UnknownError("TCP read not implemented yet"))
  }
  
  fn write(self : TcpStream, buf : Buffer) -> Result[Int, NetError] {
    if self.closed {
      return Err(ConnectionReset)
    }
    // Placeholder - actual implementation would write to socket
    Err(UnknownError("TCP write not implemented yet"))
  }
  
  fn flush(self : TcpStream) -> Result[Unit, NetError] {
    if self.closed {
      return Err(ConnectionReset)
    }
    Ok(())
  }
  
  fn close(self : TcpStream) -> Result[Unit, NetError] {
    self.closed = true
    Ok(())
  }
  
  fn peer_addr(self : TcpStream) -> Result[String, NetError] {
    Ok("\{self.host}:\{self.port}")
  }
  
  fn local_addr(self : TcpStream) -> Result[String, NetError] {
    Ok("local.address:0")
  }
}
