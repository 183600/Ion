///|
test "websocket handshake requires a canonical padded key" {
  let padded = "AAAAAAAAAAAAAAAAAAAAAA=="
  match websocket_handshake_request("ws://example.com/chat", padded, []) {
    Ok(_) => ()
    Err(_) => fail("a canonical WebSocket key was rejected")
  }
  match
    websocket_handshake_request(
      "ws://example.com/chat",
      "AAAAAAAAAAAAAAAAAAAAAA",
      [],
    ) {
    Err(InvalidHeader(name)) => assert_eq(name, "Sec-WebSocket-Key")
    _ => fail("an unpadded WebSocket key was accepted")
  }
}
