/// `Connector::connect` documents that the returned stream is also reachable
/// through the pool. A reused idle connection is removed from that pool during
/// checkout, so it must be published again before being returned.

test "connect republishes a reused idle connection" {
  let stream = regression_mock_stream("", 1, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let url = Url::parse("http://example.com/").unwrap()
  let first = connector.connect(url).unwrap()
  assert_eq(dialer.count, 1)
  assert_eq(connector.idle_connection_count(), 1)

  let second = connector.connect(url).unwrap()
  assert_eq(dialer.count, 1)
  assert_eq(connector.idle_connection_count(), 1)
  let _ = first
  let _ = second

  // The reused stream is still reachable, so close can tear it down.
  assert_true(connector.close(url) is Ok(_))
  assert_false(stream.is_open)
}
