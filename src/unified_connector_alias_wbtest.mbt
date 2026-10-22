///|
test "UnifiedConnector is an alias for the pooling Connector" {
  let stream = regression_mock_stream("", 0, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector : UnifiedConnector = UnifiedConnector::new(
    dialer,
    MockTlsProvider::new("test"),
  )
  assert_eq(connector.connection_count(), 0)
  let connector2 : Connector = connector.with_timeout(1234)
  assert_eq(connector2.timeout(), 1234)
}
