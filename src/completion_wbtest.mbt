///|
test "pool keeps every idle connection for the same origin" {
  let first_stream = regression_mock_stream(
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nA1HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nA2",
    1,
    0,
  )
  let second_stream = regression_mock_stream(
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nB1HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nB2",
    1,
    0,
  )
  let streams : Array[&Stream] = [first_stream, second_stream]
  let dialer = RegressionQueueDialer::{ streams, index: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let options = ClientOptions::new().with_follow_redirects(false)
  let client = UnifiedClient::{ connector, options, redirect_count: 0 }
  let url = Url::parse("http://example.com/").unwrap()

  let first = client.request(Request::new(GET, url)).unwrap()
  let second = client.request(Request::new(GET, url)).unwrap()
  assert_eq(dialer.index, 2)
  assert_eq(first.read_body().unwrap(), b"A1")
  assert_eq(second.read_body().unwrap(), b"B1")

  let third = client.request(Request::new(GET, url)).unwrap()
  let fourth = client.request(Request::new(GET, url)).unwrap()
  assert_eq(dialer.index, 2)
  let third_body = third.read_body().unwrap()
  let fourth_body = fourth.read_body().unwrap()
  assert_true(
    (third_body == b"A2" && fourth_body == b"B2") ||
    (third_body == b"B2" && fourth_body == b"A2"),
  )

  let _ = client.close_all()
  assert_false(first_stream.is_open)
  assert_false(second_stream.is_open)
}
