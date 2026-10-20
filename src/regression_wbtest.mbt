struct RegressionMockStream {
  input : Bytes
  mut offset : Int
  output : Buffer
  max_read : Int
  max_write : Int
  mut is_open : Bool
  mut last_timeout : Int
}

fn regression_mock_stream(input : String, max_read : Int, max_write : Int) -> RegressionMockStream {
  RegressionMockStream::{
    input: @utf8.encode(input),
    offset: 0,
    output: @buffer.new(size_hint=4096),
    max_read,
    max_write,
    is_open: true,
    last_timeout: 0,
  }
}

pub impl Stream for RegressionMockStream with fn read(self : RegressionMockStream, buf : Buffer) -> Result[Int, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  let available = self.input.length() - self.offset
  let limit = if self.max_read > 0 && self.max_read < available {
    self.max_read
  } else {
    available
  }
  let mut i = 0
  while i < limit {
    buf.write_byte(self.input[self.offset + i])
    i = i + 1
  }
  self.offset = self.offset + limit
  Ok(limit)
}

pub impl Stream for RegressionMockStream with fn write(self : RegressionMockStream, buf : Buffer) -> Result[Int, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  let data = buf.to_bytes()
  let limit = if self.max_write > 0 && self.max_write < data.length() {
    self.max_write
  } else {
    data.length()
  }
  let mut i = 0
  while i < limit {
    self.output.write_byte(data[i])
    i = i + 1
  }
  Ok(limit)
}

pub impl Stream for RegressionMockStream with fn flush(self : RegressionMockStream) -> Result[Unit, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Ok(())
}

pub impl Stream for RegressionMockStream with fn close(self : RegressionMockStream) -> Result[Unit, NetError] {
  self.is_open = false
  Ok(())
}

pub impl Stream for RegressionMockStream with fn set_timeout(self : RegressionMockStream, timeout_ms : Int) -> Result[Unit, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  self.last_timeout = timeout_ms
  Ok(())
}

pub impl Stream for RegressionMockStream with fn peer_addr(self : RegressionMockStream) -> Result[String, NetError] {
  Ok("mock:0")
}

pub impl Stream for RegressionMockStream with fn local_addr(self : RegressionMockStream) -> Result[String, NetError] {
  Ok("mock:0")
}

///|
test "URL keeps query and fragment" {
  let url = Url::parse("HTTP://Example.COM:8080/a/b?x=1&y=2#frag").unwrap()
  assert_eq(url.scheme, "http")
  assert_eq(url.host, "Example.COM")
  assert_eq(url.port, 8080)
  assert_eq(url.path, "/a/b")
  assert_eq(url.query, "x=1&y=2")
  assert_eq(url.fragment, "frag")
  assert_eq(url.to_string(), "http://Example.COM:8080/a/b?x=1&y=2#frag")
}

///|
test "URL query without path" {
  let url = Url::parse("https://example.com?x=1").unwrap()
  assert_eq(url.path, "/")
  assert_eq(url.query, "x=1")
  assert_eq(url.to_string(), "https://example.com/?x=1")
}

///|
test "URL rejects invalid ports" {
  assert_true(Url::parse("http://example.com:0") is Err(_))
  assert_true(Url::parse("http://example.com:65536") is Err(_))
  assert_true(Url::parse("http://example.com:notaport") is Err(_))
  assert_true(Url::parse("http://example.com:") is Err(_))
}

///|
test "URL supports bracketed IPv6 literals" {
  let url = Url::parse("http://[::1]:8080/path").unwrap()
  assert_eq(url.host, "::1")
  assert_eq(url.port, 8080)
  assert_eq(url.to_string(), "http://[::1]:8080/path")
}

///|
test "URL rejects control characters" {
  assert_true(Url::parse("http://example.com/\r\nInjected: yes") is Err(_))
  assert_true(Url::parse("http://example.com/\u{0}") is Err(_))
}

///|
test "headers are case insensitive" {
  let headers = Headers::new()
    .add("Content-Type", "text/plain")
    .add("X-Token", "one")
    .add("X-Token", "two")
  assert_eq(headers.get("content-type").unwrap(), "text/plain")
  assert_eq(headers.get("x-token").unwrap(), "two")
  let removed = headers.remove("CONTENT-TYPE")
  assert_true(removed.get("Content-Type") is None)
  assert_eq(removed.get("x-token").unwrap(), "two")
}

///|
test "request encoding keeps query, host port, and partial writes" {
  let stream = regression_mock_stream("", 0, 3)
  let codec = H1Codec::new(stream)
  let url = Url::parse("http://example.com:8080/path?x=1").unwrap()
  let req = Request::new(GET, url)
  assert_true(codec.encode_request(req) is Ok(_))
  let expected = @utf8.encode("GET /path?x=1 HTTP/1.1\r\nHost: example.com:8080\r\nUser-Agent: Feather/0.1.0\r\n\r\n")
  assert_eq(stream.output.to_bytes(), expected)
}

///|
test "request encoding does not duplicate Content-Length" {
  let stream = regression_mock_stream("", 0, 0)
  let codec = H1Codec::new(stream)
  let url = Url::parse("http://example.com/").unwrap()
  let req = Request::new(POST, url)
    .with_header("Content-Length", "5")
    .with_body(@utf8.encode("hello"))
  assert_true(codec.encode_request(req) is Ok(_))
  let expected = @utf8.encode("POST / HTTP/1.1\r\nHost: example.com\r\nUser-Agent: Feather/0.1.0\r\nContent-Length: 5\r\n\r\nhello")
  assert_eq(stream.output.to_bytes(), expected)
}

///|
test "non-ASCII header values round-trip through UTF-8" {
  let encode_stream = regression_mock_stream("", 0, 0)
  let encode_codec = H1Codec::new(encode_stream)
  let url = Url::parse("http://example.com/").unwrap()
  let request = Request::new(GET, url).with_header("X-Name", "café")
  assert_true(encode_codec.encode_request(request) is Ok(_))
  assert_true(@utf8.decode(encode_stream.output.to_bytes()[:]).contains("X-Name: café"))

  let raw = "HTTP/1.1 200 OK\r\nX-Name: café\r\nContent-Length: 0\r\n\r\n"
  let decode_stream = regression_mock_stream(raw, 0, 0)
  let decode_codec = H1Codec::new(decode_stream)
  let response = decode_codec.decode_response().unwrap()
  assert_eq(response.get_header("x-name").unwrap(), "café")
}

///|
test "status line tolerates repeated spaces" {
  let raw = "HTTP/1.1   200  OK\r\nContent-Length: 0\r\n\r\n"
  let stream = regression_mock_stream(raw, 0, 0)
  let codec = H1Codec::new(stream)
  let response = codec.decode_response().unwrap()
  assert_eq(response.status, 200)
}

///|
test "empty header name is rejected" {
  let raw = "HTTP/1.1 200 OK\r\n: value\r\n\r\n"
  let stream = regression_mock_stream(raw, 0, 0)
  let codec = H1Codec::new(stream)
  assert_true(codec.decode_response() is Err(_))
}

///|
test "request encoding rejects header injection" {
  let stream = regression_mock_stream("", 0, 0)
  let codec = H1Codec::new(stream)
  let url = Url::parse("http://example.com/").unwrap()
  let request = Request::new(GET, url).with_header("X-Test", "ok\r\nInjected: yes")
  assert_true(codec.encode_request(request) is Err(InvalidHeader(_)))
  assert_eq(stream.output.to_bytes(), b"")
}

///|
test "response body honors Content-Length" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nX-Test: Yes\r\n\r\nhelloEXTRA"
  let stream = regression_mock_stream(raw, 1, 0)
  let codec = H1Codec::new(stream)
  let response = match codec.decode_response() {
    Ok(response) => response
    Err(ProtocolError(message)) => {
      println("protocol error: " + message)
      abort("decode failed")
    }
    Err(NetworkError(error)) => {
      println("network error")
      debug_inspect(error)
      abort("decode failed")
    }
    Err(_) => {
      println("other decode error")
      abort("decode failed")
    }
  }
  assert_eq(response.get_header("x-test").unwrap(), "Yes")
  let buf = @buffer.new(size_hint=16)
  assert_eq(response.body.read(buf).unwrap(), 5)
  assert_eq(buf.to_bytes(), @utf8.encode("hello"))
  let empty = @buffer.new(size_hint=16)
  assert_eq(response.body.read(empty).unwrap(), 0)
  assert_eq(stream.offset, raw.length() - 5)
}

///|
test "response body decodes chunked encoding" {
  let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\nX-Trailer: yes\r\n\r\n"
  let stream = regression_mock_stream(raw, 1, 0)
  let codec = H1Codec::new(stream)
  let response = codec.decode_response().unwrap()
  let buf = @buffer.new(size_hint=32)
  assert_eq(response.body.read(buf).unwrap(), 11)
  assert_eq(buf.to_bytes(), @utf8.encode("hello world"))
}

///|
test "response decoding survives large read chunks" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhelloNEXT"
  let stream = regression_mock_stream(raw, 0, 0)
  let codec = H1Codec::new(stream)
  let response = codec.decode_response().unwrap()
  let buf = @buffer.new(size_hint=16)
  assert_eq(response.body.read(buf).unwrap(), 5)
  assert_eq(buf.to_bytes(), @utf8.encode("hello"))
  assert_eq(stream.offset, raw.length())
}

///|
test "sequential responses on one codec preserve buffered bytes" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhelloHTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nbye"
  let stream = regression_mock_stream(raw, 0, 0)
  let codec = H1Codec::new(stream)
  let first = codec.decode_response().unwrap()
  let first_buf = @buffer.new(size_hint=8)
  assert_eq(first.body.read(first_buf).unwrap(), 5)
  assert_eq(first_buf.to_bytes(), @utf8.encode("hello"))
  let second = codec.decode_response().unwrap()
  let second_buf = @buffer.new(size_hint=8)
  assert_eq(second.body.read(second_buf).unwrap(), 3)
  assert_eq(second_buf.to_bytes(), @utf8.encode("bye"))
}

///|
test "invalid Content-Length error is sticky" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: nope\r\n\r\n"
  let stream = regression_mock_stream(raw, 1, 0)
  let codec = H1Codec::new(stream)
  let response = codec.decode_response().unwrap()
  assert_true(response.body.read(@buffer.new(size_hint=4)) is Err(_))
  assert_true(response.body.read(@buffer.new(size_hint=4)) is Err(_))
}

///|
test "204 response has no body" {
  let raw = "HTTP/1.1 204 No Content\r\n\r\nnext-response"
  let stream = regression_mock_stream(raw, 1, 0)
  let codec = H1Codec::new(stream)
  let response = codec.decode_response().unwrap()
  let buf = @buffer.new(size_hint=8)
  assert_eq(response.body.read(buf).unwrap(), 0)
  assert_eq(stream.offset, "HTTP/1.1 204 No Content\r\n\r\n".length())
}

///|
test "HEAD response has no body" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"
  let stream = regression_mock_stream(raw, 1, 0)
  let codec = H1Codec::new(stream)
  let response = codec.decode_response(head=true).unwrap()
  let buf = @buffer.new(size_hint=8)
  assert_eq(response.body.read(buf).unwrap(), 0)
  assert_eq(stream.offset, "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n".length())
}

struct RegressionMockDialer {
  stream : &Stream
  mut count : Int
}

pub impl Dialer for RegressionMockDialer with fn dial_tcp(self : RegressionMockDialer, host : String, port : Int) -> Result[&Stream, NetError] {
  let _ = host
  let _ = port
  self.count = self.count + 1
  Ok(self.stream)
}

pub impl Dialer for RegressionMockDialer with fn resolve(self : RegressionMockDialer, host : String) -> Result[List[String], NetError] {
  let _ = self
  Ok(@list.List([host]))
}

///|
test "HEAD response body is not consumed" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhelloNEXT"
  let stream = regression_mock_stream(raw, 0, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let options = ClientOptions::new().with_follow_redirects(false)
  let client = UnifiedClient::{ connector, options, redirect_count: 0 }
  let url = Url::parse("http://example.com/head").unwrap()
  let response = client.request(Request::new(HEAD, url)).unwrap()
  assert_eq(response.status, 200)
  let buf = @buffer.new(size_hint=8)
  assert_eq(response.body.read(buf).unwrap(), 0)
}

///|
test "same-origin redirect changes POST to GET and drops body" {
  let raw = "HTTP/1.1 302 Found\r\nLocation: /next\r\nContent-Length: 0\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
  let stream = regression_mock_stream(raw, 1, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let client = UnifiedClient::{ connector, options: ClientOptions::new(), redirect_count: 0 }
  let url = Url::parse("http://example.com/start").unwrap()
  let request = Request::new(POST, url)
    .with_header("Authorization", "Bearer token")
    .with_header("Content-Type", "text/plain")
    .with_body(@utf8.encode("payload"))
  let response = client.request(request).unwrap()
  assert_eq(response.status, 200)
  let body_buf = @buffer.new(size_hint=8)
  assert_eq(response.body.read(body_buf).unwrap(), 2)
  assert_eq(body_buf.to_bytes(), @utf8.encode("ok"))

  let wire = @utf8.decode(stream.output.to_bytes()[:])
  assert_true(wire.contains("POST /start HTTP/1.1"))
  let next_index = wire.find("GET /next HTTP/1.1").unwrap()
  let second_request = wire.substring(start=next_index)
  assert_true(second_request.contains("Authorization: Bearer token"))
  assert_true(!second_request.contains("Content-Length"))
  assert_true(!second_request.contains("Content-Type"))
  assert_true(!second_request.contains("payload"))
}

///|
test "cross-origin redirect strips Authorization" {
  let raw = "HTTP/1.1 302 Found\r\nLocation: http://other.example/next\r\nContent-Length: 0\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
  let stream = regression_mock_stream(raw, 1, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let client = UnifiedClient::{ connector, options: ClientOptions::new(), redirect_count: 0 }
  let url = Url::parse("http://example.com/start").unwrap()
  let request = Request::new(GET, url).with_header("Authorization", "Bearer token")
  let response = client.request(request).unwrap()
  assert_eq(response.status, 200)
  let wire = @utf8.decode(stream.output.to_bytes()[:])
  let next_index = wire.find("GET /next HTTP/1.1").unwrap()
  let second_request = wire.substring(start=next_index)
  assert_true(!second_request.contains("Authorization"))
  assert_true(second_request.contains("Host: other.example"))
}

///|
test "connector pools connections and close removes them" {
  let stream = regression_mock_stream("", 1, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let url = Url::parse("http://example.com/").unwrap()
  let first = connector.connect(url).unwrap()
  let second = connector.connect(url).unwrap()
  assert_eq(dialer.count, 1)
  let _ = first
  let _ = second
  assert_true(connector.close(url) is Ok(_))
  let _ = connector.connect(url).unwrap()
  assert_eq(dialer.count, 2)
}

///|
test "client options supply the default request timeout" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
  let stream = regression_mock_stream(raw, 0, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let options = ClientOptions::new().with_timeout(1234).with_follow_redirects(false)
  let client = UnifiedClient::{ connector, options, redirect_count: 0 }
  let url = Url::parse("http://example.com/").unwrap()
  let _ = client.request(Request::new(GET, url)).unwrap()
  assert_eq(stream.last_timeout, 1234)
}

///|
test "relative redirect resolution" {
  let base = Url::parse("http://example.com/a/b/c?old=1").unwrap()
  assert_eq(
    resolve_redirect_url(base, "d?x=2").unwrap().to_string(),
    "http://example.com/a/b/d?x=2",
  )
  assert_eq(
    resolve_redirect_url(base, "../x").unwrap().to_string(),
    "http://example.com/a/x",
  )
  assert_eq(
    resolve_redirect_url(base, "/root").unwrap().to_string(),
    "http://example.com/root",
  )
  assert_eq(
    resolve_redirect_url(base, "//other.example/x").unwrap().to_string(),
    "http://other.example/x",
  )
  assert_eq(
    resolve_redirect_url(base, "?new=2").unwrap().to_string(),
    "http://example.com/a/b/c?new=2",
  )
  assert_eq(
    resolve_redirect_url(base, "#frag").unwrap().to_string(),
    "http://example.com/a/b/c?old=1#frag",
  )
}

///|
test "redirect method and body rules" {
  assert_eq(redirect_method(303, POST), (GET, false))
  assert_eq(redirect_method(303, HEAD), (HEAD, false))
  assert_eq(redirect_method(301, POST), (GET, false))
  assert_eq(redirect_method(302, PUT), (PUT, true))
  assert_eq(redirect_method(307, POST), (POST, true))
  assert_eq(redirect_method(308, PUT), (PUT, true))
}
