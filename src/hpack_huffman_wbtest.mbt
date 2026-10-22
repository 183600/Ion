///|
test "hpack huffman encoding matches RFC 7541 examples" {
  assert_eq(hpack_huffman_encode("302"), b"\x64\x02")
  assert_eq(hpack_huffman_encode("private"), b"\xae\xc3\x77\x1a\x4b")
  assert_eq(
    hpack_huffman_encode("www.example.com"),
    b"\xf1\xe3\xc2\xe5\xf2\x3a\x6b\xa0\xab\x90\xf4\xff",
  )
  assert_eq(hpack_huffman_encode(""), b"")
}

///|
test "hpack encoder round trips huffman-compressed values" {
  let values = [
    "a".repeat(256),
    "café — naïve",
    "custom-value",
    "gzip, deflate, br",
  ]
  let headers : Array[(String, String)] = []
  let mut index = 0
  for value in values {
    headers.push(("x-test-" + index.to_string(), value))
    index = index + 1
  }
  let encoded = hpack_encode(headers)
  let decoded = HpackDecoder::new().decode(encoded).unwrap()
  assert_eq(decoded, headers)
}
