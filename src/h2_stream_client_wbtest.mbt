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

///|
test "invalid extended CONNECT leaves the HTTP/2 session reusable" {
  let settings = h2_test_frame(
    H2_FRAME_SETTINGS,
    0,
    0,
    h2_settings_payload([
      (H2_SETTINGS_INITIAL_WINDOW_SIZE, H2_DEFAULT_WINDOW_SIZE),
      (H2_SETTINGS_ENABLE_CONNECT_PROTOCOL, 1),
    ]),
  )
  let headers = hpack_encode([(":status", "200"), ("x-next", "ok")])
  let input = h2_test_concat([
    settings,
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM, 1, headers),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let provider = H2NegotiatingTlsProvider::{ protocol: Some("h2") }
  let client = UnifiedClient::with_transport(
    dialer,
    provider,
    ClientOptions::new().with_follow_redirects(false),
  )
  let invalid = Request::new(POST, Url::parse("https://example.com/socket").unwrap())
    .with_upgrade("websocket")
  match client.request(invalid) {
    Ok(_) => fail("extended CONNECT with POST was accepted")
    Err(err) =>
      assert_eq(
        err,
        ProtocolError("Extended CONNECT requires a GET or CONNECT request"),
      )
  }
  assert_eq(dialer.count, 1)
  assert_true(stream.is_open)
  let response = client.get("https://example.com/next").unwrap()
  assert_eq(response.status, 200)
  assert_eq(response.get_header("x-next"), Some("ok"))
  assert_eq(dialer.count, 1)
  let _ = client.close_all()
}
