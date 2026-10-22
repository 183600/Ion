///|
test "connector reports idle and active connection counts" {
  let first = regression_mock_stream("", 1, 0)
  let second = regression_mock_stream("", 1, 0)
  let streams : Array[&Stream] = [first, second]
  let dialer = RegressionQueueDialer::{ streams, index: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let url = Url::parse("http://example.com/").unwrap()
  assert_eq(connector.connection_count(), 0)
  let (_, lease) = connector.checkout(url).unwrap()
  assert_eq(connector.active_connection_count(), 1)
  assert_eq(connector.idle_connection_count(), 0)
  assert_eq(connector.connection_count(), 1)
  lease.release(true)
  assert_eq(connector.active_connection_count(), 0)
  assert_eq(connector.idle_connection_count(), 1)
  assert_eq(connector.connection_count(), 1)
  let _ = connector.close_idle()
  assert_eq(connector.connection_count(), 0)
  assert_false(first.is_open)
  let _ = second.close()
}

///|
test "close_idle leaves checked-out connections open" {
  let first = regression_mock_stream("", 1, 0)
  let second = regression_mock_stream("", 1, 0)
  let streams : Array[&Stream] = [first, second]
  let dialer = RegressionQueueDialer::{ streams, index: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let url = Url::parse("http://example.com/").unwrap()
  let (_, first_lease) = connector.checkout(url).unwrap()
  let (_, second_lease) = connector.checkout(url).unwrap()
  assert_eq(connector.active_connection_count(), 2)
  let _ = connector.close_idle()
  assert_eq(connector.active_connection_count(), 2)
  assert_true(first.is_open)
  assert_true(second.is_open)
  first_lease.release(false)
  second_lease.release(false)
  assert_eq(connector.connection_count(), 0)
}
