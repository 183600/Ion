///|
test "websocket rejects extensions the client did not offer" {
  let key = "dGhlIHNhbXBsZSBub25jZQ=="
  let raw = "HTTP/1.1 101 Switching Protocols\r\n" +
    "Connection: Upgrade\r\nUpgrade: websocket\r\n" +
    "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" +
    "Sec-WebSocket-Extensions: permessage-deflate\r\n\r\n"
  let stream = regression_mock_stream(raw, 0, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let client = UnifiedClient::{
    connector: Connector::new(dialer, MockTlsProvider::new("test")),
    options: ClientOptions::new().with_follow_redirects(false),
    redirect_count: 0,
  }
  let http : &HttpClient = client
  match websocket_connect(http, "ws://example.com/chat", key, []) {
    Err(ProtocolError(message)) =>
      assert_eq(message, "Invalid WebSocket handshake response")
    _ => fail("an extension the client never offered was accepted")
  }
  assert_false(stream.is_open)
}
