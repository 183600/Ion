///|
fn compression_pseudo_random(size : Int32, seed : Int32) -> Bytes {
  let input = Buffer(size_hint=size)
  let mut state = seed
  let mut i = 0
  while i < size {
    state = (state * 1103515245 + 12345) & 0x7fffffff
    input.write_byte((state >> 16).to_byte())
    i = i + 1
  }
  input.to_bytes()
}

///|
test "raw deflate compressor emits a complete final stream" {
  let data = b"hello hello hello hello raw deflate"
  let raw = deflate_compress_raw(data)
  assert_eq(inflate_deflate(raw, data.length() + 1).unwrap(), data)
  // The final stream must not end with the RFC 7692 sync-flush marker bytes.
  let trailing = raw.length() >= 4
  assert_true(
    !trailing ||
    !(
      raw[raw.length() - 4].to_int() == 0 &&
      raw[raw.length() - 3].to_int() == 0 &&
      raw[raw.length() - 2].to_int() == 0xff &&
      raw[raw.length() - 1].to_int() == 0xff
      ),
  )
}

///|
test "raw deflate roundtrip" {
  let mut seed = 987654321
  let sizes = [
    0, 1, 2, 3, 4, 5, 10, 100, 257, 258, 259, 1000, 4096, 32768, 40000, 100000,
  ]
  for size in sizes {
    let data = compression_pseudo_random(size, seed)
    seed = seed + 1
    let decoded = inflate_deflate(
      deflate_compress_raw(data),
      data.length() + 1,
    ).unwrap()
    assert_eq(decoded.length(), data.length())
    assert_eq(decoded, data)
  }
}

///|
test "zlib compress emits a valid header and adler-32 trailer" {
  // Empty input matches the canonical zlib output byte for byte.
  assert_eq(zlib_compress(b""), b"\x78\x9c\x03\x00\x00\x00\x00\x01")
  let data = b"zlib wrapper roundtrip"
  let wrapped = zlib_compress(data)
  assert_eq(wrapped[0].to_int(), 0x78)
  assert_eq(wrapped[1].to_int(), 0x9c)
  // (CMF << 8 | FLG) must be a multiple of 31 (RFC 1950 §2.2).
  assert_eq(((wrapped[0].to_int() << 8) | wrapped[1].to_int()) % 31, 0)
  assert_eq(inflate(wrapped, data.length() + 1).unwrap(), data)
}

///|
test "zlib compress roundtrip" {
  let mut seed = 246813579
  let sizes = [0, 1, 3, 64, 1000, 32768, 40000, 100000]
  for size in sizes {
    let data = compression_pseudo_random(size, seed)
    seed = seed + 1
    let decoded = inflate(zlib_compress(data), data.length() + 1).unwrap()
    assert_eq(decoded, data)
  }
}

///|
test "gzip compress emits a valid header and crc-32 trailer" {
  // Empty input matches the canonical `gzip -n` output with OS = unknown.
  assert_eq(
    gzip_compress(b""),
    b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\xff\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00",
  )
  let data = b"gzip wrapper roundtrip"
  let wrapped = gzip_compress(data)
  assert_eq(wrapped[0].to_int(), 0x1f)
  assert_eq(wrapped[1].to_int(), 0x8b)
  assert_eq(wrapped[2].to_int(), 0x08)
  assert_eq(wrapped[3].to_int(), 0x00)
  assert_eq(gunzip(wrapped, data.length() + 1).unwrap(), data)
}

///|
test "gzip compress roundtrip" {
  let mut seed = 192837465
  let sizes = [0, 1, 3, 64, 1000, 32768, 40000, 100000]
  for size in sizes {
    let data = compression_pseudo_random(size, seed)
    seed = seed + 1
    let decoded = gunzip(gzip_compress(data), data.length() + 1).unwrap()
    assert_eq(decoded, data)
  }
}

///|
test "gzip compress handles repetitive data at window-scale distances" {
  let pattern = b"0123456789abcdefghijklmnopqrstuvwxyz"
  let input = Buffer(size_hint=pattern.length() * 2000)
  let mut i = 0
  while i < 2000 {
    input.write_bytes(pattern)
    i = i + 1
  }
  let data = input.to_bytes()
  assert_eq(gunzip(gzip_compress(data), data.length() + 1).unwrap(), data)
  assert_eq(inflate(zlib_compress(data), data.length() + 1).unwrap(), data)
}

///|
fn compression_flip_low_bit(data : Bytes, index : Int32) -> Bytes {
  let output = Buffer(size_hint=data.length())
  let mut i = 0
  while i < data.length() {
    let byte = if i == index {
      data[i].to_int() ^ 0x01
    } else {
      data[i].to_int()
    }
    output.write_byte(byte.to_byte())
    i = i + 1
  }
  output.to_bytes()
}

///|
test "compressed output decodes through the response content-coding path" {
  let data = b"request body content coding"
  assert_eq(
    decode_content_encoding("gzip", gzip_compress(data), data.length() + 1).unwrap(),
    data,
  )
  assert_eq(
    decode_content_encoding("deflate", zlib_compress(data), data.length() + 1).unwrap(),
    data,
  )
  // A corrupted trailer must be rejected by the decoders' checksums.
  let good_gzip = gzip_compress(data)
  let bad_gzip = compression_flip_low_bit(good_gzip, good_gzip.length() - 5)
  assert_true(gunzip(bad_gzip, data.length() + 1) is Err(_))
  let good_zlib = zlib_compress(data)
  let bad_zlib = compression_flip_low_bit(good_zlib, good_zlib.length() - 1)
  assert_true(inflate(bad_zlib, data.length() + 1) is Err(_))
}

///|
test "with_gzip_body sets Content-Encoding and compresses the payload" {
  let body = b"payload payload payload payload"
  let request = Request::new(POST, Url::parse("http://example.com/upload").unwrap())
  assert_true(request.headers.contains("Content-Encoding") is false)
  let compressed = request.with_gzip_body(body)
  assert_eq(compressed.get_header("Content-Encoding"), Some("gzip"))
  let sent = compressed.body.unwrap()
  assert_eq(sent[0].to_int(), 0x1f)
  assert_eq(sent[1].to_int(), 0x8b)
  assert_true(sent.length() < body.length() + 32)
  assert_eq(gunzip(sent, body.length() + 1).unwrap(), body)
}

///|
test "with_deflate_body sets Content-Encoding and compresses the payload" {
  let body = b"payload payload payload payload"
  let compressed = Request::new(
    POST,
    Url::parse("http://example.com/upload").unwrap(),
  ).with_deflate_body(body)
  assert_eq(compressed.get_header("Content-Encoding"), Some("deflate"))
  assert_eq(inflate(compressed.body.unwrap(), body.length() + 1).unwrap(), body)
}

///|
test "gzip request bodies are framed on the wire with correct Content-Length" {
  let url = Url::parse("http://example.com/upload").unwrap()
  let body = b"framing framing framing framing framing"
  let stream = regression_mock_stream("", 0, 0)
  let codec = H1Codec::new(stream)
  assert_true(
    codec.encode_request(Request::new(POST, url).with_gzip_body(body)) is Ok(_),
  )
  let wire = @utf8.decode_lossy(stream.output.to_bytes()[:])
  assert_true(wire.contains("Content-Encoding: gzip\r\n"))
  assert_true(
    wire.contains(
      "Content-Length: " + gzip_compress(body).length().to_string() + "\r\n",
      ),
  )
}
