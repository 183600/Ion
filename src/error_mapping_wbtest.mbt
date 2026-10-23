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


struct FailingTlsProvider {
  error : TlsError
}

pub impl TlsProvider for FailingTlsProvider with fn new_client(
  self : FailingTlsProvider,
  config : TlsConfig,
) -> Result[&TlsClientCtx, TlsError] {
  let _ = config
  Ok(FailingTlsCtx::{ error: self.error })
}

struct FailingTlsCtx {
  error : TlsError
}

pub impl TlsClientCtx for FailingTlsCtx with fn server_name(self : FailingTlsCtx) -> String {
  let _ = self
  "failing.example"
}

pub impl TlsClientCtx for FailingTlsCtx with fn connect(
  self : FailingTlsCtx,
  underlying : &Stream,
) -> Result[&Stream, TlsError] {
  let _ = underlying
  Err(self.error)
}

///|
test "a timed out TLS handshake surfaces as HttpError::Timeout" {
  let stream = regression_mock_stream("", 0, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let provider = FailingTlsProvider::{ error: Timeout }
  let client = UnifiedClient::with_transport(
    dialer,
    provider,
    ClientOptions::new().with_follow_redirects(false),
  )
  let url = Url::parse("https://example.com/").unwrap()
  assert_true(client.request(Request::new(GET, url)) is Err(Timeout))
}

///|
test "a closed TLS handshake surfaces as HttpError::ConnectionClosed" {
  let stream = regression_mock_stream("", 0, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let provider = FailingTlsProvider::{ error: TlsError::ConnectionClosed }
  let client = UnifiedClient::with_transport(
    dialer,
    provider,
    ClientOptions::new().with_follow_redirects(false),
  )
  let url = Url::parse("https://example.com/").unwrap()
  assert_true(client.request(Request::new(GET, url)) is Err(ConnectionClosed))
}

///|
test "direct HTTP/1 codec promotes transport write failures" {
  let url = Url::parse("http://example.com/").unwrap()
  let timed_out = H1Codec::new(ErroringStream::{ error: NetError::Timeout })
  assert_true(timed_out.encode_request(Request::new(GET, url)) is Err(Timeout))
  let closed = H1Codec::new(ErroringStream::{ error: NetError::Closed })
  assert_true(closed.encode_request(Request::new(GET, url)) is Err(ConnectionClosed))
}

///|
test "direct HTTP/1 codec promotes transport head read failures" {
  let timed_out = H1Codec::new(ErroringStream::{ error: NetError::Timeout })
  assert_true(timed_out.decode_response() is Err(Timeout))
  let closed = H1Codec::new(ErroringStream::{ error: NetError::Closed })
  assert_true(closed.decode_response() is Err(ConnectionClosed))
}
