///|
test "Response::text_with_limit bounds decoded text" {
  let compressed = inflate_bytes_of([
    31, 139, 8, 0, 57, 223, 215, 106, 2, 255, 203, 72, 205, 201, 201, 7, 0, 134,
    166, 16, 54, 5, 0, 0, 0,
  ])
  let headers = Headers::new().set("Content-Encoding", "gzip")
  let limited = Response::new(200, headers, response_copy_stream(compressed))
  match limited.text_with_limit(4) {
    Ok(_) => fail("decoded text larger than the explicit limit was accepted")
    Err(_) => ()
  }
  let accepted = Response::new(200, headers, response_copy_stream(compressed))
  assert_eq(accepted.text_with_limit(5).unwrap(), "hello")
}
