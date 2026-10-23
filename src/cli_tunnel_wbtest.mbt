struct CliTunnelProbe {
  mut read_called : Bool
  mut closed : Bool
}

fn cli_tunnel_probe() -> CliTunnelProbe {
  CliTunnelProbe::{ read_called: false, closed: false }
}

pub impl Stream for CliTunnelProbe with fn read(
  self : CliTunnelProbe,
  buf : Buffer,
) -> Result[Int, NetError] {
  let _ = buf
  self.read_called = true
  Err(NetError::ReadError("tunnel body was read as text"))
}

pub impl Stream for CliTunnelProbe with fn write(
  self : CliTunnelProbe,
  buf : Buffer,
) -> Result[Int, NetError] {
  let _ = self
  Ok(buf.length())
}

pub impl Stream for CliTunnelProbe with fn flush(
  self : CliTunnelProbe,
) -> Result[Unit, NetError] {
  let _ = self
  Ok(())
}

pub impl Stream for CliTunnelProbe with fn close(
  self : CliTunnelProbe,
) -> Result[Unit, NetError] {
  self.closed = true
  Ok(())
}

pub impl Stream for CliTunnelProbe with fn set_timeout(
  self : CliTunnelProbe,
  timeout_ms : Int,
) -> Result[Unit, NetError] {
  let _ = self
  let _ = timeout_ms
  Ok(())
}

pub impl Stream for CliTunnelProbe with fn peer_addr(
  self : CliTunnelProbe,
) -> Result[String, NetError] {
  let _ = self
  Ok("mock:443")
}

pub impl Stream for CliTunnelProbe with fn local_addr(
  self : CliTunnelProbe,
) -> Result[String, NetError] {
  let _ = self
  Ok("mock:12345")
}

test "CLI does not read an upgraded protocol body as text" {
  let probe = cli_tunnel_probe()
  let response = Response::new_with_version(
    "HTTP/1.1",
    101,
    Headers::new().set("Upgrade", "websocket"),
    probe,
  )
  assert_true(print_response(response))
  assert_false(probe.read_called)
  assert_true(probe.closed)
}

test "CLI does not read a successful CONNECT tunnel as text" {
  let probe = cli_tunnel_probe()
  let response = Response::new_with_version(
    "HTTP/1.1",
    200,
    Headers::new(),
    probe,
  )
  assert_true(print_response(response, tunnel=true))
  assert_false(probe.read_called)
  assert_true(probe.closed)
}
