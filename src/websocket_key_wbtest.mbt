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

///|
test "generated websocket keys are canonical 16-byte nonces" {
  match websocket_generate_key() {
    Some(key) => {
      let decoded = @base64.decode(key) catch {
        _ => fail("generated WebSocket key is not base64")
      }
      assert_eq(decoded.length(), 16)
      assert_eq(key, @base64.encode(decoded))
      assert_true(valid_websocket_key(key))
    }
    // The wasm-gc target exposes no entropy source; a missing platform RNG is
    // reported as `None` instead of silently reusing a weak key.
    None => ()
  }
}

///|
#cfg(target="native")
test "native websocket key generation uses platform entropy" {
  assert_true(websocket_generate_key() is Some(_))
}

///|
#cfg(target="js")
test "JavaScript websocket key generation uses platform entropy" {
  assert_true(websocket_generate_key() is Some(_))
}
