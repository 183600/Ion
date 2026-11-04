///|
test "automatic decoding is not enabled for an HTTP/2 extended CONNECT tunnel" {
  let settings = h2_test_frame(
    H2_FRAME_SETTINGS,
    0,
    0,
    h2_settings_payload([
      (H2_SETTINGS_INITIAL_WINDOW_SIZE, H2_DEFAULT_WINDOW_SIZE),
      (H2_SETTINGS_ENABLE_CONNECT_PROTOCOL, 1),
    ]),
  )
  let response_headers = hpack_encode([
    (":status", "200"),
    ("content-encoding", "gzip"),
  ])
  let input = h2_test_concat([
    settings,
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, response_headers),
    h2_test_frame(H2_FRAME_DATA, H2_FLAG_END_STREAM, 1, b"tunnel"),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0, }
  let provider = H2NegotiatingTlsProvider::{ protocol: Some("h2"), }
  let client = UnifiedClient::with_transport(
    dialer,
    provider,
    ClientOptions::new().with_follow_redirects(false).with_auto_decompress(true),
  )
  let request = Request::from_url(GET, "https://example.com/socket")
    .unwrap()
    .with_upgrade("websocket")
  let response = client.request(request).unwrap()
  assert_eq(response.status, 200)
  assert_false(response.auto_decompress())
  assert_eq(response.read_body().unwrap(), b"tunnel")
}

///|
test "automatic decoding is not enabled for an unsolicited HTTP/1.1 101" {
  let stream = regression_mock_stream(
    "HTTP/1.1 101 Switching Protocols\r\n\r\n", 0, 0,
  )
  let dialer = RegressionMockDialer::{ stream, count: 0, }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let client = UnifiedClient::{
    connector,
    options: ClientOptions::new()
    .with_follow_redirects(false)
    .with_auto_decompress(true),
    redirect_count: 0,
  }
  let response = client.get("http://example.com/socket").unwrap()
  assert_eq(response.status, 101)
  assert_false(response.auto_decompress())
  let _ = client.close_all()
}
