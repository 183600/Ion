/// Error types for network operations
pub enum NetError {
  ConnectionFailed(String)
  ReadError(String)
  WriteError(String)
  Timeout
  Closed
  InvalidAddress(String)
  IoError(String)
} derive(Eq, Debug)

/// Stream interface for reading and writing bytes
pub trait Stream {
  // Read data into buffer, returns number of bytes read
  fn read(Self, Buffer) -> Result[Int, NetError]

  // Write data from buffer, returns number of bytes written
  fn write(Self, Buffer) -> Result[Int, NetError]

  // Flush any buffered data
  fn flush(Self) -> Result[Unit, NetError]

  // Close the stream
  fn close(Self) -> Result[Unit, NetError]

  // Optional: Set read/write timeout
  fn set_timeout(Self, Int) -> Result[Unit, NetError]

  // Optional: Get peer address
  fn peer_addr(Self) -> Result[String, NetError]

  // Optional: Get local address
  fn local_addr(Self) -> Result[String, NetError]

  // Optional: authorize reading more body bytes for an explicit caller limit.
  fn set_body_limit(Self, Int) -> Unit = _
}

impl Stream with fn set_body_limit(_self, _limit) {
  ()
}

/// Placeholder TCP stream kept for API compatibility and tests. It validates
/// the target address and tracks open state, but performs no socket I/O at
/// all: reads report EOF and writes report success without sending bytes.
/// Real sockets come from `NativeTcpStream` (via `default_dialer()`).
pub struct TcpStream {
  // Target description only; no socket handle is ever opened.
  host : String
  port : Int
  mut is_open : Bool
} derive(Eq, Debug)

pub fn TcpStream::new(host : String, port : Int) -> TcpStream {
  TcpStream::{ host, port, is_open: false }
}

pub fn TcpStream::open(self : TcpStream) -> Result[TcpStream, NetError] {
  if self.is_open {
    return Ok(self)
  }
  if !valid_tcp_host(self.host) {
    return Err(NetError::InvalidAddress("Invalid host"))
  }
  if !valid_tcp_port(self.port) {
    return Err(NetError::InvalidAddress("Invalid port"))
  }
  // Validation only: no socket is opened for a placeholder stream.
  self.is_open = true
  Ok(self)
}

pub impl Stream for TcpStream with fn read(self : TcpStream, buf : Buffer) -> Result[Int, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  // Placeholder stream: reads always report EOF.
  let _ = buf
  Ok(0)
}

pub impl Stream for TcpStream with fn write(self : TcpStream, buf : Buffer) -> Result[Int, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  // Placeholder stream: writes report success without sending anything.
  Ok(buf.length())
}

pub impl Stream for TcpStream with fn flush(self : TcpStream) -> Result[Unit, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Ok(())
}

pub impl Stream for TcpStream with fn close(self : TcpStream) -> Result[Unit, NetError] {
  self.is_open = false
  Ok(())
}

pub impl Stream for TcpStream with fn set_timeout(self : TcpStream, timeout_ms : Int) -> Result[Unit, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  let _ = timeout_ms
  Ok(())
}

pub impl Stream for TcpStream with fn peer_addr(self : TcpStream) -> Result[String, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  let host = if self.host.contains(":") && !(self.host.has_prefix("[") && self.host.has_suffix("]")) {
    "[" + self.host + "]"
  } else {
    self.host
  }
  Ok(host + ":" + self.port.to_string())
}

pub impl Stream for TcpStream with fn local_addr(self : TcpStream) -> Result[String, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Ok("0.0.0.0:0")
}
