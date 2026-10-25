///|
test "websocket handshake rejects invalid subprotocol offers" {
  let key = "dGhlIHNhbXBsZSBub25jZQ=="
  let invalid : Array[Array[String]] = [
    [""],
    ["chat", "chat"],
    ["chat", "super chat"],
    ["chat,superchat"],
    ["chat\r\nX-Injected: 1"],
  ]
  for protocols in invalid {
    match websocket_handshake_request("ws://example.com/chat", key, protocols) {
      Err(InvalidHeader(name)) => assert_eq(name, "Sec-WebSocket-Protocol")
      _ => fail("an invalid subprotocol offer was accepted")
    }
  }
}

///|
test "websocket handshake accepts valid subprotocol offers" {
  let key = "dGhlIHNhbXBsZSBub25jZQ=="
  let request = websocket_handshake_request(
    "ws://example.com/chat",
    key,
    ["chat", "superchat.v2"],
  ).unwrap()
  assert_eq(
    request.get_header("Sec-WebSocket-Protocol"),
    Some("chat, superchat.v2"),
  )
}
