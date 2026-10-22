/// A pooled connection can go stale between requests. A write may then fail
/// before the peer receives the request, so idempotent requests should retry
/// on a fresh connection just like a failed read.

struct WriteFailureStream {
  input : Bytes
  mut offset : Int
  mut write_calls : Int
  fail_write : Int
  mut is_open : Bool
}

fn write_failure_stream(input : String, fail_write : Int) -> WriteFailureStream {
  WriteFailureStream::{
    input: @utf8.encode(input),
    offset: 0,
    write_calls: 0,
    fail_write,
    is_open: true,
  }
}

pub impl Stream for WriteFailureStream with fn read(
  self : WriteFailureStream,
  buf : Buffer,
) -> Result[Int, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  let available = self.input.length() - self.offset
  if available <= 0 {
    return Ok(0)
  }
  buf.write_byte(self.input[self.offset])
  self.offset = self.offset + 1
  Ok(1)
}

pub impl Stream for WriteFailureStream with fn write(
  self : WriteFailureStream,
  buf : Buffer,
) -> Result[Int, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  self.write_calls = self.write_calls + 1
  if self.write_calls >= self.fail_write {
    self.is_open = false
    return Err(NetError::WriteError("stale connection"))
  }
  Ok(buf.length())
}

pub impl Stream for WriteFailureStream with fn flush(
  self : WriteFailureStream,
) -> Result[Unit, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Ok(())
}

pub impl Stream for WriteFailureStream with fn close(
  self : WriteFailureStream,
) -> Result[Unit, NetError] {
  self.is_open = false
  Ok(())
}

pub impl Stream for WriteFailureStream with fn set_timeout(
  self : WriteFailureStream,
  timeout_ms : Int,
) -> Result[Unit, NetError] {
  let _ = timeout_ms
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Ok(())
}

pub impl Stream for WriteFailureStream with fn peer_addr(
  self : WriteFailureStream,
) -> Result[String, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Ok("mock:0")
}

pub impl Stream for WriteFailureStream with fn local_addr(
  self : WriteFailureStream,
) -> Result[String, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Ok("mock:0")
}

fn write_retry_client(
  streams : Array[&Stream],
) -> (UnifiedClient, RegressionQueueDialer) {
  let dialer = RegressionQueueDialer::{ streams, index: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let client = UnifiedClient::{
    connector,
    options: ClientOptions::new().with_follow_redirects(false),
    redirect_count: 0,
  }
  (client, dialer)
}

test "idempotent request retries when writing to a stale pooled connection fails" {
  let stale = write_failure_stream(
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok",
    2,
  )
  let fresh = write_failure_stream(
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok",
    2,
  )
  let streams : Array[&Stream] = [stale, fresh]
  let (client, dialer) = write_retry_client(streams)
  let url = "http://example.com/"

  assert_eq(client.get(url).unwrap().read_body().unwrap(), b"ok")
  let retried = client.get(url).unwrap()
  assert_eq(retried.read_body().unwrap(), b"ok")
  assert_eq(dialer.index, 2)
  assert_false(stale.is_open)
  let _ = client.close_all()
}

test "non-idempotent request is not retried after a stale write failure" {
  let stale = write_failure_stream(
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok",
    2,
  )
  let unused = write_failure_stream(
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok",
    2,
  )
  let streams : Array[&Stream] = [stale, unused]
  let (client, dialer) = write_retry_client(streams)
  let url = "http://example.com/"

  assert_eq(client.get(url).unwrap().read_body().unwrap(), b"ok")
  match client.post(url, b"") {
    Ok(_) => fail("POST retried after its request could have been written")
    Err(err) => assert_true(err is NetworkError(WriteError(_)))
  }
  assert_eq(dialer.index, 1)
  assert_false(stale.is_open)
  let _ = client.close_all()
}
