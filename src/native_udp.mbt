///|
/// Native UDP transport backed by POSIX datagram sockets.
///
/// The socket is opened in dual-stack mode when the host supports it, so a
/// single descriptor reaches both IPv4 and IPv6 peers. Datagram reads report
/// the sender, which lets callers reject replies that did not come from the
/// peer they queried.
extern "C" fn feather_udp_open() -> Int32 = "feather_udp_open"

///|
extern "C" fn feather_udp_bind(fd : Int32, port : Int32) -> Int32 = "feather_udp_bind"

///|
#borrow(host)
extern "C" fn feather_udp_connect(
  fd : Int32,
  host : Bytes,
  port : Int32,
) -> Int32 = "feather_udp_connect"

///|
#borrow(payload)
extern "C" fn feather_udp_send(
  fd : Int32,
  payload : Bytes,
  length : Int32,
) -> Int32 = "feather_udp_send"

///|
#borrow(payload, host)
extern "C" fn feather_udp_send_to(
  fd : Int32,
  payload : Bytes,
  length : Int32,
  host : Bytes,
  port : Int32,
) -> Int32 = "feather_udp_send_to"

///|
#borrow(buffer, output)
extern "C" fn feather_udp_recv_from(
  fd : Int32,
  buffer : Bytes,
  capacity : Int32,
  output : Bytes,
  output_capacity : Int32,
) -> Int32 = "feather_udp_recv_from"

///|
extern "C" fn feather_udp_set_timeout(fd : Int32, timeout_ms : Int32) -> Int32 = "feather_udp_set_timeout"

///|
extern "C" fn feather_udp_close(fd : Int32) -> Int32 = "feather_udp_close"

///|
extern "C" fn feather_udp_local_port(fd : Int32) -> Int32 = "feather_udp_local_port"

///|
/// The largest datagram the transport accepts. UDP payloads cannot exceed
/// 65507 bytes on IPv4, and the receive buffer is sized for the maximum.
const NATIVE_UDP_MAX_DATAGRAM : Int32 = 65535

///|
/// The capacity of the scratch buffer that receives the peer description.
const NATIVE_UDP_PEER_CAPACITY : Int32 = 128

///|
/// Read a NUL-terminated string from a buffer filled by the native stub.
fn native_udp_read_c_string(data : Bytes) -> String {
  let mut end = 0
  while end < data.length() && data[end] != b'\x00' {
    end = end + 1
  }
  @utf8.decode_lossy(data.exact_view(start=0, end~))
}

///|
/// Split the `host:port` peer description produced by the native stub into its
/// address and port parts. IPv6 literals are bracketed, and their optional
/// scope identifier is part of the address.
fn native_udp_split_peer(peer : String) -> (String, Int32) {
  match peer.rev_find(":") {
    Some(index) => {
      let address = if peer.has_prefix("[") && index > 1 {
        peer[1:index - 1].to_owned()
      } else {
        peer[0:index].to_owned()
      }
      let port = @string.parse_int(peer[index + 1:]) catch { _ => 0 }
      (address, port)
    }
    None => (peer, 0)
  }
}

///|
/// A UDP socket backed by the native operating system.
#derive(Eq, Debug)
pub struct NativeUdpDatagram {
  mut fd : Int32
  mut is_open : Bool
  mut timeout_ms : Int32
  mut connected : Bool
}

///|
/// Open a native UDP socket.
pub fn NativeUdpDatagram::open() -> Result[NativeUdpDatagram, NetError] {
  NativeUdpDatagram::with_timeout(30000)
}

///|
/// Open a native UDP socket that applies `timeout_ms` to blocking sends and
/// receives.
pub fn NativeUdpDatagram::with_timeout(
  timeout_ms : Int32,
) -> Result[NativeUdpDatagram, NetError] {
  let timeout_ms = if timeout_ms < 0 { 0 } else { timeout_ms }
  let fd = feather_udp_open()
  if fd < 0 {
    return Err(native_tcp_error(-fd, "UDP open"))
  }
  // Binding to an ephemeral port up front makes the source port known before
  // the first datagram is sent, which callers such as resolvers rely on.
  let bound = feather_udp_bind(fd, 0)
  if bound < 0 {
    let error = native_tcp_error(-bound, "UDP bind")
    let _ = feather_udp_close(fd)
    return Err(error)
  }
  let datagram = NativeUdpDatagram::{
    fd,
    is_open: true,
    timeout_ms,
    connected: false,
  }
  if timeout_ms > 0 {
    match datagram.set_timeout(timeout_ms) {
      Ok(_) => ()
      Err(err) => {
        let _ = datagram.close()
        return Err(err)
      }
    }
  }
  Ok(datagram)
}

///|
pub impl Datagram for NativeUdpDatagram with fn send_to(
  self : NativeUdpDatagram,
  payload : Bytes,
  address : String,
  port : Int32,
) -> Result[Unit, NetError] {
  if !self.is_open || self.fd < 0 {
    return Err(NetError::Closed)
  }
  if port < 1 || port > 65535 {
    return Err(NetError::InvalidAddress("Invalid port"))
  }
  if payload.length() > NATIVE_UDP_MAX_DATAGRAM {
    return Err(NetError::IoError("UDP datagram is too large"))
  }
  let sent = if self.connected {
    // A connected socket only accepts datagrams from its peer, and the
    // operating system rejects `sendto` with a destination address.
    feather_udp_send(self.fd, payload, payload.length())
  } else {
    feather_udp_send_to(
      self.fd,
      payload,
      payload.length(),
      @utf8.encode(address),
      port,
    )
  }
  if sent < 0 {
    return Err(native_tcp_error(-sent, "UDP send"))
  }
  Ok(())
}

///|
pub impl Datagram for NativeUdpDatagram with fn receive_from(
  self : NativeUdpDatagram,
  buffer : Buffer,
) -> Result[DatagramPacket, NetError] {
  if !self.is_open || self.fd < 0 {
    return Err(NetError::Closed)
  }
  let temporary = Bytes::new(NATIVE_UDP_MAX_DATAGRAM)
  let peer = Bytes::new(NATIVE_UDP_PEER_CAPACITY)
  let count = feather_udp_recv_from(
    self.fd,
    temporary,
    NATIVE_UDP_MAX_DATAGRAM,
    peer,
    NATIVE_UDP_PEER_CAPACITY,
  )
  if count < 0 {
    return Err(native_tcp_error(-count, "UDP receive"))
  }
  buffer.write_bytes(temporary.exact_view(start=0, end=count))
  let (address, port) = native_udp_split_peer(native_udp_read_c_string(peer))
  Ok(DatagramPacket::{ length: count, address, port, })
}

///|
pub impl Datagram for NativeUdpDatagram with fn connect(
  self : NativeUdpDatagram,
  address : String,
  port : Int32,
) -> Result[Unit, NetError] {
  if !self.is_open || self.fd < 0 {
    return Err(NetError::Closed)
  }
  if port < 1 || port > 65535 {
    return Err(NetError::InvalidAddress("Invalid port"))
  }
  let result = feather_udp_connect(self.fd, @utf8.encode(address), port)
  if result < 0 {
    return Err(native_tcp_error(-result, "UDP connect"))
  }
  self.connected = true
  Ok(())
}

///|
pub impl Datagram for NativeUdpDatagram with fn set_timeout(
  self : NativeUdpDatagram,
  timeout_ms : Int32,
) -> Result[Unit, NetError] {
  if !self.is_open || self.fd < 0 {
    return Err(NetError::Closed)
  }
  let timeout_ms = if timeout_ms < 0 { 0 } else { timeout_ms }
  let result = feather_udp_set_timeout(self.fd, timeout_ms)
  if result < 0 {
    return Err(native_tcp_error(-result, "UDP timeout"))
  }
  self.timeout_ms = timeout_ms
  Ok(())
}

///|
pub impl Datagram for NativeUdpDatagram with fn local_port(
  self : NativeUdpDatagram,
) -> Int32 {
  if !self.is_open || self.fd < 0 {
    return 0
  }
  let port = feather_udp_local_port(self.fd)
  if port < 0 {
    0
  } else {
    port
  }
}

///|
pub impl Datagram for NativeUdpDatagram with fn close(self : NativeUdpDatagram) -> Result[
  Unit,
  NetError,
] {
  if !self.is_open {
    return Ok(())
  }
  let fd = self.fd
  self.fd = -1
  self.is_open = false
  self.connected = false
  let result = feather_udp_close(fd)
  if result < 0 {
    return Err(native_tcp_error(-result, "UDP close"))
  }
  Ok(())
}

///|
/// Global datagram instance for convenience.
#cfg(target="native")
pub fn default_datagram() -> NativeUdpDatagram {
  NativeUdpDatagram::with_timeout(5000).unwrap()
}

///|
#cfg(not(target="native"))
const UDP_TRANSPORT_UNAVAILABLE : String = "UDP transport unavailable on this target; build with --target native"

///|
/// Datagram for targets without a socket transport.
#cfg(not(target="native"))
#derive(Eq, Debug)
pub struct UnavailableDatagram {}

///|
#cfg(not(target="native"))
pub fn UnavailableDatagram::new() -> UnavailableDatagram {
  UnavailableDatagram::{ }
}

///|
#cfg(not(target="native"))
impl Datagram for UnavailableDatagram with fn send_to(
  self : UnavailableDatagram,
  _payload : Bytes,
  _address : String,
  _port : Int32,
) -> Result[Unit, NetError] {
  let _ = self
  Err(NetError::ConnectionFailed(UDP_TRANSPORT_UNAVAILABLE))
}

///|
#cfg(not(target="native"))
impl Datagram for UnavailableDatagram with fn receive_from(
  self : UnavailableDatagram,
  _buffer : Buffer,
) -> Result[DatagramPacket, NetError] {
  let _ = self
  Err(NetError::ConnectionFailed(UDP_TRANSPORT_UNAVAILABLE))
}

///|
#cfg(not(target="native"))
impl Datagram for UnavailableDatagram with fn close(
  self : UnavailableDatagram,
) -> Result[Unit, NetError] {
  let _ = self
  Err(NetError::ConnectionFailed(UDP_TRANSPORT_UNAVAILABLE))
}

///|
#cfg(not(target="native"))
pub fn default_datagram() -> UnavailableDatagram {
  UnavailableDatagram::new()
}
