/// Native TCP transport backed by POSIX sockets.

#borrow(host)
extern "C" fn feather_tcp_connect(host : Bytes, port : Int, timeout_ms : Int) -> Int = "feather_tcp_connect"

#borrow(buffer)
extern "C" fn feather_tcp_read(fd : Int, buffer : Bytes, capacity : Int) -> Int = "feather_tcp_read"

#borrow(buffer)
extern "C" fn feather_tcp_write(fd : Int, buffer : Bytes, length : Int) -> Int = "feather_tcp_write"

extern "C" fn feather_tcp_close(fd : Int) -> Int = "feather_tcp_close"

extern "C" fn feather_tcp_set_timeout(fd : Int, timeout_ms : Int) -> Int = "feather_tcp_set_timeout"

extern "C" fn feather_tcp_is_alive(fd : Int) -> Int = "feather_tcp_is_alive"

#borrow(host)
#borrow(output)
extern "C" fn feather_tcp_resolve(host : Bytes, output : Bytes, capacity : Int) -> Int = "feather_tcp_resolve"

const NATIVE_TCP_READ_CHUNK : Int = 8192

fn native_tcp_error(code : Int, operation : String) -> NetError {
  if code < 0 {
    return NetError::IoError(operation + " failed (code " + code.to_string() + ")")
  }
  match code {
    11 | 110 | 115 => Timeout
    101 | 111 | 113 => ConnectionFailed(operation + " failed (errno " + code.to_string() + ")")
    22 => InvalidAddress(operation + " failed: invalid address")
    _ => IoError(operation + " failed (errno " + code.to_string() + ")")
  }
}

fn native_tcp_address_error(code : Int) -> NetError {
  if code >= 10000 {
    return InvalidAddress("DNS resolution failed (code " + (code - 10000).to_string() + ")")
  }
  native_tcp_error(code, "TCP connection")
}

/// A TCP stream backed by a native operating-system socket.
pub struct NativeTcpStream {
  mut fd : Int
  host : String
  port : Int
  mut is_open : Bool
  mut timeout_ms : Int
} derive(Eq, Debug)

pub fn NativeTcpStream::new(host : String, port : Int) -> NativeTcpStream {
  NativeTcpStream::with_timeout(host, port, 30000)
}

pub fn NativeTcpStream::with_timeout(
  host : String,
  port : Int,
  timeout_ms : Int,
) -> NativeTcpStream {
  NativeTcpStream::{
    fd: -1,
    host,
    port,
    is_open: false,
    timeout_ms: if timeout_ms < 0 { 0 } else { timeout_ms },
  }
}

pub fn NativeTcpStream::open(self : NativeTcpStream) -> Result[NativeTcpStream, NetError] {
  if self.is_open {
    return Ok(self)
  }
  if !valid_tcp_host(self.host) {
    return Err(NetError::InvalidAddress("Invalid host"))
  }
  if !valid_tcp_port(self.port) {
    return Err(NetError::InvalidAddress("Invalid port"))
  }
  let fd = feather_tcp_connect(@utf8.encode(self.host), self.port, self.timeout_ms)
  if fd < 0 {
    return Err(native_tcp_address_error(-fd))
  }
  self.fd = fd
  self.is_open = true
  Ok(self)
}

pub impl Stream for NativeTcpStream with fn read(
  self : NativeTcpStream,
  buf : Buffer,
) -> Result[Int, NetError] {
  if !self.is_open || self.fd < 0 {
    return Err(NetError::Closed)
  }
  let temporary = Bytes::new(NATIVE_TCP_READ_CHUNK)
  let count = feather_tcp_read(self.fd, temporary, NATIVE_TCP_READ_CHUNK)
  if count < 0 {
    return Err(native_tcp_error(-count, "TCP read"))
  }
  if count > 0 {
    buf.write_bytes(temporary.exact_view(start=0, end=count))
  }
  Ok(count)
}

pub impl Stream for NativeTcpStream with fn write(
  self : NativeTcpStream,
  buf : Buffer,
) -> Result[Int, NetError] {
  if !self.is_open || self.fd < 0 {
    return Err(NetError::Closed)
  }
  let data = buf.to_bytes()
  if data.length() == 0 {
    return Ok(0)
  }
  let count = feather_tcp_write(self.fd, data, data.length())
  if count < 0 {
    return Err(native_tcp_error(-count, "TCP write"))
  }
  Ok(count)
}

pub impl Stream for NativeTcpStream with fn flush(
  self : NativeTcpStream,
) -> Result[Unit, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Ok(())
}

pub impl Stream for NativeTcpStream with fn close(
  self : NativeTcpStream,
) -> Result[Unit, NetError] {
  if !self.is_open {
    return Ok(())
  }
  let fd = self.fd
  self.fd = -1
  self.is_open = false
  let result = feather_tcp_close(fd)
  if result < 0 {
    return Err(native_tcp_error(-result, "TCP close"))
  }
  Ok(())
}

pub impl Stream for NativeTcpStream with fn set_timeout(
  self : NativeTcpStream,
  timeout_ms : Int,
) -> Result[Unit, NetError] {
  if !self.is_open || self.fd < 0 {
    return Err(NetError::Closed)
  }
  let timeout_ms = if timeout_ms < 0 { 0 } else { timeout_ms }
  let result = feather_tcp_set_timeout(self.fd, timeout_ms)
  if result < 0 {
    return Err(native_tcp_error(-result, "TCP timeout"))
  }
  self.timeout_ms = timeout_ms
  Ok(())
}

pub impl Stream for NativeTcpStream with fn peer_addr(
  self : NativeTcpStream,
) -> Result[String, NetError] {
  if !self.is_open || self.fd < 0 {
    return Err(NetError::Closed)
  }
  if feather_tcp_is_alive(self.fd) <= 0 {
    return Err(NetError::Closed)
  }
  let host = if self.host.contains(":") && !(self.host.has_prefix("[") && self.host.has_suffix("]")) {
    "[" + self.host + "]"
  } else {
    self.host
  }
  Ok(host + ":" + self.port.to_string())
}

pub impl Stream for NativeTcpStream with fn local_addr(
  self : NativeTcpStream,
) -> Result[String, NetError] {
  if !self.is_open || self.fd < 0 {
    return Err(NetError::Closed)
  }
  Ok("0.0.0.0:0")
}

/// TCP dialer that performs real native DNS resolution and socket connections.
pub struct NativeTcpDialer {
  timeout_ms : Int
} derive(Eq, Debug)

pub fn NativeTcpDialer::new() -> NativeTcpDialer {
  NativeTcpDialer::{ timeout_ms: 30000 }
}

pub fn NativeTcpDialer::with_timeout(timeout_ms : Int) -> NativeTcpDialer {
  NativeTcpDialer::{ timeout_ms: if timeout_ms < 0 { 0 } else { timeout_ms } }
}

pub impl Dialer for NativeTcpDialer with fn dial_tcp(
  self : NativeTcpDialer,
  host : String,
  port : Int,
) -> Result[&Stream, NetError] {
  let stream = NativeTcpStream::with_timeout(host, port, self.timeout_ms)
  match stream.open() {
    Ok(stream) => Ok(stream)
    Err(err) => Err(err)
  }
}

pub impl Dialer for NativeTcpDialer with fn resolve(
  self : NativeTcpDialer,
  host : String,
) -> Result[List[String], NetError] {
  let _ = self
  if !valid_tcp_host(host) {
    return Err(NetError::InvalidAddress("Invalid host"))
  }
  let capacity = 8192
  let output = Bytes::new(capacity)
  let length = feather_tcp_resolve(@utf8.encode(host), output, capacity)
  if length < 0 {
    return Err(native_tcp_address_error(-length))
  }
  let text = @utf8.decode_lossy(output.exact_view(start=0, end=length))
  let addresses : Array[String] = []
  for part in text.split("\n") {
    if part.length() > 0 {
      addresses.push(part.to_owned())
    }
  }
  if addresses.length() == 0 {
    return Err(NetError::InvalidAddress("DNS resolution returned no addresses"))
  }
  Ok(@list.List(addresses[:]))
}
