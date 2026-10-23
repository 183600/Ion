/// RFC 8441 extended CONNECT does not use Sec-WebSocket-Key/Accept, so an
/// HTTP/2 response only needs a successful status and (optionally) the chosen
/// subprotocol.
test "websocket connects through HTTP/2 extended CONNECT" {
  let settings = h2_test_frame(
    H2_FRAME_SETTINGS,
    0,
    0,
    h2_settings_payload([(H2_SETTINGS_ENABLE_CONNECT_PROTOCOL, 1)]),
  )
  let response_headers = hpack_encode([
    (":status", "200"),
    ("sec-websocket-protocol", "chat"),
  ])
  let input = h2_test_concat([
    settings,
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, response_headers),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let client = UnifiedClient::{
    connector: Connector::new(
      dialer,
      H2NegotiatingTlsProvider::{ protocol: Some("h2") },
    ),
    options: ClientOptions::new().with_follow_redirects(false),
    redirect_count: 0,
  }
  let http : &HttpClient = client
  let socket = websocket_connect(
    http,
    "wss://example.com/socket",
    "dGhlIHNhbXBsZSBub25jZQ==",
    ["chat"],
  ).unwrap()
  assert_eq(socket.role(), Client)
}

///|
test "websocket limits unfragmented messages" {
  let input = ws_test_frame(WS_OPCODE_TEXT, true, b"hello")
  let socket = WebSocket::client(ws_test_stream(input)).with_max_message_bytes(4)
  match socket.read_message() {
    Err(ProtocolError(message)) => assert_eq(message, "WebSocket message too large")
    _ => fail("oversized unfragmented message was accepted")
  }
  let outbound = WebSocket::client(ws_test_stream(b"")).with_max_message_bytes(4)
  match outbound.send_text("hello") {
    Err(ProtocolError(message)) => assert_eq(message, "WebSocket message too large")
    _ => fail("oversized outbound message was accepted")
  }
}

///|
test "websocket stops sending after a close frame" {
  let socket = WebSocket::client(ws_test_stream(b""))
  socket.send_close(1000, "bye").unwrap()
  match socket.send_text("late") {
    Err(ConnectionClosed) => ()
    _ => fail("data frame was sent after Close")
  }
  socket.close().unwrap()
  assert_false(socket.is_open())
}

///|
test "websocket receiving a close finishes the handshake" {
  let input = ws_test_frame(WS_OPCODE_CLOSE, true, b"\x03\xe8bye")
  let socket = WebSocket::client(ws_test_stream(input))
  assert_eq(socket.read_message().unwrap(), Close(1000, "bye"))
  assert_false(socket.is_open())
  assert_true(socket.send_text("late") is Err(ConnectionClosed))
}

///|
test "websocket rejects non-minimal payload length encodings" {
  // A one-byte payload must use the 7-bit length form, not the 16-bit form.
  let extended16 = ws_test_stream(b"\x81\x7e\x00\x01X")
  match WebSocket::client(extended16).read_message() {
    Err(ProtocolError(message)) =>
      assert_eq(message, "Invalid WebSocket frame length")
    _ => fail("overlong 16-bit frame length was accepted")
  }
  // Likewise, a one-byte payload must not use the 64-bit form.
  let extended64 = ws_test_stream(
    b"\x81\x7f\x00\x00\x00\x00\x00\x00\x00\x01X",
  )
  match WebSocket::client(extended64).read_message() {
    Err(ProtocolError(message)) =>
      assert_eq(message, "Invalid WebSocket frame length")
    _ => fail("overlong 64-bit frame length was accepted")
  }
}

///|
test "websocket send_frame rejects malformed Close payloads" {
  // One-byte Close payload.
  let short = ws_test_stream(b"")
  match WebSocket::client(short).send_frame(WebSocketFrame::{
    fin: true,
    opcode: WS_OPCODE_CLOSE,
    payload: b"\x03",
  }) {
    Err(InvalidHeader(_)) => ()
    _ => fail("one-byte Close payload was accepted")
  }
  assert_eq(short.output.to_bytes().length(), 0)

  // 1005 is reserved and must never be sent on the wire.
  let reserved = ws_test_stream(b"")
  match WebSocket::client(reserved).send_frame(WebSocketFrame::{
    fin: true,
    opcode: WS_OPCODE_CLOSE,
    payload: b"\x03\xed",
  }) {
    Err(InvalidHeader(_)) => ()
    _ => fail("reserved Close status code was accepted")
  }
  assert_eq(reserved.output.to_bytes().length(), 0)

  // The reason after the status code must be valid UTF-8.
  let invalid_text = ws_test_stream(b"")
  match WebSocket::client(invalid_text).send_frame(WebSocketFrame::{
    fin: true,
    opcode: WS_OPCODE_CLOSE,
    payload: b"\x03\xe8\xff",
  }) {
    Err(InvalidHeader(_)) => ()
    _ => fail("invalid UTF-8 Close reason was accepted")
  }
  assert_eq(invalid_text.output.to_bytes().length(), 0)

  // An empty Close payload and a valid status/reason remain accepted.
  let valid_stream = ws_test_stream(b"")
  let valid = WebSocket::client(valid_stream)
  valid.send_frame(WebSocketFrame::{
    fin: true,
    opcode: WS_OPCODE_CLOSE,
    payload: b"\x03\xe8bye",
  }).unwrap()
  assert_true(valid_stream.output.to_bytes().length() > 0)
}

///|
test "websocket send_frame with a Close frame stops later frames" {
  let socket = WebSocket::client(ws_test_stream(b""))
  socket.send_frame(WebSocketFrame::{
    fin: true,
    opcode: WS_OPCODE_CLOSE,
    payload: b"\x03\xe8bye",
  }).unwrap()
  match socket.send_text("late") {
    Err(ConnectionClosed) => ()
    _ => fail("data frame was sent after a Close frame written by send_frame")
  }
}
