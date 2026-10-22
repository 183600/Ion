/// Native TLS client provider backed by OpenSSL.

type NativeTlsHandle

#borrow(server_name, alpn, roots, certificate, private_key)
extern "C" fn feather_tls_new(
  server_name : Bytes,
  alpn : Bytes,
  alpn_length : Int,
  verify : Int,
  min_version : Int,
  roots : Bytes,
  roots_length : Int,
  certificate : Bytes,
  certificate_length : Int,
  private_key : Bytes,
  private_key_length : Int,
) -> NativeTlsHandle = "feather_tls_new"

#borrow(tls)
extern "C" fn feather_tls_ready(tls : NativeTlsHandle) -> Int = "feather_tls_ready"

#borrow(tls)
extern "C" fn feather_tls_capture_keylog(tls : NativeTlsHandle, enabled : Int) -> Int = "feather_tls_capture_keylog"

#borrow(tls, buffer)
extern "C" fn feather_tls_drain_keylog(tls : NativeTlsHandle, buffer : Bytes, capacity : Int) -> Int = "feather_tls_drain_keylog"

#borrow(tls)
extern "C" fn feather_tls_handshake(tls : NativeTlsHandle) -> Int = "feather_tls_handshake"

#borrow(tls, buffer)
extern "C" fn feather_tls_read(tls : NativeTlsHandle, buffer : Bytes, capacity : Int) -> Int = "feather_tls_read"

#borrow(tls, buffer)
extern "C" fn feather_tls_write(tls : NativeTlsHandle, buffer : Bytes, offset : Int, length : Int) -> Int = "feather_tls_write"

#borrow(tls, buffer)
extern "C" fn feather_tls_receive_pending(tls : NativeTlsHandle, buffer : Bytes, capacity : Int) -> Int = "feather_tls_receive_pending"

#borrow(tls, buffer)
extern "C" fn feather_tls_send_input(tls : NativeTlsHandle, buffer : Bytes, length : Int) -> Int = "feather_tls_send_input"

#borrow(tls)
extern "C" fn feather_tls_shutdown(tls : NativeTlsHandle) -> Int = "feather_tls_shutdown"

#borrow(tls)
extern "C" fn feather_tls_verify_error(tls : NativeTlsHandle) -> Int = "feather_tls_verify_error"

#borrow(tls, buffer)
extern "C" fn feather_tls_alpn(tls : NativeTlsHandle, buffer : Bytes, capacity : Int) -> Int = "feather_tls_alpn"

#borrow(tls, buffer)
extern "C" fn feather_tls_last_error_message(tls : NativeTlsHandle, buffer : Bytes, capacity : Int) -> Int = "feather_tls_last_error_message"

const NATIVE_TLS_BUFFER_SIZE : Int = 16384
const NATIVE_TLS_HANDSHAKE_STEPS : Int = 64

fn native_tls_error_message(tls : NativeTlsHandle) -> String {
  let buffer = Bytes::new(512)
  let length = feather_tls_last_error_message(tls, buffer, 512)
  if length <= 0 {
    return "TLS operation failed"
  }
  @utf8.decode_lossy(buffer.exact_view(start=0, end=length))
}

fn native_tls_handshake_error(tls : NativeTlsHandle) -> TlsError {
  let message = native_tls_error_message(tls)
  if feather_tls_verify_error(tls) != 0 {
    return CertificateValidationFailed(message)
  }
  HandshakeFailed(message)
}

fn native_tls_alpn_bytes(alpn : List[String]) -> Bytes {
  let buffer = Buffer(size_hint=64)
  for protocol in alpn {
    let encoded = @utf8.encode(protocol)
    if encoded.length() > 255 {
      continue
    }
    buffer.write_byte(encoded.length().to_byte())
    buffer.write_bytes(encoded)
  }
  buffer.to_bytes()
}

fn native_tls_root_bytes(store : RootStore) -> Bytes {
  let buffer = Buffer(size_hint=4096)
  for certificate in store.certificates {
    buffer.write_bytes(certificate)
    buffer.write_byte(b'\n')
  }
  buffer.to_bytes()
}

/// Forward any captured TLS key material to the configured key-log sink. This
/// is a debugging aid only; it never affects the handshake or I/O result.
fn native_tls_drain_keylog(
  tls : NativeTlsHandle,
  sink : &KeyLogSink?,
) -> Unit {
  let sink = match sink {
    Some(sink) => sink
    None => return
  }
  let buffer = Buffer(size_hint=1024)
  while true {
    let chunk = Bytes::new(4096)
    let length = feather_tls_drain_keylog(tls, chunk, 4096)
    if length <= 0 {
      break
    }
    buffer.write_bytes(chunk.exact_view(start=0, end=length))
  }
  let text = @utf8.decode_lossy(buffer.to_bytes())
  for line in text.split("\n") {
    if line.length() == 0 {
      continue
    }
    let environment = match line.find(" ") {
      Some(index) => line[:index]
      None => line
    }
    sink.log(environment.to_owned(), @utf8.encode(line.to_owned()))
  }
}

enum NativeTlsIo {
  TlsIoData
  TlsIoClosed
  TlsIoTimeout
  TlsIoFailure(String)
}

fn native_tls_flush(
  tls : NativeTlsHandle,
  underlying : &Stream,
) -> NativeTlsIo {
  let buffer = Bytes::new(NATIVE_TLS_BUFFER_SIZE)
  while true {
    let count = feather_tls_receive_pending(tls, buffer, NATIVE_TLS_BUFFER_SIZE)
    if count < 0 {
      return TlsIoFailure(native_tls_error_message(tls))
    }
    if count == 0 {
      return TlsIoData
    }
    let data = buffer.exact_view(start=0, end=count).to_owned()
    match write_all(underlying, data) {
      Ok(_) => ()
      Err(err) => match err {
        Timeout => return TlsIoTimeout
        Closed => return TlsIoClosed
        _ => return TlsIoFailure("TLS write failed")
      }
    }
  }
  TlsIoFailure("TLS flush did not converge")
}

fn native_tls_feed(
  tls : NativeTlsHandle,
  underlying : &Stream,
) -> NativeTlsIo {
  let buffer = Buffer(size_hint=4096)
  let count = match underlying.read(buffer) {
    Ok(count) => count
    Err(err) => match err {
      Timeout => return TlsIoTimeout
      Closed => return TlsIoClosed
      _ => return TlsIoFailure("TLS read failed")
    }
  }
  if count <= 0 {
    return TlsIoClosed
  }
  let data = buffer.to_bytes()
  if data.length() == 0 {
    return TlsIoFailure("TLS stream returned no data")
  }
  let written = feather_tls_send_input(tls, data, data.length())
  if written != data.length() {
    return TlsIoFailure("TLS failed to buffer encrypted input")
  }
  TlsIoData
}

fn native_tls_flush_error(result : NativeTlsIo) -> TlsError {
  match result {
    TlsIoTimeout => Timeout
    TlsIoClosed => ConnectionClosed
    TlsIoFailure(message) => IoError(message)
    _ => IoError("TLS write failed")
  }
}

fn native_tls_feed_error(result : NativeTlsIo) -> TlsError {
  match result {
    TlsIoTimeout => Timeout
    TlsIoClosed => ConnectionClosed
    TlsIoFailure(message) => IoError(message)
    TlsIoData => IoError("TLS read failed")
  }
}

/// A TLS stream backed by OpenSSL.
pub struct NativeTlsStream {
  tls : NativeTlsHandle
  underlying : &Stream
  key_log : Option[&KeyLogSink]
  mut is_open : Bool
}

pub impl Stream for NativeTlsStream with fn read(
  self : NativeTlsStream,
  buf : Buffer,
) -> Result[Int, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  let buffer = Bytes::new(NATIVE_TLS_BUFFER_SIZE)
  while true {
    let count = feather_tls_read(self.tls, buffer, NATIVE_TLS_BUFFER_SIZE)
    native_tls_drain_keylog(self.tls, self.key_log)
    if count > 0 {
      buf.write_bytes(buffer.exact_view(start=0, end=count))
      return Ok(count)
    }
    if count == 0 {
      return Ok(0)
    }
    if count == -1 {
      match native_tls_flush(self.tls, self.underlying) {
        TlsIoData => ()
        TlsIoTimeout => return Err(NetError::Timeout)
        TlsIoClosed => return Err(NetError::Closed)
        _ => return Err(NetError::ReadError("TLS flush failed"))
      }
      match native_tls_feed(self.tls, self.underlying) {
        TlsIoData => continue
        TlsIoClosed => return Ok(0)
        TlsIoTimeout => return Err(NetError::Timeout)
        TlsIoFailure(message) => return Err(NetError::ReadError(message))
      }
    }
    if count == -2 {
      match native_tls_flush(self.tls, self.underlying) {
        TlsIoData => continue
        TlsIoTimeout => return Err(NetError::Timeout)
        TlsIoClosed => return Err(NetError::Closed)
        _ => return Err(NetError::ReadError("TLS flush failed"))
      }
    }
    return Err(NetError::ReadError(native_tls_error_message(self.tls)))
  }
  Err(NetError::ReadError("TLS read did not converge"))
}

pub impl Stream for NativeTlsStream with fn write(
  self : NativeTlsStream,
  buf : Buffer,
) -> Result[Int, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  let data = buf.to_bytes()
  let mut offset = 0
  while offset < data.length() {
    let count = feather_tls_write(self.tls, data, offset, data.length() - offset)
    native_tls_drain_keylog(self.tls, self.key_log)
    if count > 0 {
      offset = offset + count
      match native_tls_flush(self.tls, self.underlying) {
        TlsIoData => ()
        TlsIoTimeout => return Err(NetError::Timeout)
        TlsIoClosed => return Err(NetError::Closed)
        _ => return Err(NetError::WriteError("TLS flush failed"))
      }
      continue
    }
    if count == -1 {
      match native_tls_flush(self.tls, self.underlying) {
        TlsIoData => ()
        TlsIoTimeout => return Err(NetError::Timeout)
        TlsIoClosed => return Err(NetError::Closed)
        _ => return Err(NetError::WriteError("TLS flush failed"))
      }
      match native_tls_feed(self.tls, self.underlying) {
        TlsIoData => continue
        TlsIoClosed => return Err(NetError::Closed)
        TlsIoTimeout => return Err(NetError::Timeout)
        TlsIoFailure(_) => return Err(NetError::WriteError("TLS read failed"))
      }
    }
    if count == -2 {
      match native_tls_flush(self.tls, self.underlying) {
        TlsIoData => continue
        TlsIoTimeout => return Err(NetError::Timeout)
        TlsIoClosed => return Err(NetError::Closed)
        _ => return Err(NetError::WriteError("TLS flush failed"))
      }
    }
    return Err(NetError::WriteError(native_tls_error_message(self.tls)))
  }
  Ok(offset)
}

pub impl Stream for NativeTlsStream with fn flush(
  self : NativeTlsStream,
) -> Result[Unit, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  match native_tls_flush(self.tls, self.underlying) {
    TlsIoData => self.underlying.flush()
    TlsIoTimeout => Err(NetError::Timeout)
    TlsIoClosed => Err(NetError::Closed)
    _ => Err(NetError::WriteError("TLS flush failed"))
  }
}

pub impl Stream for NativeTlsStream with fn close(
  self : NativeTlsStream,
) -> Result[Unit, NetError] {
  if !self.is_open {
    return Ok(())
  }
  self.is_open = false
  let _ = feather_tls_shutdown(self.tls)
  let _ = native_tls_flush(self.tls, self.underlying)
  self.underlying.close()
}

pub impl Stream for NativeTlsStream with fn set_timeout(
  self : NativeTlsStream,
  timeout_ms : Int,
) -> Result[Unit, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  self.underlying.set_timeout(timeout_ms)
}

pub impl Stream for NativeTlsStream with fn peer_addr(
  self : NativeTlsStream,
) -> Result[String, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  self.underlying.peer_addr()
}

pub impl Stream for NativeTlsStream with fn local_addr(
  self : NativeTlsStream,
) -> Result[String, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  self.underlying.local_addr()
}

/// TLS client context that performs real OpenSSL handshakes.
pub struct OpenSslTlsClientCtx {
  config : TlsConfig
  mut is_connected : Bool
  mut negotiated_alpn : String?
}

pub impl TlsClientCtx for OpenSslTlsClientCtx with fn server_name(
  self : OpenSslTlsClientCtx,
) -> String {
  self.config.server_name
}

pub impl TlsClientCtx for OpenSslTlsClientCtx with fn negotiated_alpn(
  self : OpenSslTlsClientCtx,
) -> String? {
  self.negotiated_alpn
}

pub impl TlsClientCtx for OpenSslTlsClientCtx with fn connect(
  self : OpenSslTlsClientCtx,
  underlying : &Stream,
) -> Result[&Stream, TlsError] {
  if self.is_connected {
    return Err(ProtocolError("TLS context is already connected"))
  }
  match self.config.validate() {
    Ok(_) => ()
    Err(err) => return Err(err)
  }

  let alpn = native_tls_alpn_bytes(self.config.alpn)
  let roots = native_tls_root_bytes(self.config.root_store)
  let (certificate, private_key) = match self.config.client_auth {
    Some(client) => (client.certificate, client.private_key)
    None => (b"", b"")
  }
  let verify = if self.config.verify == SkipVerification { 0 } else { 1 }
  let min_version = if self.config.min_version == Tls1_3 { 1 } else { 0 }
  let tls = feather_tls_new(
    @utf8.encode(self.config.server_name),
    alpn,
    alpn.length(),
    verify,
    min_version,
    roots,
    roots.length(),
    certificate,
    certificate.length(),
    private_key,
    private_key.length(),
  )
  if feather_tls_ready(tls) != 1 {
    return Err(InvalidConfig(native_tls_error_message(tls)))
  }

  let key_log = self.config.key_log
  if key_log is Some(_) {
    let _ = feather_tls_capture_keylog(tls, 1)
  }

  let mut steps = 0
  while steps < NATIVE_TLS_HANDSHAKE_STEPS {
    steps = steps + 1
    let status = feather_tls_handshake(tls)
    native_tls_drain_keylog(tls, key_log)
    match native_tls_flush(tls, underlying) {
      TlsIoData => ()
      result => return Err(native_tls_flush_error(result))
    }
    if status == 1 {
      let alpn_buffer = Bytes::new(256)
      let alpn_length = feather_tls_alpn(tls, alpn_buffer, 256)
      if alpn_length > 0 {
        self.negotiated_alpn = Some(
          @utf8.decode_lossy(alpn_buffer.exact_view(start=0, end=alpn_length)),
        )
      }
      self.is_connected = true
      let stream = NativeTlsStream::{ tls, underlying, key_log, is_open: true }
      return Ok(stream)
    }
    if status == 0 {
      match native_tls_feed(tls, underlying) {
        TlsIoData => continue
        result => return Err(native_tls_feed_error(result))
      }
    }
    if status == 2 {
      continue
    }
    return Err(native_tls_handshake_error(tls))
  }
  Err(HandshakeFailed("TLS handshake did not converge"))
}

/// TLS provider that uses OpenSSL for native builds.
pub struct OpenSslTlsProvider {}

pub fn OpenSslTlsProvider::new() -> OpenSslTlsProvider {
  OpenSslTlsProvider::{}
}

pub impl TlsProvider for OpenSslTlsProvider with fn new_client(
  self : OpenSslTlsProvider,
  config : TlsConfig,
) -> Result[&TlsClientCtx, TlsError] {
  let _ = self
  match config.validate() {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  let ctx = OpenSslTlsClientCtx::{
    config,
    is_connected: false,
    negotiated_alpn: None,
  }
  Ok(ctx)
}
