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
  if !self.is_open {
    return Err(NetError::Closed)
  }
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
  assert_true(Url::parse("http://example.com:+80") is Err(_))
  assert_true(Url::parse("http://example.com:0x50") is Err(_))
  assert_true(Url::parse("http://example.com:8_0") is Err(_))
}

///|
test "URL supports bracketed IPv6 literals" {
  let url = Url::parse("http://[::1]:8080/path").unwrap()
  assert_eq(url.host, "::1")
  assert_eq(url.port, 8080)
  assert_eq(url.to_string(), "http://[::1]:8080/path")
  for raw in [
    "http://[::]/",
    "http://[2001:db8::1]/",
    "http://[::ffff:192.0.2.1]/",
    "http://[fe80::1%25eth0]/",
    "http://[v1.foo]/",
  ] {
    assert_true(Url::parse(raw) is Ok(_))
  }
  for raw in [
    "http://[foo]/",
    "http://[[::1]]/",
    "http://[:::]/",
    "http://[1:2:3:4:5:6:7]/",
    "http://[1:2:3:4:5:6:7:8:9]/",
    "http://[::ffff:192.0.2.999]/",
    "http://[1:::2]/",
    "http://[::1%25]/",
    "http://[::1%]/",
  ] {
    assert_true(Url::parse(raw) is Err(_))
  }
}

///|
test "URL rejects control characters" {
  assert_true(Url::parse("http://example.com/\r\nInjected: yes") is Err(_))
  assert_true(Url::parse("http://example.com/\u{0}") is Err(_))
  assert_true(Url::parse("http://example.com/a b") is Err(_))
  assert_true(Url::parse("http://example.com/a\tb") is Err(_))
  assert_true(Url::parse("http://user@pass@example.com/") is Err(_))
  assert_true(Url::parse("http://exa[mple.com/") is Err(_))
  assert_true(Url::parse("http://example.com/a\u{1}b") is Err(_))
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
test "encode rejects request-target and host injection" {
  let stream = regression_mock_stream("", 0, 0)
  let codec = H1Codec::new(stream)
  let injected_path = Url::{
    scheme: "http",
    host: "example.com",
    port: 80,
    path: "/a\r\nX-Injected: yes",
    query: "",
    fragment: "",
  }
  assert_true(codec.encode_request(Request::new(GET, injected_path)) is Err(_))
  let injected_host = Url::{
    scheme: "http",
    host: "example.com\r\nX-Injected: yes",
    port: 80,
    path: "/",
    query: "",
    fragment: "",
  }
  assert_true(codec.encode_request(Request::new(GET, injected_host)) is Err(_))
  assert_eq(stream.output.to_bytes().length(), 0)
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
test "TLS stream close is idempotent and formats IPv6 peers" {
  let provider = MockTlsProvider::new("test")
  let ctx = provider.new_client(TlsConfig::new("example.com")).unwrap()
  let raw = TcpStream::new("::1", 443)
  assert_true(raw.open() is Ok(_))
  let tls = ctx.connect(raw).unwrap()
  assert_eq(tls.peer_addr().unwrap(), "[::1]:443")
  assert_true(tls.close() is Ok(_))
  assert_true(tls.close() is Ok(_))
}

///|
test "Connection close responses are removed from reuse" {
  let raw = "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 2\r\n\r\nok"
  let stream = regression_mock_stream(raw, 1, 0)
  let codec = H1Codec::new(stream)
  let response = codec.decode_response().unwrap()
  let buf = @buffer.new(size_hint=4)
  assert_eq(response.body.read(buf).unwrap(), 2)
  assert_eq(stream.is_open, false)
}

///|
test "response bodies are read in bounded chunks" {
  let body = "a".repeat(20000)
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 20000\r\n\r\n" + body
  let stream = regression_mock_stream(raw, 512, 0)
  let codec = H1Codec::new(stream)
  let response = codec.decode_response().unwrap()
  let buf = @buffer.new(size_hint=8192)
  assert_eq(response.body.read(buf).unwrap(), 8192)
  assert_true(stream.offset < raw.length())
  let rest = response.read_body().unwrap()
  assert_eq(rest.length(), 20000 - 8192)
  assert_eq(stream.offset, raw.length())
}

///|
test "fixed-length body finishing at the read boundary returns to the pool" {
  let body = "a".repeat(8192)
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 8192\r\n\r\n" + body +
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi"
  let stream = regression_mock_stream(raw, 1, 0)
  let streams : Array[&Stream] = [stream]
  let dialer = RegressionQueueDialer::{ streams, index: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let options = ClientOptions::new().with_follow_redirects(false)
  let client = UnifiedClient::{ connector, options, redirect_count: 0 }
  let url = Url::parse("http://example.com/").unwrap()

  let first = client.request(Request::new(GET, url)).unwrap()
  let first_buf = @buffer.new(size_hint=8192)
  assert_eq(first.body.read(first_buf).unwrap(), 8192)

  let second = client.request(Request::new(GET, url)).unwrap()
  assert_eq(second.text().unwrap(), "hi")
  assert_eq(dialer.index, 1)
}

///|
test "prefetched response bytes prevent unsafe connection reuse" {
  let first_stream = regression_mock_stream(
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nokHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi",
    0,
    0,
  )
  let second_stream = regression_mock_stream(
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi",
    0,
    0,
  )
  let streams : Array[&Stream] = [first_stream, second_stream]
  let dialer = RegressionQueueDialer::{ streams, index: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let options = ClientOptions::new().with_follow_redirects(false)
  let client = UnifiedClient::{ connector, options, redirect_count: 0 }
  let url = Url::parse("http://example.com/").unwrap()

  let first = client.request(Request::new(GET, url)).unwrap()
  let first_buf = @buffer.new(size_hint=8)
  assert_eq(first.body.read(first_buf).unwrap(), 2)
  assert_eq(first_buf.to_bytes(), @utf8.encode("ok"))
  assert_true(!first_stream.is_open)

  let second = client.request(Request::new(GET, url)).unwrap()
  assert_eq(second.text().unwrap(), "hi")
  assert_eq(dialer.index, 2)
}

///|
test "response status line must use the HTTP protocol" {
  let raw = "BOGUS 200 OK\r\nContent-Length: 0\r\n\r\n"
  let codec = H1Codec::new(regression_mock_stream(raw, 0, 0))
  assert_true(codec.decode_response() is Err(_))
  let raw2 = "HTTP/1.1 0200 OK\r\nContent-Length: 0\r\n\r\n"
  let codec2 = H1Codec::new(regression_mock_stream(raw2, 0, 0))
  assert_true(codec2.decode_response() is Err(_))
}

///|
test "truncated response headers are rejected" {
  let raw = "HTTP/1.1 204 No Content\r\n"
  let codec = H1Codec::new(regression_mock_stream(raw, 0, 0))
  assert_true(codec.decode_response() is Err(_))
}

///|
test "EOF-framed responses close the connection" {
  let raw = "HTTP/1.1 200 OK\r\n\r\nhello"
  let stream = regression_mock_stream(raw, 1, 0)
  let codec = H1Codec::new(stream)
  let response = codec.decode_response().unwrap()
  let buf = @buffer.new(size_hint=8)
  assert_eq(response.body.read(buf).unwrap(), 5)
  assert_eq(buf.to_bytes(), b"hello")
  assert_eq(stream.is_open, false)
}

///|
test "response rejects invalid header names and values" {
  let malformed = [
    "HTTP/1.1 200 OK\r\nBad Header: x\r\n\r\n",
    "HTTP/1.1 200 OK\r\nX-Test: a\rb\r\n\r\n",
  ]
  for raw in malformed {
    let codec = H1Codec::new(regression_mock_stream(raw, 0, 0))
    assert_true(codec.decode_response() is Err(_))
  }
}

///|
test "Transfer-Encoding only recognizes the chunked token" {
  let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: notchunked\r\nContent-Length: 5\r\n\r\nhello"
  let codec = H1Codec::new(regression_mock_stream(raw, 0, 0))
  let response = codec.decode_response().unwrap()
  let buf = @buffer.new(size_hint=8)
  assert_eq(response.body.read(buf).unwrap(), 5)
  assert_eq(buf.to_bytes(), b"hello")
}

///|
test "response stream is closed after closing" {
  let raw = "HTTP/1.1 204 No Content\r\n\r\n"
  let codec = H1Codec::new(regression_mock_stream(raw, 0, 0))
  let response = codec.decode_response().unwrap()
  assert_true(response.body.close() is Ok(_))
  let buf = @buffer.new(size_hint=8)
  assert_true(response.body.write(buf) is Err(NetError::Closed))
}

///|
test "decode_response remembers a preceding HEAD request" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"
  let stream = regression_mock_stream(raw, 0, 0)
  let codec = H1Codec::new(stream)
  let url = Url::parse("http://example.com/").unwrap()
  assert_true(codec.encode_request(Request::new(HEAD, url)) is Ok(_))
  let response = codec.decode_response().unwrap()
  let buf = @buffer.new(size_hint=8)
  assert_eq(response.body.read(buf).unwrap(), 0)
}

///|
test "HEAD framing applies only to the next response" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
  let stream = regression_mock_stream(raw, 0, 0)
  let codec = H1Codec::new(stream)
  let url = Url::parse("http://example.com/").unwrap()
  assert_true(codec.encode_request(Request::new(HEAD, url)) is Ok(_))
  let head_response = codec.decode_response().unwrap()
  assert_eq(head_response.body.read(@buffer.new(size_hint=8)).unwrap(), 0)
  let next_response = codec.decode_response().unwrap()
  assert_eq(next_response.text().unwrap(), "ok")
}

///|
test "Content-Length must be plain decimal digits" {
  for value in ["+5", "5_0", "0x5"] {
    let raw = "HTTP/1.1 200 OK\r\nContent-Length: " + value + "\r\n\r\nhello"
    let codec = H1Codec::new(regression_mock_stream(raw, 0, 0))
    let response = codec.decode_response().unwrap()
    assert_true(response.body.read(@buffer.new(size_hint=8)) is Err(_))
  }
}

///|
test "huge declared body lengths fail without allocating the whole size" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 2000000000\r\n\r\n"
  let codec = H1Codec::new(regression_mock_stream(raw, 0, 0))
  let response = codec.decode_response().unwrap()
  assert_true(response.body.read(@buffer.new(size_hint=8)) is Err(_))
  let chunked = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n7FFFFFFF\r\n"
  let codec2 = H1Codec::new(regression_mock_stream(chunked, 0, 0))
  let response2 = codec2.decode_response().unwrap()
  assert_true(response2.body.read(@buffer.new(size_hint=8)) is Err(_))
}

///|
test "chunk sizes must be plain hexadecimal digits" {
  for value in ["+5", "5_0", "0x5"] {
    let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" + value + "\r\nhello\r\n0\r\n\r\n"
    let codec = H1Codec::new(regression_mock_stream(raw, 0, 0))
    let response = codec.decode_response().unwrap()
    assert_true(response.body.read(@buffer.new(size_hint=8)) is Err(_))
  }
}

///|
test "conflicting Content-Length headers are rejected" {
  let conflicting = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\nhello!"
  let codec = H1Codec::new(regression_mock_stream(conflicting, 0, 0))
  let response = codec.decode_response().unwrap()
  assert_true(response.body.read(@buffer.new(size_hint=8)) is Err(_))

  let repeated = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\nhello"
  let codec2 = H1Codec::new(regression_mock_stream(repeated, 0, 0))
  let response2 = codec2.decode_response().unwrap()
  let buf = @buffer.new(size_hint=8)
  assert_eq(response2.body.read(buf).unwrap(), 5)
  assert_eq(buf.to_bytes(), b"hello")
}

///|
test "combined Content-Length values must agree" {
  let combined = "HTTP/1.1 200 OK\r\nContent-Length: 5, 5\r\n\r\nhello"
  let codec = H1Codec::new(regression_mock_stream(combined, 0, 0))
  let response = codec.decode_response().unwrap()
  assert_eq(response.text().unwrap(), "hello")

  for value in ["5, 6", "5, nope", "5,"] {
    let raw = "HTTP/1.1 200 OK\r\nContent-Length: " + value + "\r\n\r\nhello"
    let codec = H1Codec::new(regression_mock_stream(raw, 0, 0))
    let response = codec.decode_response().unwrap()
    assert_true(response.read_body() is Err(_))
  }
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

struct RegressionQueueDialer {
  streams : Array[&Stream]
  mut index : Int
}

pub impl Dialer for RegressionQueueDialer with fn dial_tcp(self : RegressionQueueDialer, host : String, port : Int) -> Result[&Stream, NetError] {
  let _ = host
  let _ = port
  if self.index >= self.streams.length() {
    return Err(NetError::ConnectionFailed("no scripted stream"))
  }
  let stream = self.streams[self.index]
  self.index = self.index + 1
  Ok(stream)
}

pub impl Dialer for RegressionQueueDialer with fn resolve(self : RegressionQueueDialer, host : String) -> Result[List[String], NetError] {
  let _ = self
  Ok(@list.List([host]))
}

struct RegressionProxyDialer {
  stream : &Stream
  mut host : String
  mut port : Int
}

pub impl Dialer for RegressionProxyDialer with fn dial_tcp(self : RegressionProxyDialer, host : String, port : Int) -> Result[&Stream, NetError] {
  self.host = host
  self.port = port
  Ok(self.stream)
}

pub impl Dialer for RegressionProxyDialer with fn resolve(self : RegressionProxyDialer, host : String) -> Result[List[String], NetError] {
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
test "connector replaces externally closed pooled streams" {
  let first_stream = regression_mock_stream("", 1, 0)
  let second_stream = regression_mock_stream("", 1, 0)
  let streams : Array[&Stream] = [first_stream, second_stream]
  let dialer = RegressionQueueDialer::{ streams, index: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let url = Url::parse("http://example.com/").unwrap()
  let first = connector.connect(url).unwrap()
  assert_true(first.close() is Ok(_))
  let _ = connector.connect(url).unwrap()
  assert_eq(dialer.index, 2)
}

struct RegressionHttpClient {
  mut calls : Int
  response_body : &Stream
}

pub impl HttpClient for RegressionHttpClient with fn request(self : RegressionHttpClient, req : Request) -> Result[Response, HttpError] {
  let _ = req
  self.calls = self.calls + 1
  Ok(Response::new(200, Headers::new(), self.response_body))
}

///|
test "HttpClient convenience methods parse URLs" {
  let body = regression_mock_stream("", 0, 0)
  let client = RegressionHttpClient::{ calls: 0, response_body: body }
  let trait_client : &HttpClient = client
  let response = trait_client.get("http://example.com/x").unwrap()
  assert_eq(response.status, 200)
  assert_eq(client.calls, 1)
  let bad = trait_client.get("not a url")
  assert_true(bad is Err(_))
  assert_eq(client.calls, 1)
}

///|
test "HEAD responses return their connection to the pool" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi"
  let stream = regression_mock_stream(raw, 1, 0)
  let streams : Array[&Stream] = [stream]
  let dialer = RegressionQueueDialer::{ streams, index: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let options = ClientOptions::new().with_follow_redirects(false)
  let client = UnifiedClient::{ connector, options, redirect_count: 0 }
  let url = Url::parse("http://example.com/").unwrap()

  let head_response = client.head("http://example.com/").unwrap()
  assert_eq(head_response.status, 200)

  let second = client.request(Request::new(GET, url)).unwrap()
  assert_eq(second.text().unwrap(), "hi")
  assert_eq(dialer.index, 1)
}

///|
test "client reuses a connection after a fully read response" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nokHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi"
  let stream = regression_mock_stream(raw, 1, 0)
  let streams : Array[&Stream] = [stream]
  let dialer = RegressionQueueDialer::{ streams, index: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let options = ClientOptions::new().with_follow_redirects(false)
  let client = UnifiedClient::{ connector, options, redirect_count: 0 }
  let url = Url::parse("http://example.com/").unwrap()

  let first = client.request(Request::new(GET, url)).unwrap()
  let first_buf = @buffer.new(size_hint=8)
  assert_eq(first.body.read(first_buf).unwrap(), 2)
  assert_eq(first_buf.to_bytes(), @utf8.encode("ok"))

  let second = client.request(Request::new(GET, url)).unwrap()
  let second_buf = @buffer.new(size_hint=8)
  assert_eq(second.body.read(second_buf).unwrap(), 2)
  assert_eq(second_buf.to_bytes(), @utf8.encode("hi"))
  assert_eq(dialer.index, 1)
}

///|
test "closing a fully read response keeps its pooled connection" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nokHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi"
  let stream = regression_mock_stream(raw, 1, 0)
  let streams : Array[&Stream] = [stream]
  let dialer = RegressionQueueDialer::{ streams, index: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let options = ClientOptions::new().with_follow_redirects(false)
  let client = UnifiedClient::{ connector, options, redirect_count: 0 }
  let url = Url::parse("http://example.com/").unwrap()

  let first = client.request(Request::new(GET, url)).unwrap()
  let first_buf = @buffer.new(size_hint=8)
  assert_eq(first.body.read(first_buf).unwrap(), 2)
  assert_true(first.body.close() is Ok(_))
  assert_true(stream.is_open)

  let second = client.request(Request::new(GET, url)).unwrap()
  let second_buf = @buffer.new(size_hint=8)
  assert_eq(second.body.read(second_buf).unwrap(), 2)
  assert_eq(second_buf.to_bytes(), @utf8.encode("hi"))
  assert_eq(dialer.index, 1)
}

///|
test "unread response body is not reused for the next request" {
  let first_stream = regression_mock_stream(
    "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello",
    1,
    0,
  )
  let second_stream = regression_mock_stream(
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok",
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
  assert_eq(first.status, 200)
  let second = client.request(Request::new(GET, url)).unwrap()
  assert_eq(second.status, 200)
  let body_buf = @buffer.new(size_hint=8)
  assert_eq(second.body.read(body_buf).unwrap(), 2)
  assert_eq(body_buf.to_bytes(), @utf8.encode("ok"))
  assert_eq(dialer.index, 2)

  let _ = client.close_all()
  assert_true(!first_stream.is_open)
  assert_true(!second_stream.is_open)
}

///|
test "zero-length responses return to the pool without being read" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
  let stream = regression_mock_stream(raw, 1, 0)
  let streams : Array[&Stream] = [stream]
  let dialer = RegressionQueueDialer::{ streams, index: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let options = ClientOptions::new().with_follow_redirects(false)
  let client = UnifiedClient::{ connector, options, redirect_count: 0 }
  let url = Url::parse("http://example.com/").unwrap()

  let first = client.request(Request::new(GET, url)).unwrap()
  assert_eq(first.status, 200)
  assert_true(stream.is_open)

  let second = client.request(Request::new(GET, url)).unwrap()
  let body_buf = @buffer.new(size_hint=8)
  assert_eq(second.body.read(body_buf).unwrap(), 2)
  assert_eq(body_buf.to_bytes(), @utf8.encode("ok"))
  assert_eq(dialer.index, 1)
}

///|
test "closing one response keeps another pooled connection for the same origin" {
  let first_stream = regression_mock_stream(
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nA1",
    1,
    0,
  )
  let second_stream = regression_mock_stream(
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nB1HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nC1",
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
  let second_buf = @buffer.new(size_hint=8)
  assert_eq(second.body.read(second_buf).unwrap(), 2)
  assert_eq(second_buf.to_bytes(), @utf8.encode("B1"))
  assert_true(second_stream.is_open)

  assert_true(first.body.close() is Ok(_))
  assert_true(second_stream.is_open)

  let third = client.request(Request::new(GET, url)).unwrap()
  let third_buf = @buffer.new(size_hint=8)
  assert_eq(third.body.read(third_buf).unwrap(), 2)
  assert_eq(third_buf.to_bytes(), @utf8.encode("C1"))
  assert_eq(dialer.index, 2)
}

///|
test "a failed request keeps other pooled connections for the same origin" {
  let first_stream = regression_mock_stream(
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nA1HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nA2",
    1,
    0,
  )
  let second_stream = regression_mock_stream(
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nB1BOGUS RESPONSE\r\n\r\n",
    1,
    0,
  )
  let third_stream = regression_mock_stream(
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nC1",
    0,
    0,
  )
  let streams : Array[&Stream] = [first_stream, second_stream, third_stream]
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
  assert_eq(third.read_body().unwrap(), b"A2")
  assert_eq(dialer.index, 2)
}

///|
test "closing an unread response releases its connection" {
  let first_stream = regression_mock_stream(
    "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello",
    1,
    0,
  )
  let second_stream = regression_mock_stream(
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok",
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
  assert_true(first.body.close() is Ok(_))
  assert_true(!first_stream.is_open)

  let second = client.request(Request::new(GET, url)).unwrap()
  let body_buf = @buffer.new(size_hint=8)
  assert_eq(second.body.read(body_buf).unwrap(), 2)
  assert_eq(body_buf.to_bytes(), @utf8.encode("ok"))
  assert_eq(dialer.index, 2)
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
test "an explicit request timeout wins over the client default" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
  let stream = regression_mock_stream(raw, 0, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let options = ClientOptions::new().with_timeout(1234).with_follow_redirects(false)
  let client = UnifiedClient::{ connector, options, redirect_count: 0 }
  let url = Url::parse("http://example.com/").unwrap()
  let request = Request::new(GET, url).with_timeout(30000)
  let _ = client.request(request).unwrap()
  assert_eq(stream.last_timeout, 30000)
}

///|
test "redirects preserve an explicit request timeout" {
  let raw = "HTTP/1.1 302 Found\r\nLocation: /next\r\nContent-Length: 0\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
  let stream = regression_mock_stream(raw, 1, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let options = ClientOptions::new().with_timeout(1234)
  let client = UnifiedClient::{ connector, options, redirect_count: 0 }
  let url = Url::parse("http://example.com/start").unwrap()
  let _ = client.request(Request::new(GET, url).with_timeout(30000)).unwrap()
  assert_eq(stream.last_timeout, 30000)
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
    resolve_redirect_url(base, "/a//b").unwrap().to_string(),
    "http://example.com/a//b",
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
  assert_eq(normalize_path_and_suffix("/."), "/")
  assert_eq(normalize_path_and_suffix("/a/.."), "/")
  assert_eq(normalize_path_and_suffix("//"), "//")
  assert_eq(
    resolve_redirect_url(Url::parse("http://example.com/").unwrap(), "..//")
    .unwrap()
    .to_string(),
    "http://example.com//",
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

///|
test "interim 100 Continue responses are skipped" {
  let raw = "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
  let codec = H1Codec::new(regression_mock_stream(raw, 1, 0))
  let response = codec.decode_response().unwrap()
  assert_eq(response.status, 200)
  assert_eq(response.version, "HTTP/1.1")
  assert_eq(response.text().unwrap(), "ok")
}

///|
test "unsupported HTTP versions are rejected" {
  for version in ["HTTP/2.0", "HTTP/0.9", "HTTP/1.2"] {
    let raw = version + " 200 OK\r\nContent-Length: 0\r\n\r\n"
    let codec = H1Codec::new(regression_mock_stream(raw, 0, 0))
    assert_true(codec.decode_response() is Err(_))
  }
}

///|
test "obsolete folded response headers are rejected" {
  let raw = "HTTP/1.1 200 OK\r\nX-Test: one\r\n two\r\nContent-Length: 0\r\n\r\n"
  let codec = H1Codec::new(regression_mock_stream(raw, 0, 0))
  assert_true(codec.decode_response() is Err(_))
}

///|
test "HTTP/1.0 closes by default but honors keep-alive" {
  let closing = "HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nok"
  let close_stream = regression_mock_stream(closing, 1, 0)
  let close_codec = H1Codec::new(close_stream)
  let close_response = close_codec.decode_response().unwrap()
  assert_eq(close_response.text().unwrap(), "ok")
  assert_eq(close_stream.is_open, false)

  let keeping = "HTTP/1.0 200 OK\r\nConnection: keep-alive\r\nContent-Length: 2\r\n\r\nok"
  let keep_stream = regression_mock_stream(keeping, 1, 0)
  let keep_codec = H1Codec::new(keep_stream)
  let keep_response = keep_codec.decode_response().unwrap()
  assert_eq(keep_response.text().unwrap(), "ok")
  assert_eq(keep_stream.is_open, true)
}

///|
test "response bodies are bounded by the configured limit" {
  let fixed = "HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\n123456789"
  let fixed_codec = H1Codec::new_with_limit(regression_mock_stream(fixed, 0, 0), 8)
  let fixed_response = fixed_codec.decode_response().unwrap()
  assert_true(fixed_response.read_body() is Err(_))

  let chunked = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n5\r\nworld\r\n0\r\n\r\n"
  let chunked_codec = H1Codec::new_with_limit(regression_mock_stream(chunked, 1, 0), 9)
  let chunked_response = chunked_codec.decode_response().unwrap()
  assert_true(chunked_response.read_body() is Err(_))

  let eof = "HTTP/1.1 200 OK\r\n\r\n123456789"
  let eof_codec = H1Codec::new_with_limit(regression_mock_stream(eof, 1, 0), 8)
  let eof_response = eof_codec.decode_response().unwrap()
  assert_true(eof_response.read_body() is Err(_))
}

///|
test "read_body and text consume the response stream" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"
  let codec = H1Codec::new(regression_mock_stream(raw, 2, 0))
  let response = codec.decode_response().unwrap()
  assert_eq(response.read_body().unwrap(), b"hello")
  assert_eq(response.read_body().unwrap(), b"")

  let text_codec = H1Codec::new(regression_mock_stream(raw, 2, 0))
  let text_response = text_codec.decode_response().unwrap()
  assert_eq(text_response.text().unwrap(), "hello")
}

///|
test "headers expose all values in insertion order" {
  let headers = Headers::new()
    .add("X-Test", "one")
    .add("x-test", "two")
    .add("Other", "value")
  assert_eq(headers.get_all("X-Test"), @list.List(["one", "two"]))
  assert_true(headers.contains("x-TEST"))
  assert_eq(headers.length(), 3)
  let replaced = headers.set("X-Test", "three")
  assert_eq(replaced.get_all("x-test"), @list.List(["three"]))
  assert_eq(replaced.get("other").unwrap(), "value")
}

///|
test "request encoding supports chunked bodies" {
  let stream = regression_mock_stream("", 0, 2)
  let codec = H1Codec::new(stream)
  let url = Url::parse("http://example.com/upload").unwrap()
  let request = Request::new(POST, url)
    .with_header("Transfer-Encoding", "chunked")
    .with_body(@utf8.encode("hello"))
  assert_true(codec.encode_request(request) is Ok(_))
  let expected = @utf8.encode(
    "POST /upload HTTP/1.1\r\nHost: example.com\r\nUser-Agent: Feather/0.1.0\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n",
  )
  assert_eq(stream.output.to_bytes(), expected)
}

///|
test "empty chunked request still terminates the body" {
  let stream = regression_mock_stream("", 0, 0)
  let codec = H1Codec::new(stream)
  let url = Url::parse("http://example.com/upload").unwrap()
  let request = Request::new(POST, url).with_header("Transfer-Encoding", "chunked")
  assert_true(codec.encode_request(request) is Ok(_))
  assert_true(
    @utf8.decode(stream.output.to_bytes()[:]).has_suffix("\r\n\r\n0\r\n\r\n"),
  )
}

///|
test "redirect limit counts followed redirects exactly" {
  let raw = "HTTP/1.1 302 Found\r\nLocation: /one\r\nContent-Length: 0\r\n\r\nHTTP/1.1 302 Found\r\nLocation: /two\r\nContent-Length: 0\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
  let stream = regression_mock_stream(raw, 1, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let options = ClientOptions::new().with_max_redirects(1)
  let client = UnifiedClient::{ connector, options, redirect_count: 0 }
  let url = Url::parse("http://example.com/start").unwrap()
  assert_true(client.request(Request::new(GET, url)) is Err(RedirectLimitExceeded))
}

///|
test "cross-origin redirects strip credentials and cookies" {
  let raw = "HTTP/1.1 302 Found\r\nLocation: http://other.example/next\r\nContent-Length: 0\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
  let stream = regression_mock_stream(raw, 1, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let client = UnifiedClient::{ connector, options: ClientOptions::new(), redirect_count: 0 }
  let url = Url::parse("http://example.com/start").unwrap()
  let request = Request::new(GET, url)
    .with_header("Cookie", "session=secret")
    .with_header("Proxy-Authorization", "Basic secret")
  let response = client.request(request).unwrap()
  assert_eq(response.status, 200)
  let wire = @utf8.decode(stream.output.to_bytes()[:])
  let next_index = wire.find("GET /next HTTP/1.1").unwrap()
  let second_request = wire.substring(start=next_index)
  assert_true(!second_request.contains("Cookie"))
  assert_true(!second_request.contains("Proxy-Authorization"))
}

///|
test "request framing rejects ambiguous lengths" {
  let url = Url::parse("http://example.com/").unwrap()
  let mismatch = H1Codec::new(regression_mock_stream("", 0, 0))
  assert_true(
    mismatch.encode_request(
      Request::new(POST, url)
        .with_header("Content-Length", "3")
        .with_body(@utf8.encode("hello")),
    ) is Err(InvalidHeader(_)),
  )

  let both = H1Codec::new(regression_mock_stream("", 0, 0))
  assert_true(
    both.encode_request(
      Request::new(POST, url)
        .with_header("Content-Length", "5")
        .with_header("Transfer-Encoding", "chunked")
        .with_body(@utf8.encode("hello")),
    ) is Err(InvalidHeader(_)),
  )

  let duplicate = H1Codec::new(regression_mock_stream("", 0, 0))
  assert_true(
    duplicate.encode_request(
      Request::new(POST, url)
        .with_header("Content-Length", "5")
        .with_header("Content-Length", "5")
        .with_body(@utf8.encode("hello")),
    ) is Err(InvalidHeader(_)),
  )

  let unsupported = H1Codec::new(regression_mock_stream("", 0, 0))
  assert_true(
    unsupported.encode_request(
      Request::new(POST, url)
        .with_header("Transfer-Encoding", "gzip")
        .with_body(@utf8.encode("hello")),
    ) is Err(InvalidHeader(_)),
  )
  for value in ["gzip, chunked", "chunked, chunked"] {
    let codec = H1Codec::new(regression_mock_stream("", 0, 0))
    assert_true(
      codec.encode_request(
        Request::new(POST, url)
          .with_header("Transfer-Encoding", value)
          .with_body(@utf8.encode("hello")),
      ) is Err(InvalidHeader(_)),
    )
  }
}

///|
test "TLS configuration is validated before use" {
  assert_true(TlsConfig::new("example.com").validate() is Ok(_))
  assert_true(TlsConfig::new("").validate() is Err(InvalidConfig(_)))
  assert_true(TlsConfig::new("bad name").validate() is Err(InvalidConfig(_)))
  assert_true(
    TlsConfig::new("example.com").with_alpn(@list.List(["h2", ""])).validate() is
    Err(InvalidConfig(_)),
  )
  assert_true(
    TlsConfig::new("example.com")
      .with_client_auth(ClientCert::new(b"", b"key"))
      .validate() is Err(InvalidConfig(_)),
  )
  assert_true(
    TlsConfig::new("example.com")
      .with_client_auth(ClientCert::new(b"cert", b""))
      .validate() is Err(InvalidConfig(_)),
  )
  let provider = MockTlsProvider::new("test")
  assert_true(provider.new_client(TlsConfig::new("")) is Err(_))
  assert_true(
    provider.new_client(TlsConfig::new("example.com")) is Ok(_),
  )
}

///|
test "a mock TLS context cannot be connected twice" {
  let provider = MockTlsProvider::new("test")
  let ctx = provider.new_client(TlsConfig::new("example.com")).unwrap()
  let first = TcpStream::new("example.com", 443)
  assert_true(first.open() is Ok(_))
  assert_true(ctx.connect(first) is Ok(_))
  let second = TcpStream::new("example.com", 443)
  assert_true(second.open() is Ok(_))
  assert_true(ctx.connect(second) is Err(_))
}

///|
test "HttpClient convenience methods cover HEAD, OPTIONS, and PATCH" {
  let body = regression_mock_stream("", 0, 0)
  let client = RegressionHttpClient::{ calls: 0, response_body: body }
  let trait_client : &HttpClient = client
  assert_eq(trait_client.head("http://example.com/").unwrap().status, 200)
  assert_eq(trait_client.options("http://example.com/").unwrap().status, 200)
  assert_eq(
    trait_client.patch("http://example.com/", b"data").unwrap().status,
    200,
  )
  assert_eq(client.calls, 3)
}

///|
test "UnifiedClient convenience methods send the requested verb" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
  let stream = regression_mock_stream(raw, 1, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let client = UnifiedClient::{ connector, options: ClientOptions::new(), redirect_count: 0 }
  assert_eq(client.head("http://example.com/a").unwrap().status, 200)
  assert_eq(client.options("http://example.com/a").unwrap().status, 200)
  assert_eq(client.patch("http://example.com/a", b"x").unwrap().status, 200)
  let wire = @utf8.decode(stream.output.to_bytes()[:])
  assert_true(wire.contains("HEAD /a HTTP/1.1"))
  assert_true(wire.contains("OPTIONS /a HTTP/1.1"))
  assert_true(wire.contains("PATCH /a HTTP/1.1"))
}

struct ConfigCapturingTlsProvider {
  mut last_config : TlsConfig?
}

pub impl TlsProvider for ConfigCapturingTlsProvider with fn new_client(self : ConfigCapturingTlsProvider, config : TlsConfig) -> Result[&TlsClientCtx, TlsError] {
  self.last_config = Some(config)
  match config.validate() {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  Ok(MockTlsClientCtx::{ config, is_connected: false })
}

///|
test "connector rejects invalid schemes, hosts, and ports" {
  let stream = regression_mock_stream("", 0, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  assert_true(
    connector.connect(Url::new("ftp", "example.com", 21)) is Err(InvalidUrl(_)),
  )
  assert_true(
    connector.connect(Url::new("http", "", 80)) is Err(InvalidUrl(_)),
  )
  assert_true(
    connector.connect(Url::new("http", "bad host", 80)) is Err(InvalidUrl(_)),
  )
  assert_true(
    connector.connect(Url::new("http", "example.com", 0)) is Err(InvalidUrl(_)),
  )
  assert_true(
    connector.connect(Url::new("http", "example.com", 65536)) is Err(InvalidUrl(_)),
  )
  assert_eq(dialer.count, 0)
}

///|
test "connector pool keys normalize host case" {
  let stream = regression_mock_stream("", 0, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let first = Url::parse("http://Example.COM/path").unwrap()
  let second = Url::parse("http://example.com/other").unwrap()
  let _ = connector.connect(first).unwrap()
  let _ = connector.connect(second).unwrap()
  assert_eq(dialer.count, 1)
}

///|
test "connector applies shared TLS configuration per host" {
  let stream = regression_mock_stream("", 0, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let provider = ConfigCapturingTlsProvider::{ last_config: None }
  let base = TlsConfig::new("ignored.example")
    .with_min_version(Tls1_3)
    .with_alpn(@list.List(["h2", "http/1.1"]))
  let connector = Connector::new(dialer, provider).with_tls_config(base)
  let url = Url::parse("https://secure.example:8443/").unwrap()
  let _ = connector.connect(url).unwrap()
  let captured = provider.last_config.unwrap()
  assert_eq(captured.server_name, "secure.example")
  assert_eq(captured.min_version, Tls1_3)
  assert_eq(captured.alpn, @list.List(["h2", "http/1.1"]))
}

///|
test "UnifiedClient exposes transport and TLS configuration" {
  let stream = regression_mock_stream(
    "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n",
    1,
    0,
  )
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let provider = ConfigCapturingTlsProvider::{ last_config: None }
  let client = UnifiedClient::with_transport(
    dialer,
    provider,
    ClientOptions::new().with_follow_redirects(false),
  ).with_tls_config(TlsConfig::new("base.example").with_min_version(Tls1_3))
  let url = Url::parse("https://secure.example/").unwrap()
  let _ = client.request(Request::new(GET, url)).unwrap()
  assert_eq(provider.last_config.unwrap().server_name, "secure.example")
}

///|
test "dialer validates host names and ports" {
  let dialer = TcpDialer::new()
  assert_true(dialer.dial_tcp("", 80) is Err(InvalidAddress(_)))
  assert_true(dialer.dial_tcp("bad host", 80) is Err(InvalidAddress(_)))
  assert_true(dialer.dial_tcp("example.com", 0) is Err(InvalidAddress(_)))
  assert_true(dialer.dial_tcp("example.com", 65536) is Err(InvalidAddress(_)))
  assert_true(dialer.resolve("") is Err(InvalidAddress(_)))
  assert_true(dialer.resolve("bad\nhost") is Err(InvalidAddress(_)))
  assert_true(dialer.dial_tcp("example.com", 80) is Ok(_))
}

///|
test "opening an invalid TcpStream fails cleanly" {
  let missing_host = TcpStream::new("", 80)
  assert_true(missing_host.open() is Err(InvalidAddress(_)))
  assert_eq(missing_host.is_open, false)
  let bad_port = TcpStream::new("example.com", 70000)
  assert_true(bad_port.open() is Err(InvalidAddress(_)))
  let stream = TcpStream::new("example.com", 80)
  assert_true(stream.open() is Ok(_))
  assert_true(stream.open() is Ok(_))
  assert_eq(stream.is_open, true)
}
///|
test "header names must be valid HTTP tokens" {
  for raw in [
    "HTTP/1.1 200 OK\r\nX-Test : value\r\nContent-Length: 0\r\n\r\n",
    "HTTP/1.1 200 OK\r\nX-T\u{e9}st: value\r\nContent-Length: 0\r\n\r\n",
    "HTTP/1.1 200 OK\r\nX@Test: value\r\nContent-Length: 0\r\n\r\n",
  ] {
    let codec = H1Codec::new(regression_mock_stream(raw, 0, 0))
    assert_true(codec.decode_response() is Err(_))
  }
}

///|
test "connection tokens are detected across repeated headers" {
  let raw = "HTTP/1.1 200 OK\r\nConnection: close\r\nConnection: keep-alive\r\nContent-Length: 2\r\n\r\nok"
  let stream = regression_mock_stream(raw, 1, 0)
  let codec = H1Codec::new(stream)
  let response = codec.decode_response().unwrap()
  assert_eq(response.text().unwrap(), "ok")
  assert_eq(stream.is_open, false)
}
///|
test "URL rejects malformed percent escapes outside the host" {
  for raw in [
    "http://example.com/%",
    "http://example.com/%zz",
    "http://example.com/a%2",
    "http://example.com/?x=%zz",
    "http://example.com/#%zz",
    "http://example.com/a\\b",
  ] {
    assert_true(Url::parse(raw) is Err(_))
  }
  for raw in [
    "http://example.com/%20",
    "http://example.com/?x=%2F",
    "http://example.com/#frag",
  ] {
    assert_true(Url::parse(raw) is Ok(_))
  }
}

///|
test "URL validates userinfo characters" {
  for raw in [
    "http://user%zz@example.com/",
    "http://user%2@example.com/",
    "http://user%@example.com/",
    "http://user%2G@example.com/",
    "http://us\\er@example.com/",
    "http://us[er@example.com/",
    "http://us]er@example.com/",
    "http://us{er@example.com/",
    "http://us|er@example.com/",
    "http://us^er@example.com/",
  ] {
    assert_true(Url::parse(raw) is Err(_))
  }
  for raw in [
    "http://user:pass@example.com/",
    "http://user%40name@example.com/",
    "http://user.name+tag@example.com/",
    "http://user:@example.com/",
    "http://@example.com/",
  ] {
    assert_true(Url::parse(raw) is Ok(_))
  }
}

///|
test "request encoding rejects malformed targets" {
  let url = Url::parse("http://example.com/").unwrap()
  for path in ["/a%zz", "/a\\b"] {
    let stream = regression_mock_stream("", 0, 0)
    let codec = H1Codec::new(stream)
    let request = Request::new(GET, url.with_path(path))
    assert_true(codec.encode_request(request) is Err(InvalidUrl(_)))
  }
}

///|
test "URL rejects unsafe host characters" {
  for raw in [
    "http://exa\\mple.com/",
    "http://exa\"mple.com/",
    "http://exa<mple.com/",
    "http://exa>mple.com/",
    "http://exa^mple.com/",
    "http://exa{mple.com/",
    "http://exa|mple.com/",
    "http://exa}mple.com/",
    "http://exa,mple.com/",
    "http://exa%zzmple.com/",
    "http://exa%2mple.com/",
    "http://exa%mple.com/",
  ] {
    assert_true(Url::parse(raw) is Err(_))
  }
  assert_true(Url::parse("http://exa_mple.example/") is Ok(_))
  assert_true(Url::parse("http://exa%20mple.example/") is Ok(_))
  assert_true(Url::parse("http://[2001:db8::1]/") is Ok(_))
}
///|
test "request encoding rejects duplicate or malformed Host headers" {
  let url = Url::parse("http://example.com/").unwrap()
  let duplicate = H1Codec::new(regression_mock_stream("", 0, 0))
  assert_true(
    duplicate.encode_request(
      Request::new(GET, url)
        .with_header("Host", "example.com")
        .with_header("Host", "other.example"),
    ) is Err(InvalidHeader(_)),
  )
  let malformed = H1Codec::new(regression_mock_stream("", 0, 0))
  assert_true(
    malformed.encode_request(
      Request::new(GET, url).with_header("Host", "bad host"),
    ) is Err(InvalidHeader(_)),
  )
  let valid = H1Codec::new(regression_mock_stream("", 0, 0))
  assert_true(
    valid.encode_request(
      Request::new(GET, url).with_header("Host", "example.com:8080"),
    ) is Ok(_),
  )
}
///|
test "request encoding accepts bracketed IPv6 Host headers" {
  let url = Url::parse("http://[::1]:8080/").unwrap()
  let stream = regression_mock_stream("", 0, 0)
  let codec = H1Codec::new(stream)
  assert_true(
    codec.encode_request(
      Request::new(GET, url).with_header("Host", "[::1]:8080"),
    ) is Ok(_),
  )
  assert_true(@utf8.decode(stream.output.to_bytes()[:]).contains("Host: [::1]:8080\r\n"))
  let bare = H1Codec::new(regression_mock_stream("", 0, 0))
  assert_true(
    bare.encode_request(
      Request::new(GET, url).with_header("Host", "[::1]"),
    ) is Ok(_),
  )
  for host in [
    "[::]",
    "[2001:db8::1]",
    "[::ffff:192.0.2.1]",
    "[fe80::1%25eth0]",
    "[v1.foo]",
  ] {
    let codec = H1Codec::new(regression_mock_stream("", 0, 0))
    assert_true(
      codec.encode_request(
        Request::new(GET, url).with_header("Host", host),
      ) is Ok(_),
    )
  }
  let automatic = regression_mock_stream("", 0, 0)
  let automatic_codec = H1Codec::new(automatic)
  assert_true(automatic_codec.encode_request(Request::new(GET, url)) is Ok(_))
  assert_true(@utf8.decode(automatic.output.to_bytes()[:]).contains("Host: [::1]:8080\r\n"))
}
///|
test "request encoding rejects malformed Host ports and IPv6 literals" {
  let url = Url::parse("http://example.com/").unwrap()
  for host in [
    "::1",
    "[::1",
    "::1]:80",
    "example.com:notaport",
    "example.com:70000",
    "[::1]:",
    ":80",
    "[foo]",
    "[[::1]]",
    "[:::]",
    "[1:2:3:4:5:6:7]",
    "[1:2:3:4:5:6:7:8:9]",
    "[::ffff:192.0.2.999]",
    "[1:::2]",
    "[::1%25]",
    "[::1%]",
    "exa\"mple.com",
    "exa<mple.com",
    "exa>mple.com",
    "exa^mple.com",
    "exa`mple.com",
    "exa{mple.com",
    "exa|mple.com",
    "exa}mple.com",
    "exa%zzmple.com",
  ] {
    let codec = H1Codec::new(regression_mock_stream("", 0, 0))
    assert_true(
      codec.encode_request(
        Request::new(GET, url).with_header("Host", host),
      ) is Err(InvalidHeader(_)),
    )
  }
}
///|
test "chunked trailers must be valid header fields" {
  for trailer in ["Bad Trailer: x", "X-Test: a\rb", ": value", "X-Test"] {
    let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n" +
      trailer + "\r\n\r\n"
    let codec = H1Codec::new(regression_mock_stream(raw, 0, 0))
    let response = codec.decode_response().unwrap()
    assert_true(response.read_body() is Err(_))
  }
}
///|
test "connector validates TLS settings before dialing" {
  let stream = regression_mock_stream("", 0, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
    .with_tls_config(TlsConfig::new("base.example").with_alpn(@list.List(["h2", ""])))
  let url = Url::parse("https://example.com/").unwrap()
  assert_true(connector.connect(url) is Err(TlsError(InvalidConfig(_))))
  assert_eq(dialer.count, 0)
}
///|
test "connector applies its timeout before TLS handshakes" {
  let stream = regression_mock_stream("", 0, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test")).with_timeout(
    1234,
  )
  let url = Url::parse("https://example.com/").unwrap()
  let _ = connector.connect(url).unwrap()
  assert_eq(stream.last_timeout, 1234)
}
///|
test "connector applies its timeout to HTTP connections" {
  let stream = regression_mock_stream("", 0, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test")).with_timeout(
    1234,
  )
  let url = Url::parse("http://example.com/").unwrap()
  let _ = connector.connect(url).unwrap()
  assert_eq(stream.last_timeout, 1234)
}
///|
test "redirect origin comparison ignores host case" {
  let raw = "HTTP/1.1 302 Found\r\nLocation: http://EXAMPLE.com/next\r\nContent-Length: 0\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
  let stream = regression_mock_stream(raw, 1, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let client = UnifiedClient::{ connector, options: ClientOptions::new(), redirect_count: 0 }
  let url = Url::parse("http://example.com/start").unwrap()
  let response = client.request(
    Request::new(GET, url).with_header("Authorization", "Bearer token"),
  ).unwrap()
  assert_eq(response.status, 200)
  let wire = @utf8.decode(stream.output.to_bytes()[:])
  let next_index = wire.find("GET /next HTTP/1.1").unwrap()
  assert_true(wire.substring(start=next_index).contains("Authorization: Bearer token"))
}
///|
test "HTTP method parsing accepts standard verbs" {
  for verb in ["GET", "post", "Put", "DELETE", "HEAD", "OPTIONS", "PATCH"] {
    assert_true(HttpMethod::parse(verb) is Ok(_))
  }
  assert_eq(HttpMethod::parse("get").unwrap(), GET)
  assert_true(HttpMethod::parse("BREW") is Err(InvalidMethod(_)))
  assert_true(HttpMethod::parse("") is Err(InvalidMethod(_)))
}

///|
test "URL builders update individual components" {
  let url = Url::parse("https://example.com/old?x=1#frag").unwrap()
  let updated = url
    .with_path("/new")
    .with_query("y=2")
    .with_fragment("other")
  assert_eq(updated.to_string(), "https://example.com/new?y=2#other")
  let cleared = updated.with_query("").with_fragment("")
  assert_eq(cleared.to_string(), "https://example.com/new")
}

///|
test "Request with_method changes only the verb" {
  let url = Url::parse("http://example.com/").unwrap()
  let request = Request::new(GET, url)
    .with_header("X-Test", "yes")
    .with_method(POST)
    .with_body(b"body")
  assert_eq(request.method, POST)
  assert_eq(request.get_header("X-Test").unwrap(), "yes")
  assert_eq(request.body.unwrap(), b"body")
}
struct NoProgressStream {
  mut is_open : Bool
}

pub impl Stream for NoProgressStream with fn read(self : NoProgressStream, buf : Buffer) -> Result[Int, NetError] {
  let _ = self
  let _ = buf
  Ok(1)
}

pub impl Stream for NoProgressStream with fn write(self : NoProgressStream, buf : Buffer) -> Result[Int, NetError] {
  Ok(buf.length())
}

pub impl Stream for NoProgressStream with fn flush(self : NoProgressStream) -> Result[Unit, NetError] {
  let _ = self
  Ok(())
}

pub impl Stream for NoProgressStream with fn close(self : NoProgressStream) -> Result[Unit, NetError] {
  self.is_open = false
  Ok(())
}

pub impl Stream for NoProgressStream with fn set_timeout(self : NoProgressStream, timeout_ms : Int) -> Result[Unit, NetError] {
  let _ = self
  let _ = timeout_ms
  Ok(())
}

pub impl Stream for NoProgressStream with fn peer_addr(self : NoProgressStream) -> Result[String, NetError] {
  let _ = self
  Ok("mock:0")
}

pub impl Stream for NoProgressStream with fn local_addr(self : NoProgressStream) -> Result[String, NetError] {
  let _ = self
  Ok("mock:0")
}

struct ReadErrorStream {
  mut is_open : Bool
}

pub impl Stream for ReadErrorStream with fn read(self : ReadErrorStream, buf : Buffer) -> Result[Int, NetError] {
  let _ = self
  let _ = buf
  Err(NetError::ReadError("read failed"))
}

pub impl Stream for ReadErrorStream with fn write(self : ReadErrorStream, buf : Buffer) -> Result[Int, NetError] {
  let _ = self
  Ok(buf.length())
}

pub impl Stream for ReadErrorStream with fn flush(self : ReadErrorStream) -> Result[Unit, NetError] {
  let _ = self
  Ok(())
}

pub impl Stream for ReadErrorStream with fn close(self : ReadErrorStream) -> Result[Unit, NetError] {
  self.is_open = false
  Ok(())
}

pub impl Stream for ReadErrorStream with fn set_timeout(self : ReadErrorStream, timeout_ms : Int) -> Result[Unit, NetError] {
  let _ = self
  let _ = timeout_ms
  Ok(())
}

pub impl Stream for ReadErrorStream with fn peer_addr(self : ReadErrorStream) -> Result[String, NetError] {
  let _ = self
  Ok("mock:0")
}

pub impl Stream for ReadErrorStream with fn local_addr(self : ReadErrorStream) -> Result[String, NetError] {
  let _ = self
  Ok("mock:0")
}

///|
test "streams reporting progress without data are rejected" {
  let stream = NoProgressStream::{ is_open: true }
  let codec = H1Codec::new(stream)
  assert_true(codec.decode_response() is Err(NetworkError(ReadError(_))))
}
///|
test "response status helpers and URL scheme checks" {
  let response = Response::new(204, Headers::new(), regression_mock_stream("", 4096, 4096))
  assert_true(response.is_success())
  assert_false(response.is_redirection())
  assert_false(response.is_client_error())
  assert_false(response.is_server_error())
  let redirect = Response::new(308, Headers::new(), regression_mock_stream("", 4096, 4096))
  assert_true(redirect.is_redirection())
  let client_error = Response::new(404, Headers::new(), regression_mock_stream("", 4096, 4096))
  assert_true(client_error.is_client_error())
  let server_error = Response::new(503, Headers::new(), regression_mock_stream("", 4096, 4096))
  assert_true(server_error.is_server_error())
  let url = Url::parse("http://example.com/").unwrap()
  assert_false(url.is_secure())
  assert_true(Url::parse("HTTPS://example.com/").unwrap().is_secure())
}
///|
test "basic auth replaces existing authorization headers" {
  let url = Url::parse("https://example.com/").unwrap()
  let request = Request::new(GET, url)
    .with_header("Authorization", "Bearer old")
    .with_basic_auth("user", "pass")
  assert_eq(request.get_header("Authorization").unwrap(), "Basic dXNlcjpwYXNz")
  assert_eq(request.headers.length(), 1)
  assert_eq(request.with_basic_auth("", "").get_header("Authorization").unwrap(), "Basic Og==")
}
///|
test "chunked transfer coding must be final" {
  let invalid = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked, gzip\r\n\r\n5\r\nhello\r\n0\r\n\r\n"
  let response = H1Codec::new(regression_mock_stream(invalid, 4096, 4096)).decode_response().unwrap()
  assert_true(response.read_body() is Err(NetworkError(ReadError(_))))
  let valid = "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n"
  let response = H1Codec::new(regression_mock_stream(valid, 4096, 4096)).decode_response().unwrap()
  assert_eq(response.read_body().unwrap(), b"hello")
}
///|
test "reading a body rejects streams that make no progress" {
  let response = Response::new(200, Headers::new(), NoProgressStream::{ is_open: true })
  assert_true(response.read_body() is Err(NetworkError(ReadError(_))))
}
///|
test "response body reads enforce an explicit limit" {
  let response = Response::new(200, Headers::new(), regression_mock_stream("hello", 4096, 4096))
  assert_true(response.read_body_with_limit(4) is Err(NetworkError(ReadError(_))))
  let response = Response::new(200, Headers::new(), regression_mock_stream("hello", 4096, 4096))
  assert_eq(response.read_body_with_limit(5).unwrap(), b"hello")
}

///|
test "exceeding an explicit body limit closes the response stream" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhelloHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
  let stream = regression_mock_stream(raw, 4096, 0)
  let codec = H1Codec::new(stream)
  let response = codec.decode_response().unwrap()
  assert_true(response.read_body_with_limit(2) is Err(NetworkError(ReadError(_))))
  assert_false(stream.is_open)

  let stalled = Response::new(200, Headers::new(), NoProgressStream::{ is_open: true })
  assert_true(stalled.read_body_with_limit(4) is Err(NetworkError(ReadError(_))))
}
///|
test "body read errors close the response stream" {
  let stream = ReadErrorStream::{ is_open: true }
  let response = Response::new(200, Headers::new(), stream)
  assert_true(response.read_body_with_limit(4) is Err(NetworkError(ReadError(_))))
  assert_false(stream.is_open)
}
///|
test "client option builders clamp negative limits" {
  let options = ClientOptions::new()
    .with_timeout(-5)
    .with_max_redirects(-3)
  assert_eq(options.timeout_ms, 0)
  assert_eq(options.max_redirects, 0)
  assert_eq(TcpDialer::with_timeout(-1).timeout_ms, 0)
}
///|
test "form requests percent-encode fields" {
  let url = Url::parse("https://example.com/submit").unwrap()
  let request = Request::new(POST, url).with_form([
    ("q", "hello world"),
    ("symbols", "a+b&c=d/é"),
    ("empty", ""),
  ])
  assert_eq(request.get_header("Content-Type").unwrap(), "application/x-www-form-urlencoded")
  assert_eq(request.headers.get_all("Content-Type").length(), 1)
  assert_eq(
    @utf8.decode(request.body.unwrap()[:]),
    "q=hello+world&symbols=a%2Bb%26c%3Dd%2F%C3%A9&empty=",
  )
  let encoded = H1Codec::new(regression_mock_stream("", 0, 0))
  assert_true(encoded.encode_request(request) is Ok(_))
  let replaced = Request::new(POST, url)
    .set_header("Content-Type", "text/plain")
    .with_form([("a", "b")])
  assert_eq(replaced.headers.get_all("Content-Type").length(), 1)
  assert_eq(replaced.get_header("Content-Type").unwrap(), "application/x-www-form-urlencoded")
}
///|
test "empty Location headers are not followed" {
  let raw = "HTTP/1.1 302 Found\r\nLocation:   \r\nContent-Length: 0\r\n\r\n"
  let stream = regression_mock_stream(raw, 4096, 4096)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let client = UnifiedClient::{ connector, options: ClientOptions::new(), redirect_count: 0 }
  let url = Url::parse("http://example.com/start").unwrap()
  let response = client.request(Request::new(GET, url)).unwrap()
  assert_eq(response.status, 302)
  assert_eq(dialer.count, 1)
}
///|
test "request headers can be replaced and removed" {
  let url = Url::parse("https://example.com/").unwrap()
  let request = Request::new(GET, url)
    .with_header("X-Test", "one")
    .with_header("X-Test", "two")
    .set_header("X-Test", "three")
    .without_header("Missing")
  assert_eq(request.headers.get_all("X-Test"), @list.List(["three"]))
}
///|
test "replacing TLS configuration closes the old pool" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
  let stream = regression_mock_stream(raw, 4096, 4096)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let client = UnifiedClient::{ connector, options: ClientOptions::new(), redirect_count: 0 }
  let url = Url::parse("http://example.com/").unwrap()
  let _ = client.request(Request::new(GET, url)).unwrap()
  let _ = client.with_tls_config(TlsConfig::new("example.com"))
  assert_false(stream.is_open)
}
///|
test "replacing connector TLS configuration closes its pool" {
  let first_stream = regression_mock_stream("", 1, 0)
  let second_stream = regression_mock_stream("", 1, 0)
  let streams : Array[&Stream] = [first_stream, second_stream]
  let dialer = RegressionQueueDialer::{ streams, index: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let url = Url::parse("http://example.com/").unwrap()
  let _ = connector.connect(url).unwrap()
  let replaced = connector.with_tls_config(TlsConfig::new("example.com"))
  assert_false(first_stream.is_open)
  let _ = replaced.connect(url).unwrap()
  assert_eq(dialer.index, 2)
}
///|
test "replacing connector TLS configuration isolates the new pool" {
  let first = regression_mock_stream("", 1, 0)
  let second = regression_mock_stream("", 1, 0)
  let third = regression_mock_stream("", 1, 0)
  let streams : Array[&Stream] = [first, second, third]
  let dialer = RegressionQueueDialer::{ streams, index: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let url = Url::parse("http://example.com/").unwrap()
  let _ = connector.connect(url).unwrap()
  let replaced = connector.with_tls_config(TlsConfig::new("example.com"))
  let _ = replaced.connect(url).unwrap()
  assert_eq(dialer.index, 2)
  let _ = connector.connect(url).unwrap()
  assert_eq(dialer.index, 3)
}
///|
test "101 responses close the upgraded connection" {
  let raw = "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n"
  let stream = regression_mock_stream(raw, 0, 0)
  let codec = H1Codec::new(stream)
  let response = codec.decode_response().unwrap()
  assert_eq(response.status, 101)
  assert_eq(response.body.read(@buffer.new(size_hint=4)).unwrap(), 0)
  assert_false(stream.is_open)
}
///|
test "client closes upgraded connections without a body read" {
  let raw = "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n"
  let stream = regression_mock_stream(raw, 0, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let options = ClientOptions::new().with_follow_redirects(false)
  let client = UnifiedClient::{ connector, options, redirect_count: 0 }
  let url = Url::parse("http://example.com/").unwrap()
  let response = client.request(Request::new(GET, url)).unwrap()
  assert_eq(response.status, 101)
  assert_false(stream.is_open)
}

///|
test "failed HEAD encoding does not change response framing" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"
  let codec = H1Codec::new(regression_mock_stream(raw, 0, 0))
  let url = Url::parse("http://example.com/").unwrap()
  let invalid = Request::new(HEAD, url).with_header("X-Test", "bad\r\nvalue")
  assert_true(codec.encode_request(invalid) is Err(_))
  let response = codec.decode_response().unwrap()
  assert_eq(response.text().unwrap(), "hello")
}
///|
test "request and response expose repeated header values" {
  let raw = "HTTP/1.1 200 OK\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\nContent-Length: 0\r\n\r\n"
  let codec = H1Codec::new(regression_mock_stream(raw, 0, 0))
  let response = codec.decode_response().unwrap()
  assert_eq(response.get_header_all("Set-Cookie"), @list.List(["a=1", "b=2"]))
  let request = Request::new(GET, Url::parse("http://example.com/").unwrap())
    .with_header("X-Test", "one")
    .with_header("X-Test", "two")
  assert_eq(request.get_header_all("x-test"), @list.List(["one", "two"]))
}
///|
test "post_form sends a URL-encoded request" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
  let stream = regression_mock_stream(raw, 4096, 4096)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let client = UnifiedClient::{ connector, options: ClientOptions::new(), redirect_count: 0 }
  let response = client.post_form("http://example.com/submit", [("a", "b c")]).unwrap()
  assert_eq(response.text().unwrap(), "ok")
  let written = @utf8.decode(stream.output.to_bytes()[:])
  assert_true(written.has_suffix("\r\n\r\na=b+c"))
}
///|
test "connector caps idle connections per host" {
  let first = regression_mock_stream("", 1, 0)
  let second = regression_mock_stream("", 1, 0)
  let third = regression_mock_stream("", 1, 0)
  let fourth = regression_mock_stream("", 1, 0)
  let streams : Array[&Stream] = [first, second, third, fourth]
  let dialer = RegressionQueueDialer::{ streams, index: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
    .with_max_idle_per_host(2)
  assert_eq(connector.max_idle_per_host(), 2)
  let url = Url::parse("http://example.com/").unwrap()
  let (_s0, lease0) = connector.checkout(url).unwrap()
  let (_s1, lease1) = connector.checkout(url).unwrap()
  let (_s2, lease2) = connector.checkout(url).unwrap()
  let (_s3, lease3) = connector.checkout(url).unwrap()
  assert_eq(dialer.index, 4)
  lease0.release(true)
  lease1.release(true)
  lease2.release(true)
  lease3.release(true)
  assert_false(first.is_open)
  assert_false(second.is_open)
  assert_true(third.is_open)
  assert_true(fourth.is_open)
}

///|
test "connector clamps the idle cap to at least one" {
  let dialer = TcpDialer::new()
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
    .with_max_idle_per_host(0)
  assert_eq(connector.max_idle_per_host(), 1)
}

///|
test "connector enforces a per-host connection cap" {
  let first = regression_mock_stream("", 1, 0)
  let second = regression_mock_stream("", 1, 0)
  let streams : Array[&Stream] = [first, second]
  let dialer = RegressionQueueDialer::{ streams, index: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
    .with_max_connections_per_host(1)
  assert_eq(connector.max_connections_per_host(), 1)
  let url = Url::parse("http://example.com/").unwrap()
  let (_stream, lease) = connector.checkout(url).unwrap()
  assert_true(connector.checkout(url) is Err(_))
  assert_eq(dialer.index, 1)
  lease.release(false)
  assert_true(connector.checkout(url) is Ok(_))
  assert_eq(dialer.index, 2)
}

///|
test "connector connection cap is counted per host" {
  let first = regression_mock_stream("", 1, 0)
  let second = regression_mock_stream("", 1, 0)
  let streams : Array[&Stream] = [first, second]
  let dialer = RegressionQueueDialer::{ streams, index: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
    .with_max_connections_per_host(1)
  let (_s0, lease0) = connector.checkout(Url::parse("http://a.example/").unwrap()).unwrap()
  let (_s1, _lease1) = connector.checkout(Url::parse("http://b.example/").unwrap()).unwrap()
  let _ = lease0
  assert_eq(dialer.index, 2)
}

///|
test "connector clamps the connection cap to unlimited" {
  let dialer = TcpDialer::new()
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
    .with_max_connections_per_host(0)
  assert_eq(connector.max_connections_per_host(), 0)
}

///|
test "connector rejects idle connections past the idle timeout" {
  let stream = regression_mock_stream("", 1, 0)
  let pool = @ref.Ref(ConnectionPoolState::new())
  let key = "http://example.com:80"
  pool.val.cache_idle(key, stream, 1000)
  // A lookup well before the timeout reuses the connection.
  match take_idle_stream_at(pool, key, 2000) {
    Some(_) => assert_true(stream.is_open)
    None => abort("live connection should be reused")
  }
  assert_true(take_idle_stream_at(pool, key, 2000) is None)

  let expired = regression_mock_stream("", 1, 0)
  pool.val.cache_idle(key, expired, 1000)
  assert_true(take_idle_stream_at(pool, key, 95000) is None)
  assert_false(expired.is_open)
}

///|
test "connector never evicts idle connections when the timeout is disabled" {
  let stream = regression_mock_stream("", 1, 0)
  let pool = @ref.Ref(ConnectionPoolState::new())
  pool.val.idle_timeout_ms = 0
  let key = "http://example.com:80"
  pool.val.cache_idle(key, stream, 1000)
  match take_idle_stream_at(pool, key, 999999999) {
    Some(_) => assert_true(stream.is_open)
    None => abort("idle timeout disabled should keep the connection")
  }
}

///|
test "connector exposes a configurable idle timeout" {
  let dialer = TcpDialer::new()
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  assert_eq(connector.idle_timeout(), 90000)
  assert_eq(connector.with_idle_timeout(5000).idle_timeout(), 5000)
  assert_eq(connector.with_idle_timeout(-1).idle_timeout(), 0)
}

///|
test "Proxy::new parses URL and credentials" {
  let proxy = Proxy::new("http://user:secret@proxy.example:3128").unwrap()
  assert_eq(proxy.authority(), "proxy.example:3128")
  assert_eq(proxy.authorization(), Some("Basic " + @base64.encode(@utf8.encode("user:secret"))))
  let plain = Proxy::new("http://proxy.example").unwrap()
  assert_eq(plain.authority(), "proxy.example")
  assert_true(plain.authorization() is None)
}

///|
test "Proxy::new rejects non-http schemes and bad ports" {
  assert_true(Proxy::new("https://proxy.example:443") is Err(InvalidUrl(_)))
  assert_true(Proxy::new("http://proxy.example:0") is Err(_))
  assert_true(Proxy::new("http://proxy.example:70000") is Err(_))
}

///|
test "Proxy::new_with_basic_auth encodes credentials" {
  let proxy = Proxy::new_with_basic_auth("127.0.0.1", 8080, "u", "p").unwrap()
  assert_eq(proxy.authority(), "127.0.0.1:8080")
  assert_eq(proxy.authorization(), Some("Basic " + @base64.encode(@utf8.encode("u:p"))))
}

///|
test "plain HTTP through a proxy uses absolute-form and proxy auth" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
  let stream = regression_mock_stream(raw, 4096, 4096)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let options = ClientOptions::new().with_follow_redirects(false)
  let client = UnifiedClient::{ connector, options, redirect_count: 0 }
  let proxy = Proxy::new("http://user:secret@proxy.example:3128").unwrap()
  let client = client.with_proxy(proxy)
  let url = Url::parse("http://example.com/path?x=1").unwrap()
  let response = client.request(Request::new(GET, url)).unwrap()
  assert_eq(response.text().unwrap(), "ok")
  assert_eq(dialer.count, 1)
  let wire = @utf8.decode(stream.output.to_bytes()[:])
  assert_true(wire.contains("GET http://example.com/path?x=1 HTTP/1.1\r\n"))
  assert_true(wire.contains("Proxy-Authorization: Basic " + @base64.encode(@utf8.encode("user:secret"))))
}

///|
test "plain HTTP through a proxy dials the proxy host" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
  let stream = regression_mock_stream(raw, 4096, 4096)
  let dialer = RegressionProxyDialer::{ stream, host: "", port: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test")).with_proxy(
    Proxy::new("http://proxy.example:3128").unwrap(),
  )
  let url = Url::parse("http://example.com/").unwrap()
  let _ = connector.connect(url).unwrap()
  assert_eq(dialer.host, "proxy.example")
  assert_eq(dialer.port, 3128)
}

///|
test "HTTPS through a proxy opens a CONNECT tunnel before TLS" {
  let raw = "HTTP/1.1 200 Connection Established\r\n\r\n"
  let stream = regression_mock_stream(raw, 4096, 4096)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test")).with_proxy(
    Proxy::new("http://user:secret@proxy.example:3128").unwrap(),
  )
  let url = Url::parse("https://example.com:8443/").unwrap()
  let _ = connector.connect(url).unwrap()
  let wire = @utf8.decode(stream.output.to_bytes()[:])
  assert_true(wire.has_prefix("CONNECT example.com:8443 HTTP/1.1\r\n"))
  assert_true(wire.contains("Host: example.com:8443\r\n"))
  assert_true(wire.contains("Proxy-Authorization: Basic " + @base64.encode(@utf8.encode("user:secret"))))
}

///|
test "HTTPS proxy CONNECT always includes the target port" {
  let raw = "HTTP/1.1 200 Connection Established\r\n\r\n"
  let stream = regression_mock_stream(raw, 4096, 4096)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test")).with_proxy(
    Proxy::new("http://proxy.example:3128").unwrap(),
  )
  let url = Url::parse("https://example.com/").unwrap()
  let _ = connector.connect(url).unwrap()
  let wire = @utf8.decode(stream.output.to_bytes()[:])
  assert_true(wire.has_prefix("CONNECT example.com:443 HTTP/1.1\r\n"))
  assert_true(wire.contains("Host: example.com:443\r\n"))
}

///|
test "failed proxy CONNECT returns an error" {
  let raw = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n"
  let stream = regression_mock_stream(raw, 4096, 4096)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test")).with_proxy(
    Proxy::new("http://proxy.example:3128").unwrap(),
  )
  let url = Url::parse("https://example.com/").unwrap()
  assert_true(connector.connect(url) is Err(_))
  assert_false(stream.is_open)
}

///|
test "replacing the proxy closes the old pool and isolates keys" {
  let first = regression_mock_stream("", 1, 0)
  let second = regression_mock_stream("", 1, 0)
  let streams : Array[&Stream] = [first, second]
  let dialer = RegressionQueueDialer::{ streams, index: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let url = Url::parse("http://example.com/").unwrap()
  let _ = connector.connect(url).unwrap()
  let proxied = connector.with_proxy(Proxy::new("http://proxy.example:3128").unwrap())
  assert_false(first.is_open)
  let _ = proxied.connect(url).unwrap()
  assert_eq(dialer.index, 2)
}

///|
test "client preserves TLS configuration when a proxy is added" {
  let raw = "HTTP/1.1 200 Connection Established\r\n\r\n"
  let stream = regression_mock_stream(raw, 4096, 4096)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let client = UnifiedClient::{ connector, options: ClientOptions::new(), redirect_count: 0 }
    .with_tls_config(TlsConfig::new("example.com"))
  let client = client.with_proxy(Proxy::new("http://proxy.example:3128").unwrap())
  assert_true(client.connector.tls_config is Some(_))
  assert_true(client.connector.proxy is Some(_))
}

///|
test "client preserves proxy when TLS configuration is replaced" {
  let connector = Connector::new(TcpDialer::new(), MockTlsProvider::new("test"))
  let client = UnifiedClient::{ connector, options: ClientOptions::new(), redirect_count: 0 }
    .with_proxy(Proxy::new("http://proxy.example:3128").unwrap())
  let client = client.with_tls_config(TlsConfig::new("example.com"))
  assert_true(client.connector.tls_config is Some(_))
  assert_true(client.connector.proxy is Some(_))
}

///|
test "with_proxy_url parses and applies a proxy string" {
  let connector = Connector::new(TcpDialer::new(), MockTlsProvider::new("test"))
  let client = UnifiedClient::{ connector, options: ClientOptions::new(), redirect_count: 0 }
  assert_true(client.with_proxy_url("http://proxy.example:8080") is Ok(_))
  assert_true(client.with_proxy_url("ftp://proxy.example") is Err(_))
}

///|
test "replacing TLS or proxy settings preserves pool tuning" {
  let connector = Connector::new(TcpDialer::new(), MockTlsProvider::new("test"))
  let client = UnifiedClient::{ connector, options: ClientOptions::new(), redirect_count: 0 }
    .with_max_idle_per_host(3)
    .with_idle_timeout(1234)
    .with_max_connections_per_host(2)
  let client = client
    .with_tls_config(TlsConfig::new("example.com"))
    .with_proxy(Proxy::new("http://proxy.example:3128").unwrap())
  assert_eq(client.connector.max_idle_per_host(), 3)
  assert_eq(client.connector.idle_timeout(), 1234)
  assert_eq(client.connector.max_connections_per_host(), 2)
}

///|
test "connector keeps idle connections when the clock moves backwards" {
  let stream = regression_mock_stream("", 1, 0)
  let pool = @ref.Ref(ConnectionPoolState::new())
  let key = "http://example.com:80"
  pool.val.idle_timeout_ms = 1000
  pool.val.cache_idle(key, stream, 5000)
  // A wall-clock adjustment must not make a fresh connection look expired.
  match take_idle_stream_at(pool, key, 1000) {
    Some(_) => assert_true(stream.is_open)
    None => abort("clock rollback should not expire a connection")
  }
}

///|
test "CONNECT response parsing tolerates tunnel data in the same read" {
  let raw = "HTTP/1.1 200 Connection Established\r\nProxy-Agent: proxy\r\n\r\nPRESHUTDOWN"
  let stream = regression_mock_stream(raw, 0, 0)
  assert_true(read_connect_response(stream) is Ok(_))
}

///|
test "CONNECT response parsing still accepts a head split across reads" {
  let stream = regression_mock_stream("HTTP/1.1 200 Connection Established\r\nA: b\r\n\r\n", 3, 0)
  assert_true(read_connect_response(stream) is Ok(_))
}

///|
test "CONNECT response parsing rejects a head without a terminator" {
  let stream = regression_mock_stream("HTTP/1.1 200 Connection Established\r\nA: b\r\n", 0, 0)
  assert_true(read_connect_response(stream) is Err(_))
}

///|
test "CONNECT failure is reported when tunnel data follows the head" {
  let stream = regression_mock_stream("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\nPRESHUTDOWN", 0, 0)
  assert_true(read_connect_response(stream) is Err(ProtocolError(_)))
}

///|
test "request encoding emits headers in insertion order" {
  let stream = regression_mock_stream("", 0, 0)
  let codec = H1Codec::new(stream)
  let url = Url::parse("http://example.com/").unwrap()
  let request = Request::new(GET, url)
    .with_header("X-First", "1")
    .with_header("X-Second", "2")
  assert_true(codec.encode_request(request) is Ok(_))
  let wire = @utf8.decode(stream.output.to_bytes()[:])
  assert_true(
    wire.has_suffix(
      "Host: example.com\r\nUser-Agent: Feather/0.1.0\r\nX-First: 1\r\nX-Second: 2\r\n\r\n",
    ),
  )
}

///|
test "response headers iterate in wire order" {
  let raw = "HTTP/1.1 200 OK\r\nX-One: 1\r\nX-Two: 2\r\nContent-Length: 0\r\n\r\n"
  let codec = H1Codec::new(regression_mock_stream(raw, 0, 0))
  let response = codec.decode_response().unwrap()
  let seen : Array[String] = []
  for header in response.headers.iter() {
    seen.push(header.name + "=" + header.value)
  }
  assert_eq(seen, ["X-One=1", "X-Two=2", "Content-Length=0"])
}
