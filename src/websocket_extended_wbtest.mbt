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
