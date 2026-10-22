/// Deterministic byte-level fuzzing for the HTTP/2/Huffman/cookie parsers. The
/// hand-written suites cover protocol cases; these checks make sure arbitrary
/// peer-controlled bytes cannot panic or make a parser loop.
fn audit_fuzz_next(seed : UInt64) -> UInt64 {
  seed * 2862933555777941757UL + 3037000493UL
}

///|
fn audit_fuzz_bytes(seed : UInt64, max_length : Int) -> (UInt64, Bytes) {
  let mut seed = seed
  seed = audit_fuzz_next(seed)
  let length = (seed % (max_length + 1).to_uint64()).to_int()
  let output = Array::make(length, b'\x00')
  let mut index = 0
  while index < length {
    seed = audit_fuzz_next(seed)
    output[index] = ((seed >> 24) & 0xff).to_byte()
    index = index + 1
  }
  (seed, Bytes::from_array(output[:]))
}

///|
test "fuzz: arbitrary HPACK blocks never panic" {
  let mut seed = 0x5eed1234UL
  let mut index = 0
  while index < 3000 {
    let (next_seed, block) = audit_fuzz_bytes(seed, 96)
    seed = next_seed
    let decoder = HpackDecoder::new()
    match decoder.decode(block) {
      Ok(fields) => {
        for field in fields {
          let (name, _value) = field
          assert_true(name.length() > 0)
        }
      }
      Err(_) => ()
    }
    index = index + 1
  }
}

///|
test "fuzz: arbitrary HTTP/2 frames never panic" {
  let mut seed = 0x1eafc0deUL
  let url = Url::parse("https://example.com/").unwrap()
  let mut index = 0
  while index < 800 {
    let (next_seed, tail) = audit_fuzz_bytes(seed, 320)
    seed = next_seed
    let input = h2_test_concat([h2_test_settings(), tail])
    let stream = h2_frame_mock_stream(input, 0)
    match H2ClientConnection::new(stream) {
      Ok(connection) => {
        let _ = connection.request(Request::new(GET, url))
      }
      Err(_) => ()
    }
    index = index + 1
  }
}

///|
test "fuzz: arbitrary Set-Cookie values never panic" {
  let mut seed = 0xc00c1eUL
  let jar = CookieJar::new()
  let url = Url::parse("https://example.com/a/b").unwrap()
  let mut index = 0
  while index < 3000 {
    let (next_seed, raw) = audit_fuzz_bytes(seed, 160)
    seed = next_seed
    let text = @utf8.decode_lossy(raw[:])
    jar.store_at(url, text, index.to_uint64())
    let _ = jar.cookie_header_at(url, index.to_uint64())
    index = index + 1
  }
  assert_true(jar.length() >= 0)
}
