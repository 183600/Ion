///|
test "released HTTP/1 response bodies do not report readiness" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
  let stream = regression_mock_stream(raw, 1, 0)
  let completions : Array[Bool] = []
  let codec = H1Codec::new_with_completion(
    stream,
    fn(reusable) { completions.push(reusable) },
  )
  let response = codec.decode_response().unwrap()
  assert_eq(response.read_body().unwrap(), b"ok")
  assert_eq(completions, [true])
  // The pooled connection may already belong to another exchange.
  assert_false(response.body.read_ready())
  assert_true(response.body.wait_readable(0) is Err(Closed))
  assert_true(stream.is_open)
}

struct PartialFrameStream {
  input : Bytes
  mut offset : Int
  output : Buffer
  mut is_open : Bool
}

fn partial_frame_stream(input : Bytes) -> PartialFrameStream {
  PartialFrameStream::{
    input,
    offset: 0,
    output: Buffer(size_hint=1024),
    is_open: true,
  }
}

pub impl Stream for PartialFrameStream with fn read(
  self : PartialFrameStream,
  buf : Buffer,
) -> Result[Int, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  let available = self.input.length() - self.offset
  if available == 0 {
    return Ok(0)
  }
  buf.write_bytes(
    self.input.exact_view(start=self.offset, end=self.input.length()),
  )
  self.offset = self.input.length()
  Ok(available)
}

pub impl Stream for PartialFrameStream with fn read_ready(
  self : PartialFrameStream,
) -> Bool {
  self.is_open && self.offset < self.input.length()
}

pub impl Stream for PartialFrameStream with fn write(
  self : PartialFrameStream,
  buf : Buffer,
) -> Result[Int, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  self.output.write_bytes(buf.to_bytes())
  Ok(buf.length())
}

pub impl Stream for PartialFrameStream with fn flush(
  self : PartialFrameStream,
) -> Result[Unit, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Ok(())
}

pub impl Stream for PartialFrameStream with fn close(
  self : PartialFrameStream,
) -> Result[Unit, NetError] {
  self.is_open = false
  Ok(())
}

pub impl Stream for PartialFrameStream with fn set_timeout(
  self : PartialFrameStream,
  timeout_ms : Int,
) -> Result[Unit, NetError] {
  let _ = timeout_ms
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Ok(())
}

pub impl Stream for PartialFrameStream with fn peer_addr(
  self : PartialFrameStream,
) -> Result[String, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Ok("partial:0")
}

pub impl Stream for PartialFrameStream with fn local_addr(
  self : PartialFrameStream,
) -> Result[String, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Ok("partial:0")
}

fn readiness_h2_input(data : Bytes) -> Bytes {
  h2_test_concat([
    h2_test_settings(),
    h2_test_frame(
      H2_FRAME_HEADERS,
      H2_FLAG_END_HEADERS,
      1,
      hpack_encode([(":status", "200")]),
    ),
    data,
  ])
}

///|
test "HTTP/2 streaming readiness ignores an incomplete frame" {
  let full = h2_test_frame(H2_FRAME_DATA, H2_FLAG_END_STREAM, 1, b"ok")
  let partial = full.exact_view(start=0, end=full.length() - 1).to_owned()
  let stream = partial_frame_stream(readiness_h2_input(partial))
  let connection = H2ClientConnection::new(stream).unwrap()
  let response = connection.request_streaming(
    Request::new(GET, Url::parse("https://example.com/partial").unwrap()),
  ).unwrap()
  assert_false(response.body.read_ready())
  assert_true(response.body.wait_readable(0) is Ok(false))
  let _ = response.body.close()
  let _ = connection.close()
}

///|
test "HTTP/2 streaming readiness accepts a complete buffered frame" {
  let full = h2_test_frame(H2_FRAME_DATA, H2_FLAG_END_STREAM, 1, b"ok")
  let stream = partial_frame_stream(readiness_h2_input(full))
  let connection = H2ClientConnection::new(stream).unwrap()
  let response = connection.request_streaming(
    Request::new(GET, Url::parse("https://example.com/complete").unwrap()),
  ).unwrap()
  assert_true(response.body.read_ready())
  assert_true(response.body.wait_readable(0) is Ok(true))
  assert_eq(response.read_body().unwrap(), b"ok")
  let _ = connection.close()
}
