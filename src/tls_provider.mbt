/// TLS Provider interface
pub trait TlsProvider {
  // Create a new TLS client context
  fn new_client(Self, TlsConfig) -> Result[&TlsClientCtx, TlsError]
}

/// TLS Client Context
pub trait TlsClientCtx {
  // Perform TLS handshake on the underlying stream
  fn connect(Self, &Stream) -> Result[&Stream, TlsError]

  // Server name configured for this client context
  fn server_name(Self) -> String
}

/// Mock TLS Provider (placeholder for actual implementation)
pub struct MockTlsProvider {
  name : String
} derive(Eq, Debug)

pub fn MockTlsProvider::new(name : String) -> MockTlsProvider {
  MockTlsProvider::{ name }
}

pub impl TlsProvider for MockTlsProvider with fn new_client(self : MockTlsProvider, config : TlsConfig) -> Result[&TlsClientCtx, TlsError] {
  // Mock provider: validate the configuration and return a passthrough
  // context. Real handshakes come from OpenSslTlsProvider on native targets.
  let _ = self
  match config.validate() {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  let ctx = MockTlsClientCtx::{ config, is_connected: false }
  Ok(ctx)
}

/// Mock TLS Client Context
pub struct MockTlsClientCtx {
  config : TlsConfig
  mut is_connected : Bool
}

pub impl TlsClientCtx for MockTlsClientCtx with fn server_name(self : MockTlsClientCtx) -> String {
  self.config.server_name
}

pub impl TlsClientCtx for MockTlsClientCtx with fn connect(self : MockTlsClientCtx, underlying : &Stream) -> Result[&Stream, TlsError] {
  // Mock provider: no handshake, the stream is wrapped untouched.
  if self.is_connected {
    return Err(ProtocolError("TLS context is already connected"))
  }
  if self.config.verify == SkipVerification {
    println("WARNING: TLS certificate verification is disabled!")
  }

  self.is_connected = true
  let tls_stream = TlsStream::{ underlying, config: self.config, is_open: true }
  Ok(tls_stream)
}

/// TLS Stream wrapper
pub struct TlsStream {
  underlying : &Stream
  config : TlsConfig
  mut is_open : Bool
}

pub impl Stream for TlsStream with fn read(self : TlsStream, buf : Buffer) -> Result[Int, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  // Mock provider: no decryption, bytes pass straight through.
  self.underlying.read(buf)
}

pub impl Stream for TlsStream with fn write(self : TlsStream, buf : Buffer) -> Result[Int, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  // Mock provider: no encryption, bytes pass straight through.
  self.underlying.write(buf)
}

pub impl Stream for TlsStream with fn flush(self : TlsStream) -> Result[Unit, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  self.underlying.flush()
}

pub impl Stream for TlsStream with fn close(self : TlsStream) -> Result[Unit, NetError] {
  if !self.is_open {
    return Ok(())
  }
  self.is_open = false
  self.underlying.close()
}

pub impl Stream for TlsStream with fn set_timeout(self : TlsStream, timeout_ms : Int) -> Result[Unit, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  self.underlying.set_timeout(timeout_ms)
}

pub impl Stream for TlsStream with fn peer_addr(self : TlsStream) -> Result[String, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  self.underlying.peer_addr()
}

pub impl Stream for TlsStream with fn local_addr(self : TlsStream) -> Result[String, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  self.underlying.local_addr()
}

/// Global TLS provider instance.
#cfg(target="native")
pub fn default_tls_provider() -> OpenSslTlsProvider {
  OpenSslTlsProvider::new()
}

#cfg(not(target="native"))
const TLS_TRANSPORT_UNAVAILABLE : String =
  "TLS transport unavailable on this target; build with --target native"

/// TLS provider for targets without a native TLS implementation. It refuses to
/// create a client context instead of silently passing plaintext through the
/// mock provider, which would make "https" connections unencrypted.
#cfg(not(target="native"))
pub struct UnavailableTlsProvider {} derive(Eq, Debug)

#cfg(not(target="native"))
pub fn UnavailableTlsProvider::new() -> UnavailableTlsProvider {
  UnavailableTlsProvider::{}
}

#cfg(not(target="native"))
pub impl TlsProvider for UnavailableTlsProvider with fn new_client(
  self : UnavailableTlsProvider,
  config : TlsConfig,
) -> Result[&TlsClientCtx, TlsError] {
  let _ = self
  let _ = config
  Err(InvalidConfig(TLS_TRANSPORT_UNAVAILABLE))
}

/// Global TLS provider instance.
#cfg(not(target="native"))
pub fn default_tls_provider() -> UnavailableTlsProvider {
  UnavailableTlsProvider::new()
}
