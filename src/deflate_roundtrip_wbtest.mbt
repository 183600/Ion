///|
fn deflate_roundtrip_decode(compressed : Bytes, limit : Int32) -> Bytes {
  let marker = b"\x00\x00\xff\xff\x01\x00\x00\xff\xff"
  let framed = Buffer(size_hint=compressed.length() + marker.length())
  framed.write_bytes(compressed)
  framed.write_bytes(marker)
  inflate_deflate(framed.to_bytes(), limit).unwrap()
}

///|
test "deflate random roundtrip" {
  let mut seed = 123456789
  let sizes = [
    0, 1, 2, 3, 4, 5, 10, 100, 257, 258, 259, 1000, 4096, 32768, 40000, 100000,
  ]
  for size in sizes {
    let input = Buffer(size_hint=size)
    let mut i = 0
    while i < size {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff
      input.write_byte((seed >> 16).to_byte())
      i = i + 1
    }
    let data = input.to_bytes()
    let decoded = deflate_roundtrip_decode(
      deflate_compress(data),
      data.length() + 1,
    )
    assert_eq(decoded.length(), data.length())
    assert_eq(decoded, data)
  }
}

///|
test "deflate structured roundtrip" {
  let patterns = [
    b"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", b"abcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabc",
    b"0123456789abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz",
  ]
  for pattern in patterns {
    let input = Buffer(size_hint=pattern.length() * 1000)
    let mut i = 0
    while i < 1000 {
      input.write_bytes(pattern)
      i = i + 1
    }
    let data = input.to_bytes()
    let decoded = deflate_roundtrip_decode(
      deflate_compress(data),
      data.length() + 1,
    )
    assert_eq(decoded, data)
  }
}
