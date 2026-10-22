/// `Connector::connect` promises that the returned stream is also reachable
/// through the pool. An ALPN-negotiated h2 stream needs the same treatment even
/// though its client preface is only sent when the session is checked out.
test "connector connect keeps a negotiated HTTP/2 stream closeable" {
  let stream = h2_frame_mock_stream(b"", 0)
  let connector = Connector::new(
    RegressionMockDialer::{ stream, count: 0 },
    H2NegotiatingTlsProvider::{ protocol: Some("h2") },
  ).with_http2(true)
  let url = Url::parse("https://example.com/").unwrap()
  let _ = connector.connect(url).unwrap()
  assert_true(stream.is_open)
  assert_eq(connector.idle_connection_count(), 1)
  assert_eq(connector.connection_count(), 1)
  assert_true(connector.close_all() is Ok(_))
  assert_false(stream.is_open)
}

test "connector connect dials fresh instead of reusing a negotiated HTTP/2 session" {
  let first = h2_frame_mock_stream(b"", 0)
  let second = h2_frame_mock_stream(b"", 0)
  let first_stream : &Stream = first
  let second_stream : &Stream = second
  let dialer = H2SequenceDialer::{
    streams: [first_stream, second_stream],
    index: 0,
    count: 0,
  }
  let connector = Connector::new(
    dialer,
    H2NegotiatingTlsProvider::{ protocol: Some("h2") },
  ).with_http2(true)
  let url = Url::parse("https://example.com/").unwrap()
  let _ = connector.connect(url).unwrap()
  let _ = connector.connect(url).unwrap()
  assert_eq(dialer.count, 2)
  assert_false(first.is_open)
  assert_true(second.is_open)
  assert_true(connector.close(url) is Ok(_))
  assert_false(second.is_open)
}
