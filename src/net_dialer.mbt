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
  if host.has_prefix("[") {
    if !host.has_suffix("]") {
      return false
    }
    return is_ip_literal(host[1:host.length() - 1].to_owned())
  }
  if host.contains(":") {
    return is_ip_literal(host)
  }
  valid_url_host_chars(host)
}

fn valid_tcp_port(port : Int) -> Bool {
  port >= 1 && port <= 65535
}

fn tcp_dial_host(host : String) -> String {
  if host.has_prefix("[") && host.has_suffix("]") {
    let inner = host[1:host.length() - 1].to_owned()
    if is_ipv6_literal_with_zone(inner) {
      return inner
    }
  }
  host
}

/// TCP Dialer implementation
pub struct TcpDialer {
  timeout_ms : Int
} derive(Eq, Debug)

pub fn TcpDialer::new() -> TcpDialer {
  TcpDialer::{ timeout_ms: 30000 }
}

pub fn TcpDialer::with_timeout(timeout_ms : Int) -> TcpDialer {
  TcpDialer::{ timeout_ms: if timeout_ms < 0 { 0 } else { timeout_ms } }
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

/// Global dialer instance for convenience.
#cfg(target="native")
pub fn default_dialer() -> NativeTcpDialer {
  NativeTcpDialer::new()
}

/// Global dialer instance for convenience.
#cfg(not(target="native"))
pub fn default_dialer() -> TcpDialer {
  TcpDialer::new()
}
