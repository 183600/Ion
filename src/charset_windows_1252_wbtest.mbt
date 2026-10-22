test "windows-1252 maps undefined byte positions to replacement characters" {
  let response = charset_text_response(
    "text/plain; charset=windows-1252",
    charset_test_bytes([0x41, 0x81, 0x8D, 0x8F, 0x90, 0x9D, 0x42]),
  )
  assert_eq(
    response.text().unwrap(),
    "A\u{fffd}\u{fffd}\u{fffd}\u{fffd}\u{fffd}B",
  )
}
