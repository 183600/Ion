///|
test "300 multiple choices is a redirection" {
  assert_true(is_redirect(300))
  let response = Response::new(
    300,
    Headers::new(),
    regression_mock_stream("", 4096, 4096),
  )
  assert_true(response.is_redirection())
}

///|
test "300 redirects without rewriting method or dropping the body" {
  assert_eq(redirect_method(300, POST), (POST, true))
  assert_eq(redirect_method(300, HEAD), (HEAD, true))

  let raw = "HTTP/1.1 300 Multiple Choices\r\nLocation: /next\r\nContent-Length: 0\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
  let stream = regression_mock_stream(raw, 1, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let client = UnifiedClient::{
    connector,
    options: ClientOptions::new(),
    redirect_count: 0,
  }
  let url = Url::parse("http://example.com/start").unwrap()
  let response = client
    .request(Request::new(POST, url).with_body(b"payload"))
    .unwrap()
  assert_eq(response.status, 200)
  assert_eq(response.text().unwrap(), "ok")

  let wire = @utf8.decode(stream.output.to_bytes()[:])
  let next_index = wire.find("POST /next HTTP/1.1").unwrap()
  let second_request = wire.substring(start=next_index)
  assert_true(second_request.contains("Content-Length: 7\r\n"))
  assert_true(second_request.ends_with("\r\n\r\npayload"))
}
