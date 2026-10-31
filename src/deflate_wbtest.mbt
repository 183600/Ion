fn deflate_test_decode(compressed : Bytes, limit : Int) -> Bytes {
  let marker = b"\x00\x00\xff\xff\x01\x00\x00\xff\xff"
  let framed = Buffer(size_hint=compressed.length() + marker.length())
  framed.write_bytes(compressed)
  framed.write_bytes(marker)
  inflate_deflate(framed.to_bytes(), limit).unwrap()
}

///|
test "deflate round-trips empty and short inputs" {
  assert_eq(deflate_test_decode(deflate_compress(b""), 16), b"")
  assert_eq(deflate_test_decode(deflate_compress(b"a"), 16), b"a")
  assert_eq(deflate_test_decode(deflate_compress(b"hello"), 16), b"hello")
}

///|
test "deflate round-trips every byte value" {
  let input = Buffer(size_hint=256)
  let mut value = 0
  while value < 256 {
    input.write_byte(value.to_byte())
    value = value + 1
  }
  let data = input.to_bytes()
  assert_eq(deflate_test_decode(deflate_compress(data), 512), data)
}

///|
test "deflate compresses repeated text" {
  let source = @utf8.encode("the quick brown fox jumps over the lazy dog. ")
  let input = Buffer(size_hint=source.length() * 64)
  let mut repeat = 0
  while repeat < 64 {
    input.write_bytes(source)
    repeat = repeat + 1
  }
  let data = input.to_bytes()
  let compressed = deflate_compress(data)
  assert_true(compressed.length() < data.length())
  assert_eq(deflate_test_decode(compressed, data.length()), data)
}

///|
test "websocket compresses outgoing messages when negotiated" {
  let source = @utf8.encode("0123456789abcdef")
  let input = Buffer(size_hint=source.length() * 32)
  let mut repeat = 0
  while repeat < 32 {
    input.write_bytes(source)
    repeat = repeat + 1
  }
  let text = @utf8.decode_lossy(input.to_bytes()[:])
  let stream = ws_test_stream(b"")
  let socket = WebSocket::new(stream, Client).with_permessage_deflate(true)
  socket.send_text(text).unwrap()
  let wire = stream.output.to_bytes()
  assert_true((wire[0].to_int() & 0x40) != 0)
  assert_true(wire.length() < @utf8.encode(text).length())
  let peer = WebSocket::new(ws_test_stream(wire), Server)
    .with_permessage_deflate(true)
  assert_eq(peer.read_message().unwrap(), Text(text))
}

///|
test "websocket leaves small outgoing messages uncompressed" {
  let stream = ws_test_stream(b"")
  let socket = WebSocket::new(stream, Client).with_permessage_deflate(true)
  socket.send_text("hi").unwrap()
  let wire = stream.output.to_bytes()
  assert_eq(wire[0].to_int() & 0x40, 0)
}
