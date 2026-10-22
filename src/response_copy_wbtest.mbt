///|
test "Response::copy_body_to streams a body into a sink" {
  let source = regression_mock_stream("hello world", 0, 0)
  let response = Response::new(200, Headers::new(), source)
  let sink = regression_mock_stream("", 0, 0)
  assert_eq(response.copy_body_to(sink).unwrap(), 11)
  assert_eq(@utf8.decode_lossy(sink.output.to_bytes()[:]), "hello world")
}

///|
test "Response::copy_body_to propagates sink write failures" {
  let source = regression_mock_stream("payload", 0, 0)
  let response = Response::new(200, Headers::new(), source)
  let sink = regression_mock_stream("", 0, 0)
  let _ = sink.close()
  match response.copy_body_to(sink) {
    Ok(_) => fail("failing sink accepted a response body")
    Err(_) => ()
  }
  assert_false(source.is_open)
}

///|
test "Response::copy_body_to enforces the response body cap" {
  let source = regression_mock_stream("hello", 0, 0)
  let response = Response::new(200, Headers::new(), source).with_max_body_bytes(4)
  let sink = regression_mock_stream("", 0, 0)
  match response.copy_body_to(sink) {
    Ok(_) => fail("oversized response body was copied")
    Err(err) => assert_eq(err, NetworkError(ReadError("response body too large")))
  }
  assert_eq(sink.output.to_bytes().length(), 0)
  assert_false(source.is_open)
}

///|
struct FlushFailingSink {
  mut is_open : Bool
  output : Buffer
}

///|
fn FlushFailingSink::new() -> FlushFailingSink {
  FlushFailingSink::{ is_open: true, output: Buffer(size_hint=64) }
}

///|
pub impl Stream for FlushFailingSink with fn read(
  self : FlushFailingSink,
  buf : Buffer,
) -> Result[Int, NetError] {
  let _ = self
  let _ = buf
  Ok(0)
}

///|
pub impl Stream for FlushFailingSink with fn write(
  self : FlushFailingSink,
  buf : Buffer,
) -> Result[Int, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  self.output.write_bytes(buf.to_bytes())
  Ok(buf.length())
}

///|
pub impl Stream for FlushFailingSink with fn flush(
  self : FlushFailingSink,
) -> Result[Unit, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Err(NetError::WriteError("flush failed"))
}

///|
pub impl Stream for FlushFailingSink with fn close(
  self : FlushFailingSink,
) -> Result[Unit, NetError] {
  self.is_open = false
  Ok(())
}

///|
pub impl Stream for FlushFailingSink with fn set_timeout(
  self : FlushFailingSink,
  timeout_ms : Int,
) -> Result[Unit, NetError] {
  let _ = self
  let _ = timeout_ms
  Ok(())
}

///|
pub impl Stream for FlushFailingSink with fn peer_addr(
  self : FlushFailingSink,
) -> Result[String, NetError] {
  let _ = self
  Ok("sink:0")
}

///|
pub impl Stream for FlushFailingSink with fn local_addr(
  self : FlushFailingSink,
) -> Result[String, NetError] {
  let _ = self
  Ok("sink:0")
}

///|
test "Response::copy_body_to closes the source when the sink flush fails" {
  let source = regression_mock_stream("payload", 0, 0)
  let response = Response::new(200, Headers::new(), source)
  let sink = FlushFailingSink::new()
  match response.copy_body_to(sink) {
    Ok(_) => fail("failing sink flush was accepted")
    Err(err) =>
      assert_eq(err, NetworkError(WriteError("flush failed")))
  }
  assert_eq(@utf8.decode_lossy(sink.output.to_bytes()[:]), "payload")
  assert_false(source.is_open)
}
