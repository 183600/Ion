test "option-only client builders keep an independent pool" {
  let raw = "HTTP/1.1 204 No Content\r\n\r\n"
  let stream = regression_mock_stream(raw, 0, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let original = UnifiedClient::{
    connector: Connector::new(dialer, MockTlsProvider::new("test")),
    options: ClientOptions::new().with_follow_redirects(false),
    redirect_count: 0,
  }
  let _ = original.get("http://example.com/").unwrap()
  assert_eq(original.idle_connection_count(), 1)

  let derived : Array[UnifiedClient] = [
    original.with_user_agent("Tuned/1.0"),
    original.with_default_header("X-Test", "1"),
    original.with_default_headers(Headers::new().set("X-Test", "1")),
    original.with_follow_redirects(true),
    original.with_max_redirects(1),
    original.with_max_response_body_bytes(1024),
    original.with_http2_streaming(true),
  ]
  for client in derived {
    assert_eq(client.idle_connection_count(), 0)
    assert_true(client.close_all() is Ok(_))
    assert_true(stream.is_open)
    assert_eq(original.idle_connection_count(), 1)
  }

  assert_true(original.close_all() is Ok(_))
  assert_false(stream.is_open)
}
