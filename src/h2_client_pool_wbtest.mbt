///|
test "http2 header-list rejection preserves the pooled session" {
  let first = hpack_encode([(":status", "200"), ("x-request", "first")])
  let second = hpack_encode([(":status", "201"), ("x-request", "second")])
  let input = h2_test_concat([
    h2_test_frame(
      H2_FRAME_SETTINGS,
      0,
      0,
      h2_settings_payload([(H2_SETTINGS_MAX_HEADER_LIST_SIZE, 300)]),
    ),
    h2_test_frame(
      H2_FRAME_HEADERS,
      H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM,
      1,
      first,
    ),
    h2_test_frame(
      H2_FRAME_HEADERS,
      H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM,
      3,
      second,
    ),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0, }
  let provider = H2NegotiatingTlsProvider::{ protocol: Some("h2") }
  let client = UnifiedClient::with_transport(
    dialer,
    provider,
    ClientOptions::new().with_follow_redirects(false),
  )
  let url = "https://example.com/path"
  assert_eq(client.get(url).unwrap().status, 200)

  let mut oversized_value = ""
  while oversized_value.length() < 200 {
    oversized_value = oversized_value + "a"
  }
  let oversized = Request::new(GET, Url::parse(url).unwrap())
    .with_header("x-oversized", oversized_value)
  match client.request(oversized) {
    Ok(_) => fail("oversized HTTP/2 request header list was accepted")
    Err(err) =>
      assert_eq(err, ProtocolError("HTTP/2 request header list too large"))
  }
  // The rejected request never opened a stream, so the existing session must
  // stay pooled instead of forcing a new connection.
  assert_eq(dialer.count, 1)
  assert_true(stream.is_open)

  let reused = client.get(url).unwrap()
  assert_eq(reused.status, 201)
  assert_eq(reused.headers.get("x-request"), Some("second"))
  assert_eq(dialer.count, 1)
  let _ = client.close_all()
}
