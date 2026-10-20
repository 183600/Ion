/// Dialer interface for establishing connections
pub trait Dialer {
  // Dial a TCP connection to host:port
  fn dial_tcp(Self, String, Int) -> Result[&Stream, NetError]

  // Optional: Resolve hostname to IP addresses
  fn resolve(Self, String) -> Result[List[String], NetError]
}

fn valid_tcp_host(host : String) -> Bool {
  if host.length() == 0 {
    return false
  }
  for ch in host {
    if ch <= ' ' || ch == '\u{7f}' || ch == '/' || ch == '\\' || ch == '?' ||
      ch == '#' || ch == '@' || ch == ',' {
      return false
    }
  }
  true
}

fn valid_tcp_port(port : Int) -> Bool {
  port >= 1 && port <= 65535
}

/// TCP Dialer implementation
pub struct TcpDialer {
  timeout_ms : Int
} derive(Eq, Debug)

pub fn TcpDialer::new() -> TcpDialer {
  TcpDialer::{ timeout_ms: 30000 }
}

pub fn TcpDialer::with_timeout(timeout_ms : Int) -> TcpDialer {
  TcpDialer::{ timeout_ms }
}

pub impl Dialer for TcpDialer with fn dial_tcp(self : TcpDialer, host : String, port : Int) -> Result[&Stream, NetError] {
  // In real implementation, this would perform actual TCP connection
  let _ = self
  if !valid_tcp_host(host) {
    return Err(NetError::InvalidAddress("Invalid host"))
  }
  if !valid_tcp_port(port) {
    return Err(NetError::InvalidAddress("Invalid port"))
  }
  let stream = TcpStream::new(host, port)
  match stream.open() {
    Ok(stream) => Ok(stream)
    Err(err) => Err(err)
  }
}

pub impl Dialer for TcpDialer with fn resolve(self : TcpDialer, host : String) -> Result[List[String], NetError] {
  // In real implementation, this would perform DNS resolution
  // For now, return the host as-is (assuming it's already an IP or hostname)
  let _ = self
  if !valid_tcp_host(host) {
    return Err(NetError::InvalidAddress("Invalid host"))
  }
  Ok(@list.List([host]))
}

/// Global dialer instance for convenience
pub fn default_dialer() -> TcpDialer {
  TcpDialer::new()
}
