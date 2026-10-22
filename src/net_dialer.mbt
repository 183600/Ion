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

#cfg(target="native")
fn decode_zone_percent(zone : String) -> String {
  @utf8.decode_lossy(percent_decode_bytes(zone)[:])
}

#cfg(target="native")
fn decode_ipv6_zone(value : String) -> String {
  match value.find("%") {
    Some(index) => {
      let zone = value[index + 1:].to_owned()
      let zone = if zone.length() > 2 && zone.has_prefix("25") {
        zone[2:].to_owned()
      } else {
        zone
      }
      return value[0:index + 1].to_owned() + decode_zone_percent(zone)
    }
    None => ()
  }
  value
}

#cfg(target="native")
fn tcp_dial_host(host : String) -> String {
  let inner = if host.has_prefix("[") && host.has_suffix("]") {
    host[1:host.length() - 1].to_owned()
  } else {
    host
  }
  if is_ipv6_literal_with_zone(inner) {
    return decode_ipv6_zone(inner)
  }
  host
}

/// Placeholder TCP dialer kept for API compatibility and tests. It validates
/// hosts and returns `TcpStream` values that perform no socket I/O. Real
/// connections come from `NativeTcpDialer` (`default_dialer()` on native
/// targets).
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
  // Placeholder dialer: validation only, no socket is opened.
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
  // Placeholder dialer: no DNS lookup is performed, the host is echoed back.
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

/// Global dialer instance for targets without a socket transport. It fails
/// explicitly instead of returning the placeholder `TcpDialer`, which would
/// only fail later as a confusing HTTP protocol error.
#cfg(not(target="native"))
pub fn default_dialer() -> UnavailableTcpDialer {
  UnavailableTcpDialer::with_timeout(30000)
}

#cfg(not(target="native"))
const TCP_TRANSPORT_UNAVAILABLE : String =
  "TCP transport unavailable on this target; build with --target native"

/// Dialer for targets without a socket transport (js, wasm, wasm-gc). It fails
/// immediately with an explicit transport error instead of dialing the
/// placeholder stream, whose empty reads surface as misleading HTTP protocol
/// errors.
#cfg(not(target="native"))
pub struct UnavailableTcpDialer {
  timeout_ms : Int
} derive(Eq, Debug)

#cfg(not(target="native"))
fn UnavailableTcpDialer::with_timeout(timeout_ms : Int) -> UnavailableTcpDialer {
  UnavailableTcpDialer::{ timeout_ms: if timeout_ms < 0 { 0 } else { timeout_ms } }
}

#cfg(not(target="native"))
impl Dialer for UnavailableTcpDialer with fn dial_tcp(
  self : UnavailableTcpDialer,
  host : String,
  port : Int,
) -> Result[&Stream, NetError] {
  let _ = self
  if !valid_tcp_host(host) {
    return Err(NetError::InvalidAddress("Invalid host"))
  }
  if !valid_tcp_port(port) {
    return Err(NetError::InvalidAddress("Invalid port"))
  }
  Err(NetError::ConnectionFailed(TCP_TRANSPORT_UNAVAILABLE))
}

#cfg(not(target="native"))
impl Dialer for UnavailableTcpDialer with fn resolve(
  self : UnavailableTcpDialer,
  host : String,
) -> Result[List[String], NetError] {
  let _ = self
  if !valid_tcp_host(host) {
    return Err(NetError::InvalidAddress("Invalid host"))
  }
  Err(NetError::ConnectionFailed(TCP_TRANSPORT_UNAVAILABLE))
}
