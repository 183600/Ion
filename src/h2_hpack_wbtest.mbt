fn hpack_test_hex(text : String) -> Bytes {
  let output = Buffer(size_hint=text.length() / 2)
  let mut index = 0
  while index + 1 < text.length() {
    let high = text.get_char(index).unwrap()
    let low = text.get_char(index + 1).unwrap()
    let high_value = if high >= '0' && high <= '9' {
      high.to_int() - '0'.to_int()
    } else if high >= 'a' && high <= 'f' {
      high.to_int() - 'a'.to_int() + 10
    } else {
      high.to_int() - 'A'.to_int() + 10
    }
    let low_value = if low >= '0' && low <= '9' {
      low.to_int() - '0'.to_int()
    } else if low >= 'a' && low <= 'f' {
      low.to_int() - 'a'.to_int() + 10
    } else {
      low.to_int() - 'A'.to_int() + 10
    }
    output.write_byte((high_value * 16 + low_value).to_byte())
    index = index + 2
  }
  output.to_bytes()
}

fn hpack_test_decode(decoder : HpackDecoder, hex : String) -> Array[(String, String)] {
  decoder.decode(hpack_test_hex(hex)).unwrap()
}

test "hpack decodes RFC 7541 indexed request examples" {
  let decoder = HpackDecoder::new()
  let headers = hpack_test_decode(decoder, "828684410f7777772e6578616d706c652e636f6d")
  assert_eq(headers.length(), 4)
  assert_eq(headers[0], (":method", "GET"))
  assert_eq(headers[1], (":scheme", "http"))
  assert_eq(headers[2], (":path", "/"))
  assert_eq(headers[3], (":authority", "www.example.com"))
}

test "hpack decodes RFC 7541 dynamic table and Huffman examples" {
  let decoder = HpackDecoder::new()
  let _ = hpack_test_decode(decoder, "828684410f7777772e6578616d706c652e636f6d")
  let headers = hpack_test_decode(
    decoder,
    "828684be58086e6f2d6361636865",
  )
  assert_eq(headers.length(), 5)
  assert_eq(headers[3], (":authority", "www.example.com"))
  assert_eq(headers[4], ("cache-control", "no-cache"))

  let headers = hpack_test_decode(
    decoder,
    "828785bf400a637573746f6d2d6b65790c637573746f6d2d76616c7565",
  )
  assert_eq(headers.length(), 5)
  assert_eq(headers[2], (":path", "/index.html"))
  assert_eq(headers[3], (":authority", "www.example.com"))
  assert_eq(headers[4], ("custom-key", "custom-value"))
}

test "hpack decodes RFC 7541 Huffman responses" {
  let decoder = HpackDecoder::with_max_size(256)
  let headers = hpack_test_decode(
    decoder,
    "488264025885aec3771a4b6196d07abe941054d444a8200595040b8166e082a62d1bff6e919d29ad171863c78f0b97c8e9ae82ae43d3",
  )
  assert_eq(headers.length(), 4)
  assert_eq(headers[0], (":status", "302"))
  assert_eq(headers[1], ("cache-control", "private"))
  assert_eq(headers[2], ("date", "Mon, 21 Oct 2013 20:13:21 GMT"))
  assert_eq(headers[3], ("location", "https://www.example.com"))

  let headers = hpack_test_decode(decoder, "4883640effc1c0bf")
  assert_eq(headers.length(), 4)
  assert_eq(headers[0], (":status", "307"))
  assert_eq(headers[1], ("cache-control", "private"))
  assert_eq(headers[2], ("date", "Mon, 21 Oct 2013 20:13:21 GMT"))
  assert_eq(headers[3], ("location", "https://www.example.com"))

  let headers = hpack_test_decode(
    decoder,
    "88c16196d07abe941054d444a8200595040b8166e084a62d1bffc05a839bd9ab77ad94e7821dd7f2e6c7b335dfdfcd5b3960d5af27087f3672c1ab270fb5291f9587316065c003ed4ee5b1063d5007",
  )
  assert_eq(headers.length(), 6)
  assert_eq(headers[0], (":status", "200"))
  assert_eq(headers[1], ("cache-control", "private"))
  assert_eq(headers[2], ("date", "Mon, 21 Oct 2013 20:13:22 GMT"))
  assert_eq(headers[3], ("location", "https://www.example.com"))
  assert_eq(headers[4], ("content-encoding", "gzip"))
  assert_eq(headers[5], ("set-cookie", "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1"))
}

test "hpack encoder round trips literal headers" {
  let headers : Array[(String, String)] = [
    (":method", "GET"),
    (":scheme", "https"),
    (":authority", "example.com"),
    (":path", "/a?b=c"),
    ("accept", "*/*"),
    ("x-test", "hello world"),
    ("x-test", "second"),
  ]
  let decoder = HpackDecoder::new()
  let decoded = decoder.decode(hpack_encode(headers)).unwrap()
  assert_eq(decoded, headers)
}

test "hpack rejects invalid Huffman padding" {
  let decoder = HpackDecoder::new()
  // A literal header with a 1-byte Huffman value consisting only of ones.
  let block = hpack_test_hex("0000ff")
  match decoder.decode(block) {
    Ok(_) => fail("invalid HPACK Huffman padding was accepted")
    Err(_) => ()
  }
}

test "hpack table size updates reset the dynamic table" {
  let decoder = HpackDecoder::new()
  let _ = hpack_test_decode(decoder, "828684410f7777772e6578616d706c652e636f6d")
  let _ = hpack_test_decode(decoder, "828684be58086e6f2d6361636865")
  let headers = hpack_test_decode(decoder, "20828684")
  assert_eq(headers.length(), 3)
  match decoder.decode(hpack_test_hex("be")) {
    Ok(_) => fail("evicted HPACK dynamic entry was still indexed")
    Err(_) => ()
  }
}

test "hpack integer decoding rejects values beyond 31 bits" {
  let (value, next) = hpack_read_integer(hpack_test_hex("7f80ffffff07"), 0, 7).unwrap()
  assert_eq(value, HPACK_MAX_INTEGER)
  assert_eq(next, 6)
  for encoded in ["7f80ffffff08", "7f80ffffff7f"] {
    match hpack_read_integer(hpack_test_hex(encoded), 0, 7) {
      Err(err) => assert_eq(err, ProtocolError("HPACK integer too large"))
      Ok(_) => fail("overflowing HPACK integer was accepted")
    }
  }
}

test "hpack sizes dynamic entries by UTF-8 octets" {
  // x: é is 1 + 2 + 32 = 35 octets. A 34-byte table cannot hold it, but
  // UTF-16 code-unit accounting used to count only 34 and kept the entry.
  let small = HpackDecoder::with_max_size(34)
  let decoded = small.decode(hpack_test_hex("40017802c3a9")).unwrap()
  assert_eq(decoded.length(), 1)
  match small.decode(hpack_test_hex("be")) {
    Ok(_) => fail("oversized HPACK dynamic entry was retained")
    Err(_) => ()
  }

  let fits = HpackDecoder::with_max_size(35)
  let _ = fits.decode(hpack_test_hex("40017802c3a9")).unwrap()
  let indexed = fits.decode(hpack_test_hex("be")).unwrap()
  assert_eq(indexed.length(), 1)
  assert_eq(indexed[0], ("x", "é"))
}

test "hpack accepts strings and header counts within the advertised list size" {
  let large = "a".repeat(70000)
  let large_decoded = HpackDecoder::new().decode(
    hpack_encode([("x-large", large)]),
  ).unwrap()
  assert_eq(large_decoded.length(), 1)
  assert_eq(large_decoded[0].0, "x-large")
  assert_eq(large_decoded[0].1.length(), 70000)

  let fields : Array[(String, String)] = []
  let mut index = 0
  while index < 1001 {
    fields.push(("x-" + index.to_string(), "v"))
    index = index + 1
  }
  let decoded = HpackDecoder::new().decode(hpack_encode(fields)).unwrap()
  assert_eq(decoded.length(), 1001)
}

test "hpack rejects invalid UTF-8 string octets instead of replacing them" {
  match HpackDecoder::new().decode(hpack_test_hex("00017801e9")) {
    Ok(_) => fail("invalid UTF-8 HPACK string was accepted")
    Err(err) => assert_eq(err, ProtocolError("Invalid UTF-8 in HPACK string"))
  }
}
