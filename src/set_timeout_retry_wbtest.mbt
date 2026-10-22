/// A pooled connection can fail while the client applies the request timeout,
/// before any request bytes are written. Retrying is safe even for methods
/// that are not idempotent because the request never reached the peer.

struct TimeoutFailStream {
  input : Bytes
  mut offset : Int
  output : Buffer
  fail_at : Int
  mut timeout_calls : Int
  mut is_open : Bool
}

fn timeout_fail_stream(input : String, fail_at : Int) -> TimeoutFailStream {
  TimeoutFailStream::{
    input: @utf8.encode(input),
    offset: 0,
    output: @buffer.new(size_hint=4096),
    fail_at,
    timeout_calls: 0,
    is_open: true,
  }
}

pub impl Stream for TimeoutFailStream with fn read(
  self : TimeoutFailStream,
  buf : Buffer,
) -> Result[Int, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  let available = self.input.length() - self.offset
  if available <= 0 {
    return Ok(0)
  }
  buf.write_bytes(self.input.exact_view(start=self.offset, end=self.input.length()))
  self.offset = self.input.length()
  Ok(available)
}

pub impl Stream for TimeoutFailStream with fn write(
  self : TimeoutFailStream,
  buf : Buffer,
) -> Result[Int, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  self.output.write_bytes(buf.to_bytes())
  Ok(buf.length())
}

pub impl Stream for TimeoutFailStream with fn flush(
  self : TimeoutFailStream,
) -> Result[Unit, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Ok(())
}

pub impl Stream for TimeoutFailStream with fn close(
  self : TimeoutFailStream,
) -> Result[Unit, NetError] {
  self.is_open = false
  Ok(())
}

pub impl Stream for TimeoutFailStream with fn set_timeout(
  self : TimeoutFailStream,
  timeout_ms : Int,
) -> Result[Unit, NetError] {
  let _ = timeout_ms
  if !self.is_open {
    return Err(NetError::Closed)
  }
  self.timeout_calls = self.timeout_calls + 1
  if self.timeout_calls == self.fail_at {
    return Err(NetError::IoError("cannot apply timeout"))
  }
  Ok(())
}

pub impl Stream for TimeoutFailStream with fn peer_addr(
  self : TimeoutFailStream,
) -> Result[String, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Ok("mock:0")
}

pub impl Stream for TimeoutFailStream with fn local_addr(
  self : TimeoutFailStream,
) -> Result[String, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Ok("mock:0")
}

test "non-idempotent request retries when applying the timeout fails before sending" {
  let stale = timeout_fail_stream(
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok",
    3,
  )
  let fresh = timeout_fail_stream(
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok",
    99,
  )
  let streams : Array[&Stream] = [stale, fresh]
  let dialer = RegressionQueueDialer::{ streams, index: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let client = UnifiedClient::{
    connector,
    options: ClientOptions::new().with_follow_redirects(false),
    redirect_count: 0,
  }
  let url = "http://example.com/"

  let first = match client.get(url) {
    Ok(response) => response
    Err(err) => fail("first request failed: " + @debug.to_string(err))
  }
  assert_eq(first.read_body().unwrap(), b"ok")
  let second = match client.post(url, b"payload") {
    Ok(response) => response
    Err(err) => fail("retried POST failed: " + @debug.to_string(err))
  }
  assert_eq(second.read_body().unwrap(), b"ok")
  assert_eq(dialer.index, 2)
  assert_false(stale.is_open)
  let wire = @utf8.decode(fresh.output.to_bytes()[:])
  assert_true(wire.has_prefix("POST / HTTP/1.1\r\n"))
  assert_true(wire.ends_with("\r\n\r\npayload"))
  let _ = client.close_all()
}
