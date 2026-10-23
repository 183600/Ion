fn ws_test_stream(input : Bytes) -> RegressionMockStream {
  RegressionMockStream::{
    input,
    offset: 0,
    output: @buffer.new(size_hint=256),
    max_read: 0,
    max_write: 0,
    is_open: true,
    last_timeout: 0,
  }
}

fn ws_test_concat(parts : Array[Bytes]) -> Bytes {
  let output = Buffer(size_hint=64)
  for part in parts {
    output.write_bytes(part)
  }
  output.to_bytes()
}

fn ws_test_frame(opcode : Int, fin : Bool, payload : Bytes) -> Bytes {
  let output = Buffer(size_hint=payload.length() + 4)
  output.write_byte(
    ((if fin { 0x80 } else { 0x00 }) | opcode).to_byte(),
  )
  if payload.length() <= 125 {
    output.write_byte(payload.length().to_byte())
  } else {
    output.write_byte((126).to_byte())
    output.write_byte(((payload.length() >> 8) & 0xFF).to_byte())
    output.write_byte((payload.length() & 0xFF).to_byte())
  }
  output.write_bytes(payload)
  output.to_bytes()
}

///|
test "websocket exposes explicit client and server endpoints" {
  assert_eq(WebSocket::client(ws_test_stream(b"")).role(), Client)
  assert_eq(WebSocket::server(ws_test_stream(b"")).role(), Server)
}

///|
test "websocket accept key matches RFC 6455 vector" {
  assert_eq(
    websocket_accept_key("dGhlIHNhbXBsZSBub25jZQ=="),
    "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
  )
}

///|
test "websocket reads a masked client frame as a server" {
  let payload = @utf8.encode("hi")
  let mask = b"\x01\x02\x03\x04"
  let masked = Buffer(size_hint=2)
  for index in 0..<payload.length() {
    masked.write_byte(
      (payload[index].to_int() ^ mask[index % 4].to_int()).to_byte(),
    )
  }
  let raw = ws_test_concat([
    b"\x81\x82",
    mask,
    masked.to_bytes(),
  ])
  let stream = ws_test_stream(raw)
  let socket = WebSocket::new(stream, Server)
  assert_eq(socket.read_message().unwrap(), Text("hi"))
}

///|
test "websocket reads a fragmented text message with an interleaved ping" {
  let raw = ws_test_concat([
    ws_test_frame(WS_OPCODE_TEXT, false, @utf8.encode("Hel")),
    ws_test_frame(WS_OPCODE_PING, true, b"x"),
    ws_test_frame(WS_OPCODE_CONTINUATION, true, @utf8.encode("lo")),
  ])
  let stream = ws_test_stream(raw)
  let socket = WebSocket::new(stream, Client)
  assert_eq(socket.read_message().unwrap(), Ping(b"x"))
  assert_eq(socket.read_message().unwrap(), Text("Hello"))
}

///|
test "websocket parses close status and reason" {
  let raw = ws_test_frame(WS_OPCODE_CLOSE, true, b"\x03\xe8bye")
  let stream = ws_test_stream(raw)
  let socket = WebSocket::new(stream, Client)
  assert_eq(socket.read_message().unwrap(), Close(1000, "bye"))
}

///|
test "websocket rejects malformed control and masking" {
  // Fragmented control frame.
  let fragmented_ping = ws_test_stream(ws_test_frame(WS_OPCODE_PING, false, b""))
  match WebSocket::new(fragmented_ping, Client).read_message() {
    Err(ProtocolError(_)) => ()
    _ => fail("fragmented ping was accepted")
  }
  // Reserved RSV1 bit.
  let reserved = ws_test_stream(b"\xc1\x00")
  match WebSocket::new(reserved, Client).read_message() {
    Err(ProtocolError(_)) => ()
    _ => fail("reserved bit was accepted")
  }
  // A server frame must not be masked.
  let masked = ws_test_stream(b"\x81\x80\x00\x00\x00\x00")
  match WebSocket::new(masked, Client).read_message() {
    Err(ProtocolError(message)) =>
      assert_eq(message, "Server WebSocket frame must not be masked")
    _ => fail("masked server frame was accepted")
  }
  // A client frame must be masked.
  let unmasked = ws_test_stream(b"\x81\x00")
  match WebSocket::new(unmasked, Server).read_message() {
    Err(ProtocolError(message)) =>
      assert_eq(message, "Client WebSocket frame must be masked")
    _ => fail("unmasked client frame was accepted")
  }
}

///|
test "websocket enforces frame and message limits" {
  let oversized = ws_test_stream(ws_test_frame(WS_OPCODE_TEXT, true, b"hello"))
  let socket = WebSocket::new(oversized, Client).with_max_frame_bytes(4)
  match socket.read_message() {
    Err(ProtocolError(message)) => assert_eq(message, "WebSocket frame too large")
    _ => fail("oversized frame was accepted")
  }
  let raw = ws_test_concat([
    ws_test_frame(WS_OPCODE_TEXT, false, b"abc"),
    ws_test_frame(WS_OPCODE_CONTINUATION, true, b"def"),
  ])
  let stream = ws_test_stream(raw)
  let socket = WebSocket::new(stream, Client).with_max_message_bytes(5)
  match socket.read_message() {
    Err(ProtocolError(message)) => assert_eq(message, "WebSocket message too large")
    _ => fail("oversized message was accepted")
  }
}

///|
test "websocket client masks outgoing frames" {
  let stream = ws_test_stream(b"")
  let socket = WebSocket::new(stream, Client)
  socket.send_text("hello").unwrap()
  let wire = stream.output.to_bytes()
  assert_eq(wire[0], b'\x81')
  assert_eq(wire[1], b'\x85')
  let mask = wire.exact_view(start=2, end=6).to_owned()
  let payload = wire.exact_view(start=6, end=wire.length()).to_owned()
  let decoded = Buffer(size_hint=5)
  for index in 0..<payload.length() {
    decoded.write_byte(
      (payload[index].to_int() ^ mask[index % 4].to_int()).to_byte(),
    )
  }
  assert_eq(decoded.to_bytes(), b"hello")
}

///|
test "websocket handshake request and response are validated" {
  let key = "dGhlIHNhbXBsZSBub25jZQ=="
  let request = websocket_handshake_request(
    "wss://example.com/chat",
    key,
    ["chat"],
  ).unwrap()
  assert_eq(request.url.scheme, "https")
  assert_eq(request.get_header("Upgrade"), Some("websocket"))
  assert_eq(request.get_header("Sec-WebSocket-Version"), Some("13"))
  assert_eq(request.get_header("Sec-WebSocket-Key"), Some(key))
  assert_eq(request.get_header("Sec-WebSocket-Protocol"), Some("chat"))

  let raw = "HTTP/1.1 101 Switching Protocols\r\n" +
    "Connection: Upgrade\r\nUpgrade: websocket\r\n" +
    "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n"
  let stream = regression_mock_stream(raw, 0, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let client = UnifiedClient::{
    connector: Connector::new(dialer, MockTlsProvider::new("test")),
    options: ClientOptions::new().with_follow_redirects(false),
    redirect_count: 0,
  }
  let http : &HttpClient = client
  let socket = websocket_connect(http, "ws://example.com/chat", key, []).unwrap()
  assert_eq(socket.role(), Client)
  socket.send_text("hi").unwrap()
  socket.close().unwrap()
  assert_false(socket.is_open())
}
