/// Dialer interface for establishing connections
pub trait Dialer {
  // Dial a TCP connection to host:port
  fn dial_tcp(self : Dialer, host : String, port : Int) -> Result[Stream, NetError]
  
  // Optional: Resolve hostname to IP addresses
  fn resolve(self : Dialer, host : String) -> Result[List[String], NetError]
}

/// TCP Dialer implementation
pub struct TcpDialer {
  mut timeout_ms : Int
}

pub fn TcpDialer::new() -> TcpDialer {
  TcpDialer::{ timeout_ms: 30000 }
}

pub fn TcpDialer::with_timeout(timeout_ms : Int) -> TcpDialer {
  TcpDialer::{ timeout_ms }
}

pub impl Dialer for TcpDialer with fn dial_tcp(self : TcpDialer, host : String, port : Int) -> Result[Stream, NetError] {
  // In real implementation, this would perform actual TCP connection
  let stream = TcpStream::new(host, port)
  stream.open()? |> Ok
}

pub impl Dialer for TcpDialer with fn resolve(self : TcpDialer, host : String) -> Result[List[String], NetError] {
  // In real implementation, this would perform DNS resolution
  // For now, return the host as-is (assuming it's already an IP or hostname)
  Ok(List::[host])
}

/// Global dialer instance for convenience
pub fn default_dialer() -> TcpDialer {
  TcpDialer::new()
}
