struct WindowUpdateFlushStream {
  output : Buffer
  mut flushes : Int
}

fn window_update_flush_stream() -> WindowUpdateFlushStream {
  WindowUpdateFlushStream::{ output: Buffer(size_hint=64), flushes: 0 }
}

pub impl Stream for WindowUpdateFlushStream with fn read(
  self : WindowUpdateFlushStream,
  buf : Buffer,
) -> Result[Int, NetError] {
  let _ = self
  let _ = buf
  Ok(0)
}

pub impl Stream for WindowUpdateFlushStream with fn write(
  self : WindowUpdateFlushStream,
  buf : Buffer,
) -> Result[Int, NetError] {
  self.output.write_bytes(buf.to_bytes())
  Ok(buf.length())
}

pub impl Stream for WindowUpdateFlushStream with fn flush(
  self : WindowUpdateFlushStream,
) -> Result[Unit, NetError] {
  self.flushes = self.flushes + 1
  Ok(())
}

pub impl Stream for WindowUpdateFlushStream with fn close(
  self : WindowUpdateFlushStream,
) -> Result[Unit, NetError] {
  let _ = self
  Ok(())
}

pub impl Stream for WindowUpdateFlushStream with fn set_timeout(
  self : WindowUpdateFlushStream,
  timeout_ms : Int,
) -> Result[Unit, NetError] {
  let _ = self
  let _ = timeout_ms
  Ok(())
}

pub impl Stream for WindowUpdateFlushStream with fn peer_addr(
  self : WindowUpdateFlushStream,
) -> Result[String, NetError] {
  let _ = self
  Ok("mock:443")
}

pub impl Stream for WindowUpdateFlushStream with fn local_addr(
  self : WindowUpdateFlushStream,
) -> Result[String, NetError] {
  let _ = self
  Ok("mock:12345")
}

test "http2 flushes window updates written while reading a response" {
  let stream = window_update_flush_stream()
  h2_send_window_update(stream, 0, 7, flush=true).unwrap()
  assert_eq(stream.flushes, 1)
  assert_eq(
    stream.output.to_bytes(),
    h2_frame_bytes(
      H2_FRAME_WINDOW_UPDATE,
      0,
      0,
      h2_window_update_payload(7),
    ),
  )
}

test "http2 keeps the initial window update batched with the preface" {
  let stream = window_update_flush_stream()
  h2_send_window_update(stream, 0, 7).unwrap()
  assert_eq(stream.flushes, 0)
  assert_true(stream.output.length() > 0)
}
