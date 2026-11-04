///|
test "responses expose the request URL" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
  let stream = regression_mock_stream(raw, 0, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0, }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let client = UnifiedClient::{
    connector,
    options: ClientOptions::new(),
    redirect_count: 0,
  }
  let response = client.get("http://example.com/path?q=1#fragment").unwrap()
  let url = response.request_url().unwrap()
  assert_eq(url.host, "example.com")
  assert_eq(url.path, "/path")
  assert_eq(url.query, "q=1")
  assert_eq(url.fragment, "fragment")
}

///|
test "responses expose the final URL after redirects" {
  let first = regression_mock_stream(
    "HTTP/1.1 302 Found\r\nLocation: http://other.example/next\r\nContent-Length: 0\r\n\r\n",
    0, 0,
  )
  let second = regression_mock_stream(
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok", 0, 0,
  )
  let dialer = RegressionQueueDialer::{ streams: [first, second], index: 0, }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let client = UnifiedClient::{
    connector,
    options: ClientOptions::new(),
    redirect_count: 0,
  }
  let response = client.get("http://example.com/start").unwrap()
  let url = response.request_url().unwrap()
  assert_eq(url.origin(), "http://other.example")
  assert_eq(url.path, "/next")
}

///|
test "codec-built responses leave the request URL unset" {
  let stream = regression_mock_stream(
    "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n", 0, 0,
  )
  let response = H1Codec::new(stream)
    .request(Request::from_url(GET, "http://example.com/").unwrap())
    .unwrap()
  assert_true(response.request_url() is None)
}
