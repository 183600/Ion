///|
struct H2FrameMockStream {
  input : Bytes
  mut offset : Int32
  output : Buffer
  max_read : Int32
  mut is_open : Bool
}

///|
fn h2_frame_mock_stream(input : Bytes, max_read : Int32) -> H2FrameMockStream {
  H2FrameMockStream::{
    input,
    offset: 0,
    output: Buffer(size_hint=1024),
    max_read,
    is_open: true,
  }
}

///|
pub impl Stream for H2FrameMockStream with fn read(
  self : H2FrameMockStream,
  buf : Buffer,
) -> Result[Int32, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  let available = self.input.length() - self.offset
  if available == 0 {
    return Ok(0)
  }
  let limit = if self.max_read > 0 && self.max_read < available {
    self.max_read
  } else {
    available
  }
  buf.write_bytes(
    self.input.exact_view(start=self.offset, end=self.offset + limit),
  )
  self.offset = self.offset + limit
  Ok(limit)
}

///|
pub impl Stream for H2FrameMockStream with fn write(
  self : H2FrameMockStream,
  buf : Buffer,
) -> Result[Int32, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  self.output.write_bytes(buf.to_bytes())
  Ok(buf.length())
}

///|
pub impl Stream for H2FrameMockStream with fn flush(self : H2FrameMockStream) -> Result[
  Unit,
  NetError,
] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Ok(())
}

///|
pub impl Stream for H2FrameMockStream with fn close(self : H2FrameMockStream) -> Result[
  Unit,
  NetError,
] {
  self.is_open = false
  Ok(())
}

///|
pub impl Stream for H2FrameMockStream with fn set_timeout(
  self : H2FrameMockStream,
  timeout_ms : Int32,
) -> Result[Unit, NetError] {
  let _ = timeout_ms
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Ok(())
}

///|
pub impl Stream for H2FrameMockStream with fn peer_addr(
  self : H2FrameMockStream,
) -> Result[String, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Ok("mock:443")
}

///|
pub impl Stream for H2FrameMockStream with fn local_addr(
  self : H2FrameMockStream,
) -> Result[String, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Ok("mock:12345")
}

///|
test "http2 frame encoding uses the nine byte header" {
  let bytes = h2_frame_bytes(
    H2_FRAME_DATA,
    H2_FLAG_END_STREAM,
    1,
    @utf8.encode("hello"),
  )
  assert_eq(bytes.length(), 14)
  assert_eq(bytes[0], b'\x00')
  assert_eq(bytes[1], b'\x00')
  assert_eq(bytes[2], b'\x05')
  assert_eq(bytes[3], b'\x00')
  assert_eq(bytes[4], b'\x01')
  assert_eq(bytes[5], b'\x00')
  assert_eq(bytes[6], b'\x00')
  assert_eq(bytes[7], b'\x00')
  assert_eq(bytes[8], b'\x01')
  assert_eq(@utf8.decode_lossy(bytes[9:]), "hello")
}

///|
test "http2 frame decoding tolerates partial reads" {
  let encoded = h2_frame_bytes(
    H2_FRAME_HEADERS,
    H2_FLAG_END_HEADERS,
    1,
    @utf8.encode("abc"),
  )
  let stream = h2_frame_mock_stream(encoded, 2)
  let reader = StreamReader::new(stream)
  let frame = h2_read_frame(reader).unwrap()
  assert_eq(frame.frame_type, H2_FRAME_HEADERS)
  assert_eq(frame.flags, H2_FLAG_END_HEADERS)
  assert_eq(frame.stream_id, 1)
  assert_eq(@utf8.decode_lossy(frame.payload[:]), "abc")
}

///|
test "http2 frame decoding rejects oversized and malformed frames" {
  let too_large = b"\x00\x40\x01\x00\x00\x00\x00\x00\x01"
  match h2_read_frame(StreamReader::new(h2_frame_mock_stream(too_large, 0))) {
    Err(err) =>
      assert_eq(err, ProtocolError("HTTP/2 frame exceeds advertised maximum"))
    Ok(_) => fail("oversized HTTP/2 frame was accepted")
  }

  let bad_ping = b"\x00\x00\x07\x06\x00\x00\x00\x00\x00abcdefg"
  match h2_read_frame(StreamReader::new(h2_frame_mock_stream(bad_ping, 0))) {
    Err(err) => assert_eq(err, ProtocolError("Invalid HTTP/2 PING length"))
    Ok(_) => fail("malformed HTTP/2 PING was accepted")
  }
}

///|
test "http2 SETTINGS ACK must have an empty payload" {
  let frame = h2_frame_bytes(
    H2_FRAME_SETTINGS,
    H2_FLAG_ACK,
    0,
    h2_settings_payload([
      (H2_SETTINGS_INITIAL_WINDOW_SIZE, H2_DEFAULT_WINDOW_SIZE),
    ]),
  )
  match h2_read_frame(StreamReader::new(h2_frame_mock_stream(frame, 0))) {
    Err(err) =>
      assert_eq(err, ProtocolError("Invalid HTTP/2 SETTINGS ACK length"))
    Ok(_) => fail("HTTP/2 SETTINGS ACK with a payload was accepted")
  }
  let empty = h2_frame_bytes(H2_FRAME_SETTINGS, H2_FLAG_ACK, 0, b"")
  assert_true(
    h2_read_frame(StreamReader::new(h2_frame_mock_stream(empty, 0))) is Ok(_),
  )
}

///|
test "http2 strips DATA and HEADERS padding" {
  let data = H2Frame::{
    frame_type: H2_FRAME_DATA,
    flags: H2_FLAG_PADDED,
    stream_id: 1,
    payload: b"\x02hello\x00\x00",
  }
  assert_eq(@utf8.decode_lossy(h2_data_payload(data).unwrap()[:]), "hello")

  let headers = H2Frame::{
    frame_type: H2_FRAME_HEADERS,
    flags: H2_FLAG_PADDED | H2_FLAG_PRIORITY,
    stream_id: 1,
    payload: b"\x01\x00\x00\x00\x00\x00block\x00",
  }
  assert_eq(
    @utf8.decode_lossy(h2_header_block_payload(headers).unwrap()[:]),
    "block",
  )
}

///|
test "http2 SETTINGS payload encodes identifiers and values" {
  let payload = h2_settings_payload([
    (H2_SETTINGS_ENABLE_PUSH, 0),
    (H2_SETTINGS_INITIAL_WINDOW_SIZE, 65535),
  ])
  assert_eq(payload.length(), 12)
  assert_eq(payload[0], b'\x00')
  assert_eq(payload[1], b'\x02')
  assert_eq(payload[8], b'\x00')
  assert_eq(payload[9], b'\x00')
  assert_eq(payload[10], b'\xff')
  assert_eq(payload[11], b'\xff')
}

///|
test "http2 window update rejects a zero increment" {
  assert_eq(
    h2_parse_window_update(b"\x00\x00\x00\x00"),
    Err(ProtocolError("Invalid HTTP/2 WINDOW_UPDATE increment")),
  )
  assert_eq(h2_parse_window_update(b"\x00\x00\x00\x01").unwrap(), 1)
}

///|
fn h2_frame_error(result : Result[H2Frame, HttpError]) -> HttpError? {
  match result {
    Err(err) => Some(err)
    Ok(_) => None
  }
}

///|
test "http2 framing rejects frames with invalid stream identifiers" {
  let data = h2_frame_bytes(H2_FRAME_DATA, 0, 0, b"x")
  assert_eq(
    h2_frame_error(
      h2_read_frame(StreamReader::new(h2_frame_mock_stream(data, 0))),
    ),
    Some(ProtocolError("HTTP/2 DATA on stream 0")),
  )
  let headers = h2_frame_bytes(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 0, b"")
  assert_eq(
    h2_frame_error(
      h2_read_frame(StreamReader::new(h2_frame_mock_stream(headers, 0))),
    ),
    Some(ProtocolError("HTTP/2 stream frame on stream 0")),
  )
  let settings = h2_frame_bytes(H2_FRAME_SETTINGS, 0, 1, b"")
  assert_eq(
    h2_frame_error(
      h2_read_frame(StreamReader::new(h2_frame_mock_stream(settings, 0))),
    ),
    Some(ProtocolError("HTTP/2 connection frame on a stream")),
  )
}

///|
test "http2 framing rejects fixed-length frames with the wrong size" {
  for
    (frame, message) in [
      (
        b"\x00\x00\x05\x04\x00\x00\x00\x00\x00abcde", "Invalid HTTP/2 SETTINGS length",
      ),
      (
        b"\x00\x00\x03\x03\x00\x00\x00\x00\x01abc", "Invalid HTTP/2 RST_STREAM length",
      ),
      (
        b"\x00\x00\x03\x08\x00\x00\x00\x00\x01abc", "Invalid HTTP/2 WINDOW_UPDATE length",
      ),
      (
        b"\x00\x00\x04\x02\x00\x00\x00\x00\x01abcd", "Invalid HTTP/2 PRIORITY length",
      ),
      (
        b"\x00\x00\x07\x07\x00\x00\x00\x00\x00abcdefg", "Invalid HTTP/2 GOAWAY length",
      ),
    ] {
    assert_eq(
      h2_frame_error(
        h2_read_frame(StreamReader::new(h2_frame_mock_stream(frame, 0))),
      ),
      Some(ProtocolError(message)),
    )
  }
}

///|
test "http2 framing rejects a truncated payload" {
  let truncated = b"\x00\x00\x05\x00\x00\x00\x00\x00\x01ab"
  match h2_read_frame(StreamReader::new(h2_frame_mock_stream(truncated, 0))) {
    Err(NetworkError(ReadError(_))) => ()
    Err(err) =>
      fail("unexpected truncated frame error: " + @debug.to_string(err))
    Ok(_) => fail("truncated HTTP/2 frame was accepted")
  }
}

///|
test "http2 padding and priority validation rejects truncated fields" {
  let empty_header = H2Frame::{
    frame_type: H2_FRAME_HEADERS,
    flags: H2_FLAG_PADDED,
    stream_id: 1,
    payload: b"",
  }
  assert_eq(
    h2_header_block_payload(empty_header),
    Err(ProtocolError("Truncated padded HTTP/2 frame")),
  )
  let bad_padding = H2Frame::{
    frame_type: H2_FRAME_HEADERS,
    flags: H2_FLAG_PADDED,
    stream_id: 1,
    payload: b"\x05abc",
  }
  assert_eq(
    h2_header_block_payload(bad_padding),
    Err(ProtocolError("Invalid HTTP/2 padding")),
  )
  let short_priority = H2Frame::{
    frame_type: H2_FRAME_HEADERS,
    flags: H2_FLAG_PRIORITY,
    stream_id: 1,
    payload: b"\x00\x00\x00\x00",
  }
  assert_eq(
    h2_header_block_payload(short_priority),
    Err(ProtocolError("Truncated HTTP/2 priority fields")),
  )
  let empty_data = H2Frame::{
    frame_type: H2_FRAME_DATA,
    flags: H2_FLAG_PADDED,
    stream_id: 1,
    payload: b"",
  }
  assert_eq(
    h2_data_payload(empty_data),
    Err(ProtocolError("Truncated padded HTTP/2 DATA frame")),
  )
  let bad_data = H2Frame::{
    frame_type: H2_FRAME_DATA,
    flags: H2_FLAG_PADDED,
    stream_id: 1,
    payload: b"\x05ab",
  }
  assert_eq(
    h2_data_payload(bad_data),
    Err(ProtocolError("Invalid HTTP/2 DATA padding")),
  )
}

///|
test "http2 window update validates its payload length" {
  assert_eq(
    h2_parse_window_update(b"\x00\x00\x01"),
    Err(ProtocolError("Invalid HTTP/2 WINDOW_UPDATE length")),
  )
  assert_eq(h2_parse_window_update(b"\x00\x00\x00\x02").unwrap(), 2)
}

///|
test "http2 rejects a stream that depends on itself" {
  let priority = h2_frame_bytes(
    H2_FRAME_PRIORITY,
    0,
    1,
    b"\x00\x00\x00\x01\x10",
  )
  assert_eq(
    h2_frame_error(
      h2_read_frame(StreamReader::new(h2_frame_mock_stream(priority, 0))),
    ),
    Some(ProtocolError("HTTP/2 stream cannot depend on itself")),
  )
  let headers = H2Frame::{
    frame_type: H2_FRAME_HEADERS,
    flags: H2_FLAG_END_HEADERS | H2_FLAG_PRIORITY,
    stream_id: 1,
    payload: b"\x00\x00\x00\x01\x10",
  }
  assert_eq(
    h2_header_block_payload(headers),
    Err(ProtocolError("HTTP/2 stream cannot depend on itself")),
  )
}
