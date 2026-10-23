#cfg(target="native")
struct DripTlsUnderlying {
  mut delivered : Int
}

#cfg(target="native")
fn drip_wait_ms(milliseconds : Int) -> Unit {
  let deadline = @env.now() + milliseconds.to_uint64()
  while @env.now() < deadline {
    ()
  }
}

#cfg(target="native")
pub impl Stream for DripTlsUnderlying with fn read(
  self : DripTlsUnderlying,
  buf : Buffer,
) -> Result[Int, NetError] {
  if self.delivered >= 16 {
    return Ok(0)
  }
  drip_wait_ms(2)
  self.delivered = self.delivered + 1
  buf.write_byte(b'\x15')
  Ok(1)
}

#cfg(target="native")
pub impl Stream for DripTlsUnderlying with fn get_timeout(
  self : DripTlsUnderlying,
) -> Int {
  let _ = self
  1
}

#cfg(target="native")
pub impl Stream for DripTlsUnderlying with fn write(
  self : DripTlsUnderlying,
  buf : Buffer,
) -> Result[Int, NetError] {
  let _ = self
  Ok(buf.length())
}

#cfg(target="native")
pub impl Stream for DripTlsUnderlying with fn flush(
  self : DripTlsUnderlying,
) -> Result[Unit, NetError] {
  let _ = self
  Ok(())
}

#cfg(target="native")
pub impl Stream for DripTlsUnderlying with fn close(
  self : DripTlsUnderlying,
) -> Result[Unit, NetError] {
  let _ = self
  Ok(())
}

#cfg(target="native")
pub impl Stream for DripTlsUnderlying with fn set_timeout(
  self : DripTlsUnderlying,
  timeout_ms : Int,
) -> Result[Unit, NetError] {
  let _ = self
  let _ = timeout_ms
  Ok(())
}

#cfg(target="native")
pub impl Stream for DripTlsUnderlying with fn peer_addr(
  self : DripTlsUnderlying,
) -> Result[String, NetError] {
  let _ = self
  Ok("mock:0")
}

#cfg(target="native")
pub impl Stream for DripTlsUnderlying with fn local_addr(
  self : DripTlsUnderlying,
) -> Result[String, NetError] {
  let _ = self
  Ok("mock:0")
}

/// A peer that sends one byte at a time keeps making progress, so an idle-step
/// cap alone never fires. The transport's connection timeout must still bound
/// the handshake.
#cfg(target="native")
test "native TLS handshake respects the transport deadline" {
  let provider = OpenSslTlsProvider::new()
  let config = TlsConfig::new("example.com").with_verify_mode(SkipVerification)
  let ctx = provider.new_client(config).unwrap()
  let stream : &Stream = DripTlsUnderlying::{ delivered: 0 }
  match ctx.connect(stream) {
    Err(Timeout) => ()
    Err(err) => abort("expected Timeout, got " + @debug.to_string(err))
    Ok(_) => abort("drip handshake unexpectedly succeeded")
  }
}
