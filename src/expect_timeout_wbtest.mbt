/// A stream whose readiness check always times out. It models a peer that
/// ignores `Expect: 100-continue` and waits for the request body before it
/// sends any response at all.

struct ExpectSilentStream {
  inner : RegressionMockStream
}

fn expect_silent_stream(input : String) -> ExpectSilentStream {
  ExpectSilentStream::{ inner: regression_mock_stream(input, 0, 0) }
}

pub impl Stream for ExpectSilentStream with fn read(
  self : ExpectSilentStream,
  buf : Buffer,
) -> Result[Int, NetError] {
  self.inner.read(buf)
}

pub impl Stream for ExpectSilentStream with fn write(
  self : ExpectSilentStream,
  buf : Buffer,
) -> Result[Int, NetError] {
  self.inner.write(buf)
}

pub impl Stream for ExpectSilentStream with fn flush(
  self : ExpectSilentStream,
) -> Result[Unit, NetError] {
  self.inner.flush()
}

pub impl Stream for ExpectSilentStream with fn close(
  self : ExpectSilentStream,
) -> Result[Unit, NetError] {
  self.inner.close()
}

pub impl Stream for ExpectSilentStream with fn set_timeout(
  self : ExpectSilentStream,
  timeout_ms : Int,
) -> Result[Unit, NetError] {
  self.inner.set_timeout(timeout_ms)
}

pub impl Stream for ExpectSilentStream with fn peer_addr(
  self : ExpectSilentStream,
) -> Result[String, NetError] {
  self.inner.peer_addr()
}

pub impl Stream for ExpectSilentStream with fn local_addr(
  self : ExpectSilentStream,
) -> Result[String, NetError] {
  self.inner.local_addr()
}

pub impl Stream for ExpectSilentStream with fn wait_readable(
  self : ExpectSilentStream,
  timeout_ms : Int,
) -> Result[Bool, NetError] {
  let _ = self
  let _ = timeout_ms
  Ok(false)
}

///|
fn expect_silent_wire(stream : ExpectSilentStream) -> String {
  @utf8.decode_lossy(stream.inner.output.to_bytes()[:])
}

///|
test "a silent peer still receives the expect body after the wait expires" {
  let url = Url::parse("http://example.com/upload").unwrap()
  let stream = expect_silent_stream(
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok",
  )
  let codec = H1Codec::new(stream)
  let request = Request::new(POST, url)
    .with_expect_continue()
    .with_body(@utf8.encode("hello"))
  assert_true(codec.encode_request(request) is Ok(_))
  // The body is still withheld while the codec waits for the peer.
  assert_true(!expect_silent_wire(stream).contains("hello"))
  let response = codec.decode_response().unwrap()
  assert_eq(response.status, 200)
  assert_eq(response.text().unwrap(), "ok")
  let wire = expect_silent_wire(stream)
  assert_true(wire.contains("hello"))
  assert_eq(wire.find("hello"), wire.rev_find("hello"))
  // The request was fully sent, so the connection is still reusable.
  assert_true(stream.inner.is_open)
}

///|
test "a later 100 does not send an already-released body twice" {
  let url = Url::parse("http://example.com/upload").unwrap()
  let stream = expect_silent_stream(
    "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 204 No Content\r\n\r\n",
  )
  let codec = H1Codec::new(stream)
  let request = Request::new(POST, url)
    .with_expect_continue()
    .with_body(@utf8.encode("once"))
  assert_true(codec.encode_request(request) is Ok(_))
  let response = codec.decode_response().unwrap()
  assert_eq(response.status, 204)
  let wire = expect_silent_wire(stream)
  assert_eq(wire.find("once"), wire.rev_find("once"))
  assert_true(stream.inner.is_open)
}

///|
test "an explicit zero expect timeout keeps the unbounded wait" {
  let url = Url::parse("http://example.com/upload").unwrap()
  let stream = expect_silent_stream(
    "HTTP/1.1 417 Expectation Failed\r\nContent-Length: 0\r\n\r\n",
  )
  let codec = H1Codec::new(stream).with_expect_timeout(0)
  let request = Request::new(POST, url)
    .with_expect_continue()
    .with_body(@utf8.encode("secret"))
  assert_true(codec.encode_request(request) is Ok(_))
  let response = codec.decode_response().unwrap()
  assert_eq(response.status, 417)
  assert_eq(response.read_body().unwrap(), b"")
  assert_true(!expect_silent_wire(stream).contains("secret"))
}

///|
#cfg(target="native")
extern "C" fn feather_tcp_wait_readable_probe(
  fd : Int,
  timeout_ms : Int,
) -> Int = "feather_tcp_wait_readable"

///|
#cfg(target="native")
test "native wait readable validates descriptors and timeouts" {
  assert_eq(feather_tcp_wait_readable_probe(-1, 0), -9)
  assert_eq(feather_tcp_wait_readable_probe(0, -1), -22)
}
