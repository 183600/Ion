struct ErroringStream {
  error : NetError
}

pub impl Stream for ErroringStream with fn read(
  self : ErroringStream,
  buf : Buffer,
) -> Result[Int, NetError] {
  let _ = buf
  Err(self.error)
}

pub impl Stream for ErroringStream with fn write(
  self : ErroringStream,
  buf : Buffer,
) -> Result[Int, NetError] {
  let _ = buf
  Err(self.error)
}

pub impl Stream for ErroringStream with fn flush(
  self : ErroringStream,
) -> Result[Unit, NetError] {
  Err(self.error)
}

pub impl Stream for ErroringStream with fn close(
  self : ErroringStream,
) -> Result[Unit, NetError] {
  let _ = self
  Ok(())
}

pub impl Stream for ErroringStream with fn set_timeout(
  self : ErroringStream,
  timeout_ms : Int,
) -> Result[Unit, NetError] {
  let _ = self
  let _ = timeout_ms
  Ok(())
}

pub impl Stream for ErroringStream with fn peer_addr(
  self : ErroringStream,
) -> Result[String, NetError] {
  let _ = self
  Ok("mock:0")
}

pub impl Stream for ErroringStream with fn local_addr(
  self : ErroringStream,
) -> Result[String, NetError] {
  let _ = self
  Ok("mock:0")
}

///|
test "a timed out response body surfaces as HttpError::Timeout" {
  let response = Response::new(200, Headers::new(), ErroringStream::{
    error: NetError::Timeout,
  })
  assert_true(response.read_body() is Err(Timeout))
}

///|
test "a closed response body surfaces as HttpError::ConnectionClosed" {
  let response = Response::new(200, Headers::new(), ErroringStream::{
    error: NetError::Closed,
  })
  assert_true(response.read_body() is Err(ConnectionClosed))
}

///|
test "other response body failures stay wrapped in NetworkError" {
  let response = Response::new(200, Headers::new(), ErroringStream::{
    error: NetError::ReadError("broken"),
  })
  assert_true(response.read_body() is Err(NetworkError(ReadError(_))))
}
