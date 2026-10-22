///|
fn fuzz_next(seed : UInt64) -> UInt64 {
  seed * 6364136223846793005UL + 1442695040888963407UL
}

///|
test "fuzz: random response and URL inputs never panic" {
  let alphabet = "GET / HTTP/1.1\r\n:;=,abc%0123456789[]@?#.-_ \t\"<>\\"
  let mut seed = 0x12345678UL
  for _ in 0..<4000 {
    seed = fuzz_next(seed)
    let length = (seed % 160UL).to_int()
    let builder = Buffer(size_hint=length)
    for _ in 0..<length {
      seed = fuzz_next(seed)
      let index = (seed % (alphabet.length()).to_uint64()).to_int()
      builder.write_byte(alphabet.get_char(index).unwrap().to_uint().to_byte())
    }
    let raw = @utf8.decode_lossy(builder.to_bytes()[:])
    let _ = Url::parse(raw)
    let stream = regression_mock_stream(raw, 0, 0)
    match H1Codec::new(stream).decode_response() {
      Ok(response) => assert_true(response.status >= 100 && response.status <= 599)
      Err(_) => ()
    }
  }
}

///|
test "fuzz: mutated valid responses never panic" {
  let base = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\nSet-Cookie: a=b; Path=/; Domain=example.com; Max-Age=10\r\nConnection: keep-alive\r\n\r\n5\r\nhello\r\n0\r\n\r\n"
  let mutation_chars = "\r\n:;=,abc%0123456789[]@?#.-_ "
  let mut seed = 0xabcdef01UL
  let url = Url::parse("http://example.com/").unwrap()
  for _ in 0..<2000 {
    let chars = base.to_array()
    seed = fuzz_next(seed)
    let edits = (seed % 8UL).to_int() + 1
    let mut text = ""
    for _ in 0..<edits {
      seed = fuzz_next(seed)
      let mode = (seed % 3UL).to_int()
      let position = ((seed / 7UL) % (chars.length()).to_uint64()).to_int()
      if mode == 0 && chars.length() > 1 {
        let _ = chars.remove(position)
      } else if mode == 1 {
        seed = fuzz_next(seed)
        let index = (seed % (mutation_chars.length()).to_uint64()).to_int()
        let _ = chars.insert(position, mutation_chars.get_char(index).unwrap())
      } else if position < chars.length() {
        seed = fuzz_next(seed)
        let index = (seed % (mutation_chars.length()).to_uint64()).to_int()
        chars[position] = mutation_chars.get_char(index).unwrap()
      }
    }
    for ch in chars {
      text = text + ch.to_string()
    }
    let _ = Url::parse(text)
    let stream = regression_mock_stream(text, 0, 0)
    let codec = H1Codec::new(stream)
    match codec.decode_response() {
      Ok(response) => {
        assert_true(response.status >= 100 && response.status <= 599)
        let body = response.text()
        let _ = body
      }
      Err(_) => ()
    }
    let jar = CookieJar::new()
    let _ = jar.store(url, text)
  }
}
