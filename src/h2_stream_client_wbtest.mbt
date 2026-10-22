///|
test "H2ClientConnection implements HttpClient on a persistent session" {
  let settings = h2_test_frame(
    H2_FRAME_SETTINGS,
    0,
    0,
    h2_settings_payload([(H2_SETTINGS_INITIAL_WINDOW_SIZE, H2_DEFAULT_WINDOW_SIZE)]),
  )
  let headers = hpack_encode([(":status", "200")])
  let input = h2_test_concat([
    settings,
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, headers),
    h2_test_frame(H2_FRAME_DATA, H2_FLAG_END_STREAM, 1, b"ok"),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let client : &HttpClient = connection
  let response = client.get("https://example.com/").unwrap()
  assert_eq(response.version, "HTTP/2")
  assert_eq(response.text().unwrap(), "ok")
}
