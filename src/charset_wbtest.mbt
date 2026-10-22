/// Response text decoding honours the Content-Type charset parameter.

fn charset_test_bytes(values : Array[Int]) -> Bytes {
  let output = Buffer(size_hint=values.length())
  for value in values {
    output.write_byte(value.to_byte())
  }
  output.to_bytes()
}

fn charset_text_response(content_type : String, body : Bytes) -> Response {
  let stream = RegressionMockStream::{
    input: body,
    offset: 0,
    output: @buffer.new(size_hint=16),
    max_read: 0,
    max_write: 0,
    is_open: true,
    last_timeout: 0,
  }
  let headers = Headers::new().add("Content-Type", content_type)
  Response::new(200, headers, stream)
}

test "text defaults to UTF-8 when no charset is declared" {
  let body = @utf8.encode("h\u{e9}llo")
  let response = charset_text_response("text/plain", body)
  assert_eq(response.charset(), None)
  assert_eq(response.text().unwrap(), "h\u{e9}llo")
}

test "text decodes ISO-8859-1 bodies" {
  let response = charset_text_response(
    "text/plain; charset=ISO-8859-1",
    charset_test_bytes([0x68, 0xE9, 0x6C, 0x6C, 0x6F]),
  )
  assert_eq(response.charset(), Some("ISO-8859-1"))
  assert_eq(response.text().unwrap(), "h\u{e9}llo")
}

test "text decodes quoted charset parameters" {
  let response = charset_text_response(
    "text/plain; charset=\"windows-1252\"",
    charset_test_bytes([0x80, 0x20, 0x41]),
  )
  assert_eq(response.text().unwrap(), "\u{20ac} A")
  let quoted_utf8 = charset_text_response(
    "text/plain; charset=\"utf-8\"",
    @utf8.encode("ok"),
  )
  assert_eq(quoted_utf8.text().unwrap(), "ok")
}

test "text decodes Windows-1252 punctuation" {
  let response = charset_text_response(
    "text/plain; charset=cp1252",
    charset_test_bytes([0x93, 0x48, 0x69, 0x94]),
  )
  assert_eq(response.text().unwrap(), "\u{201c}Hi\u{201d}")
}

test "text maps non-ASCII bytes in US-ASCII bodies to replacement characters" {
  let response = charset_text_response(
    "text/plain; charset=us-ascii",
    charset_test_bytes([0x41, 0x80, 0x42]),
  )
  assert_eq(response.text().unwrap(), "A\u{fffd}B")
}

test "text decodes UTF-16 with a byte-order mark" {
  let little = charset_text_response(
    "text/plain; charset=utf-16",
    charset_test_bytes([0xFF, 0xFE, 0x68, 0x00, 0x69, 0x00]),
  )
  assert_eq(little.text().unwrap(), "hi")
  let big = charset_text_response(
    "text/plain; charset=utf-16be",
    charset_test_bytes([0xFE, 0xFF, 0x00, 0x68, 0x00, 0x69]),
  )
  assert_eq(big.text().unwrap(), "hi")
}

test "text decodes explicit UTF-16 endianness and surrogates" {
  let little = charset_text_response(
    "text/plain; charset=utf-16le",
    charset_test_bytes([0x3D, 0xD8, 0x00, 0xDE]),
  )
  assert_eq(little.text().unwrap(), "\u{1f600}")
  let big = charset_text_response(
    "text/plain; charset=utf-16",
    charset_test_bytes([0x00, 0x68, 0x00, 0x69]),
  )
  assert_eq(big.text().unwrap(), "hi")
}

test "text falls back to UTF-8 for unknown charsets" {
  let response = charset_text_response(
    "text/plain; charset=made-up",
    @utf8.encode("h\u{e9}"),
  )
  assert_eq(response.text().unwrap(), "h\u{e9}")
}

test "charset parsing ignores other parameters and empty values" {
  let response = charset_text_response(
    "text/plain; boundary=x; charset=utf-8; format=flowed",
    @utf8.encode("ok"),
  )
  assert_eq(response.charset(), Some("utf-8"))
  let empty = charset_text_response("text/plain; charset=", @utf8.encode("ok"))
  assert_eq(empty.charset(), None)
  let no_header = Response::new(
    200,
    Headers::new(),
    RegressionMockStream::{
      input: b"ok",
      offset: 0,
      output: @buffer.new(size_hint=16),
      max_read: 0,
      max_write: 0,
      is_open: true,
      last_timeout: 0,
    },
  )
  assert_eq(no_header.charset(), None)
}

test "charset parameter ignores charset text inside quoted parameters" {
  let response = charset_text_response(
    "text/plain; boundary=\"x;charset=utf-8\"; charset=iso-8859-1",
    charset_test_bytes([0x68, 0xE9, 0x6C, 0x6C, 0x6F]),
  )
  assert_eq(response.charset(), Some("iso-8859-1"))
  assert_eq(response.text().unwrap(), "h\u{e9}llo")
}

test "quoted charset values honor quoted-pair escapes" {
  let response = charset_text_response(
    "text/plain; charset=\"iso\\-8859-1\"",
    charset_test_bytes([0x68, 0xE9, 0x6C, 0x6C, 0x6F]),
  )
  assert_eq(response.charset(), Some("iso-8859-1"))
  assert_eq(response.text().unwrap(), "h\u{e9}llo")
}

test "astral text in an earlier quoted parameter does not hide charset" {
  let response = charset_text_response(
    "text/plain; boundary=\"\u{1f642};charset=utf-8\"; charset=iso-8859-1",
    charset_test_bytes([0x68, 0xE9, 0x6C, 0x6C, 0x6F]),
  )
  assert_eq(response.charset(), Some("iso-8859-1"))
  assert_eq(response.text().unwrap(), "h\u{e9}llo")
}

test "explicit UTF-16 endianness is not overridden by an opposite BOM" {
  // RFC 2781 §4.1: text labelled UTF-16BE is always big-endian. FF FE is
  // therefore U+FFFE (an error), not an LE BOM that swaps the remaining text.
  let big = charset_text_response(
    "text/plain; charset=utf-16be",
    charset_test_bytes([0xFF, 0xFE, 0x00, 0x41]),
  )
  assert_eq(big.text().unwrap(), "\u{fffd}A")
  // The matching BOM for an explicit label is still consumed.
  let big_bom = charset_text_response(
    "text/plain; charset=utf-16be",
    charset_test_bytes([0xFE, 0xFF, 0x00, 0x68, 0x00, 0x69]),
  )
  assert_eq(big_bom.text().unwrap(), "hi")
}
