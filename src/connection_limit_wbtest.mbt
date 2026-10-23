///|
test "total connection cap reuses an idle connection" {
  let stream = regression_mock_stream("", 1, 0)
  let streams : Array[&Stream] = [stream]
  let dialer = RegressionQueueDialer::{ streams, index: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
    .with_max_connections(1)
  let first = Url::parse("http://first.example/").unwrap()
  let second = Url::parse("http://first.example/other").unwrap()
  let _ = connector.connect(first).unwrap()
  let _ = connector.connect(second).unwrap()
  assert_eq(dialer.index, 1)
  assert_eq(connector.connection_count(), 1)
  let _ = connector.close_all()
}

///|
test "total connection cap retires idle sockets for a new origin" {
  let first = regression_mock_stream("", 1, 0)
  let second = regression_mock_stream("", 1, 0)
  let streams : Array[&Stream] = [first, second]
  let dialer = RegressionQueueDialer::{ streams, index: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
    .with_max_connections(1)
  let first_url = Url::parse("http://first.example/").unwrap()
  let second_url = Url::parse("http://second.example/").unwrap()
  let _ = connector.connect(first_url).unwrap()
  let _ = connector.connect(second_url).unwrap()
  assert_false(first.is_open)
  assert_eq(dialer.index, 2)
  assert_eq(connector.connection_count(), 1)
  let _ = connector.close_all()
}

///|
test "total connection cap refuses when every connection is active" {
  let first = regression_mock_stream("", 1, 0)
  let second = regression_mock_stream("", 1, 0)
  let streams : Array[&Stream] = [first, second]
  let dialer = RegressionQueueDialer::{ streams, index: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
    .with_max_connections(1)
  let first_url = Url::parse("http://first.example/").unwrap()
  let second_url = Url::parse("http://second.example/").unwrap()
  let (_stream, lease) = connector.checkout(first_url).unwrap()
  match connector.checkout(second_url) {
    Ok(_) => fail("total connection cap was ignored")
    Err(NetworkError(ConnectionFailed(message))) =>
      assert_eq(message, "total connection limit reached")
    Err(_) => fail("unexpected error for total connection cap")
  }
  assert_true(first.is_open)
  assert_eq(dialer.index, 1)
  lease.release(false)
  let _ = connector.close_all()
}

///|
test "lowering the total connection cap evicts idle sockets" {
  let first = regression_mock_stream("", 1, 0)
  let second = regression_mock_stream("", 1, 0)
  let streams : Array[&Stream] = [first, second]
  let dialer = RegressionQueueDialer::{ streams, index: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let first_url = Url::parse("http://first.example/").unwrap()
  let second_url = Url::parse("http://second.example/").unwrap()
  let _ = connector.connect(first_url).unwrap()
  let _ = connector.connect(second_url).unwrap()
  assert_eq(connector.connection_count(), 2)
  let connector = connector.with_max_connections(1)
  assert_eq(connector.max_connections(), 1)
  assert_eq(connector.connection_count(), 1)
  let _ = connector.close_all()
}

///|
test "client total connection cap builder owns an independent pool" {
  let stream = regression_mock_stream("", 1, 0)
  let streams : Array[&Stream] = [stream]
  let dialer = RegressionQueueDialer::{ streams, index: 0 }
  let client = UnifiedClient::{
    connector: Connector::new(dialer, MockTlsProvider::new("test")),
    options: ClientOptions::new(),
    redirect_count: 0,
  }
  let url = Url::parse("http://example.com/").unwrap()
  let _ = client.connector.connect(url).unwrap()
  assert_eq(client.connection_count(), 1)
  let capped = client.with_max_connections(1)
  assert_eq(capped.connector.max_connections(), 1)
  assert_eq(capped.connection_count(), 0)
  assert_true(stream.is_open)
  let _ = capped.close_all()
  assert_true(stream.is_open)
  let _ = client.close_all()
  assert_false(stream.is_open)
}
