/// Datagram (connectionless) transport interface.
///
/// The `Stream` abstraction models reliable, ordered byte streams. Some
/// protocols need the opposite: DNS answers a query with a single packet that
/// may arrive from an unexpected source, and the transport has to report the
/// sender of every packet so the caller can reject spoofed replies.
///
/// The interface stays deliberately small so that every platform can provide
/// an implementation: the native build uses POSIX datagram sockets, and other
/// targets can supply their own transport (for example a tunnel over a
/// stream-based protocol).

/// A datagram received from the network.
pub struct DatagramPacket {
  /// Number of bytes copied into the caller's buffer.
  length : Int
  /// IP address of the sender, without a port suffix.
  address : String
  /// Port of the sender.
  port : Int
} derive(Eq, Debug)

/// Datagram transport used by resolvers and other request/response protocols.
pub trait Datagram {
  /// Send `payload` to `address:port`.
  fn send_to(Self, Bytes, String, Int) -> Result[Unit, NetError]

  /// Receive a single datagram into `buffer`.
  ///
  /// Implementations report the sender so the caller can discard replies that
  /// did not come from the peer it queried.
  fn receive_from(Self, Buffer) -> Result[DatagramPacket, NetError]

  /// Close the socket. Closing twice is not an error.
  fn close(Self) -> Result[Unit, NetError]

  /// Restrict the socket to a single peer.
  ///
  /// A connected socket only accepts datagrams from that peer, which is the
  /// strongest defense against spoofed answers. Transports that cannot
  /// connect keep the default implementation, and the caller verifies the
  /// reported sender instead.
  fn connect(Self, String, Int) -> Result[Unit, NetError] = _

  /// Bound blocking sends and receives. Zero clears the deadline.
  fn set_timeout(Self, Int) -> Result[Unit, NetError] = _

  /// The local port the socket is bound to, or zero when it is not bound.
  fn local_port(Self) -> Int = _
}

impl Datagram with fn connect(_self, _address, _port) {
  Err(NetError::IoError("Datagram transport cannot restrict its peer"))
}

impl Datagram with fn set_timeout(_self, _timeout_ms) {
  Ok(())
}

impl Datagram with fn local_port(_self) {
  0
}
