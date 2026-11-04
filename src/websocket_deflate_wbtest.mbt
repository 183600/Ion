///|
fn ws_deflate_test_frame(
  rsv1 : Bool,
  fin : Bool,
  opcode : Int32,
  payload : Bytes,
) -> Bytes {
  let output = Buffer(size_hint=payload.length() + 4)
  output.write_byte(
    ((if fin { 0x80 } else { 0x00 }) | (if rsv1 { 0x40 } else { 0x00 }) | opcode).to_byte(),
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
fn ws_deflate_test_client(raw : Bytes) -> (UnifiedClient, RegressionMockStream) {
  let stream = ws_test_stream(raw)
  let dialer = RegressionMockDialer::{ stream, count: 0, }
  let client = UnifiedClient::{
    connector: Connector::new(dialer, MockTlsProvider::new("test")),
    options: ClientOptions::new().with_follow_redirects(false),
    redirect_count: 0,
  }
  (client, stream)
}

///|
test "websocket handshake offers permessage-deflate only when requested" {
  let key = "dGhlIHNhbXBsZSBub25jZQ=="
  let plain = websocket_handshake_request("ws://example.com/chat", key, []).unwrap()
  assert_true(plain.get_header("Sec-WebSocket-Extensions") is None)
  let compressed = websocket_handshake_request(
    "ws://example.com/chat",
    key,
    [],
    permessage_deflate=true,
  ).unwrap()
  assert_eq(
    compressed.get_header("Sec-WebSocket-Extensions"),
    Some(
      "permessage-deflate; client_no_context_takeover; server_no_context_takeover",
    ),
  )
}

///|
test "inflate_deflate decodes a bare DEFLATE message" {
  let compressed = b"\xf2\x48\xcd\xc9\xc9\x07\x00"
  let framed = ws_test_concat([
    compressed, b"\x00\x00\xff\xff\x01\x00\x00\xff\xff",
  ])
  assert_eq(inflate_deflate(framed, 32).unwrap(), b"Hello")
}

///|
test "websocket decodes a compressed server text message" {
  let key = "dGhlIHNhbXBsZSBub25jZQ=="
  let compressed = b"\xf2\x48\xcd\xc9\xc9\x07\x00"
  let header = "HTTP/1.1 101 Switching Protocols\r\n" +
    "Connection: Upgrade\r\nUpgrade: websocket\r\n" +
    "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" +
    "Sec-WebSocket-Extensions: permessage-deflate; server_no_context_takeover\r\n\r\n"
  let raw = ws_test_concat([
    @utf8.encode(header),
    ws_deflate_test_frame(true, true, WS_OPCODE_TEXT, compressed),
  ])
  let (client, _) = ws_deflate_test_client(raw)
  let http : &HttpClient = client
  let socket = websocket_connect(
    http,
    "ws://example.com/chat",
    key,
    [],
    permessage_deflate=true,
  ).unwrap()
  assert_true(socket.permessage_deflate())
  assert_eq(socket.read_message().unwrap(), Text("Hello"))
}

///|
test "websocket decodes a fragmented compressed message" {
  let compressed = b"\xf2\x48\xcd\xc9\xc9\x07\x00"
  let raw = ws_test_concat([
    ws_deflate_test_frame(
      true,
      false,
      WS_OPCODE_TEXT,
      compressed.exact_view(start=0, end=3).to_owned(),
    ),
    ws_deflate_test_frame(
      false,
      true,
      WS_OPCODE_CONTINUATION,
      compressed.exact_view(start=3, end=compressed.length()).to_owned(),
    ),
  ])
  let socket = WebSocket::new(ws_test_stream(raw), Client).with_permessage_deflate(
    true,
  )
  assert_eq(socket.read_message().unwrap(), Text("Hello"))
}

///|
test "websocket enforces the decompressed message limit" {
  let compressed = b"\xf2\x48\xcd\xc9\xc9\x07\x00"
  let raw = ws_deflate_test_frame(true, true, WS_OPCODE_TEXT, compressed)
  let socket = WebSocket::new(ws_test_stream(raw), Client)
    .with_permessage_deflate(true)
    .with_max_message_bytes(4)
  match socket.read_message() {
    Err(ProtocolError(message)) =>
      assert_eq(message, "WebSocket message too large")
    _ => fail("an oversized compressed message was accepted")
  }
}

///|
test "websocket rejects compressed messages without server_no_context_takeover" {
  let key = "dGhlIHNhbXBsZSBub25jZQ=="
  let raw = @utf8.encode(
    "HTTP/1.1 101 Switching Protocols\r\n" +
    "Connection: Upgrade\r\nUpgrade: websocket\r\n" +
    "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" +
    "Sec-WebSocket-Extensions: permessage-deflate\r\n\r\n",
  )
  let (client, stream) = ws_deflate_test_client(raw)
  let http : &HttpClient = client
  match
    websocket_connect(
      http,
      "ws://example.com/chat",
      key,
      [],
      permessage_deflate=true,
    ) {
    Err(ProtocolError(message)) =>
      assert_eq(message, "Invalid WebSocket handshake response")
    _ => fail("context-takeover compression was accepted")
  }
  assert_false(stream.is_open)
}

///|
test "websocket rejects unsupported compression parameters" {
  let key = "dGhlIHNhbXBsZSBub25jZQ=="
  for
    extension in [
      "permessage-deflate; server_max_window_bits=0; server_no_context_takeover",
      "permessage-deflate; server_max_window_bits=7; server_no_context_takeover",
      "permessage-deflate; server_max_window_bits=16; server_no_context_takeover",
      "permessage-deflate; server_max_window_bits=010; server_no_context_takeover",
      "permessage-deflate; server_max_window_bits=; server_no_context_takeover",
      "permessage-deflate; server_max_window_bits=x; server_no_context_takeover",
      "permessage-deflate; server_max_window_bits=10; server_max_window_bits=10; server_no_context_takeover",
      "permessage-deflate; client_max_window_bits=10; server_no_context_takeover",
      "permessage-deflate; server_no_context_takeover; server_no_context_takeover",
      "permessage-deflate; server_no_context_takeover; unknown_parameter", "permessage-deflate; server_no_context_takeover, permessage-deflate",
    ] {
    let header = "HTTP/1.1 101 Switching Protocols\r\n" +
      "Connection: Upgrade\r\nUpgrade: websocket\r\n" +
      "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" +
      "Sec-WebSocket-Extensions: " +
      extension +
      "\r\n\r\n"
    let (client, stream) = ws_deflate_test_client(@utf8.encode(header))
    let http : &HttpClient = client
    match
      websocket_connect(
        http,
        "ws://example.com/chat",
        key,
        [],
        permessage_deflate=true,
      ) {
      Err(ProtocolError(message)) =>
        assert_eq(message, "Invalid WebSocket handshake response")
      _ => fail("an invalid compression parameter was accepted")
    }
    assert_false(stream.is_open)
  }
}

///|
test "websocket accepts a server-selected window size it did not offer" {
  let key = "dGhlIHNhbXBsZSBub25jZQ=="
  for bits in ["8", "10", "12", "15"] {
    let header = "HTTP/1.1 101 Switching Protocols\r\n" +
      "Connection: Upgrade\r\nUpgrade: websocket\r\n" +
      "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" +
      "Sec-WebSocket-Extensions: permessage-deflate; server_max_window_bits=" +
      bits +
      "; server_no_context_takeover\r\n\r\n"
    let raw = ws_test_concat([
      @utf8.encode(header),
      ws_test_frame(WS_OPCODE_TEXT, true, @utf8.encode("hi")),
    ])
    let (client, _) = ws_deflate_test_client(raw)
    let http : &HttpClient = client
    let socket = websocket_connect(
      http,
      "ws://example.com/chat",
      key,
      [],
      permessage_deflate=true,
    ).unwrap()
    assert_true(socket.permessage_deflate())
    assert_eq(socket.read_message().unwrap(), Text("hi"))
  }
}

///|
test "websocket accepts a server that declines compression" {
  let key = "dGhlIHNhbXBsZSBub25jZQ=="
  let header = "HTTP/1.1 101 Switching Protocols\r\n" +
    "Connection: Upgrade\r\nUpgrade: websocket\r\n" +
    "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n"
  let raw = ws_test_concat([
    @utf8.encode(header),
    ws_test_frame(WS_OPCODE_TEXT, true, @utf8.encode("hi")),
  ])
  let (client, _) = ws_deflate_test_client(raw)
  let http : &HttpClient = client
  let socket = websocket_connect(
    http,
    "ws://example.com/chat",
    key,
    [],
    permessage_deflate=true,
  ).unwrap()
  assert_false(socket.permessage_deflate())
  assert_eq(socket.read_message().unwrap(), Text("hi"))
}

///|
test "websocket rejects RSV1 on a continuation or control frame" {
  for
    raw in [
      ws_deflate_test_frame(true, true, WS_OPCODE_CONTINUATION, b""),
      ws_deflate_test_frame(true, true, WS_OPCODE_PING, b""),
    ] {
    let socket = WebSocket::new(ws_test_stream(raw), Client).with_permessage_deflate(
      true,
    )
    match socket.read_message() {
      Err(ProtocolError(message)) =>
        assert_eq(message, "Invalid WebSocket RSV1 bit")
      _ => fail("RSV1 on a non-initial data frame was accepted")
    }
  }
}

///|
test "websocket leaves outgoing messages uncompressed" {
  let stream = ws_test_stream(b"")
  let socket = WebSocket::new(stream, Client).with_permessage_deflate(true)
  socket.send_text("hello").unwrap()
  let wire = stream.output.to_bytes()
  assert_eq(wire[0], b'\x81')
}
