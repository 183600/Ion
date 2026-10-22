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

///|
test "fragment-only redirects do not issue another request" {
  let raw = "HTTP/1.1 302 Found\r\nLocation: #section\r\nContent-Length: 4\r\n\r\nbody"
  let stream = regression_mock_stream(raw, 1, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let client = UnifiedClient::{
    connector,
    options: ClientOptions::new(),
    redirect_count: 0,
  }
  let response = client.get("http://example.com/start").unwrap()
  assert_eq(response.status, 302)
  assert_eq(response.text().unwrap(), "body")
  assert_eq(dialer.count, 1)
}

///|
test "redirects to the identical target are returned without looping" {
  let raw = "HTTP/1.1 307 Temporary Redirect\r\nLocation: http://example.com/start\r\nContent-Length: 0\r\n\r\n"
  let stream = regression_mock_stream(raw, 1, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let client = UnifiedClient::{
    connector,
    options: ClientOptions::new(),
    redirect_count: 0,
  }
  let response = client.get("http://example.com/start").unwrap()
  assert_eq(response.status, 307)
  assert_eq(dialer.count, 1)
}

test "a same-target 303 still rewrites POST to GET" {
  let raw = "HTTP/1.1 303 See Other\r\nLocation: /form\r\nContent-Length: 0\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
  let stream = regression_mock_stream(raw, 1, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let client = UnifiedClient::{
    connector,
    options: ClientOptions::new(),
    redirect_count: 0,
  }
  let url = Url::parse("http://example.com/form").unwrap()
  let response = client
    .request(Request::new(POST, url).with_body(b"payload"))
    .unwrap()
  assert_eq(response.status, 200)
  assert_eq(response.text().unwrap(), "ok")
  let wire = @utf8.decode(stream.output.to_bytes()[:])
  assert_true(wire.contains("POST /form HTTP/1.1\r\n"))
  let second = wire.substring(start=wire.find("GET /form HTTP/1.1").unwrap())
  assert_true(second.contains("GET /form HTTP/1.1\r\n"))
  assert_true(!second.contains("payload"))
}

test "cross-origin redirects distinguish bracketed IP literals" {
  let first = regression_mock_stream(
    "HTTP/1.1 302 Found\r\nLocation: http://v1.foo/next\r\nContent-Length: 0\r\n\r\n",
    1,
    0,
  )
  let second = regression_mock_stream(
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok",
    0,
    0,
  )
  let dialer = RegressionQueueDialer::{ streams: [first, second], index: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let client = UnifiedClient::{
    connector,
    options: ClientOptions::new(),
    redirect_count: 0,
  }
  let url = Url::parse("http://[v1.foo]/start").unwrap()
  let request = Request::new(GET, url).with_header("Authorization", "Bearer secret")
  let response = client.request(request).unwrap()
  assert_eq(response.status, 200)
  let wire = @utf8.decode(second.output.to_bytes()[:])
  assert_true(!wire.contains("Authorization"))
}
