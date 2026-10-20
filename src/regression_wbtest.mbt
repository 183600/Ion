struct MockStream {
  input : Bytes
  mut offset : Int
  output : Buffer
  max_read : Int
  max_write : Int
  mut is_open : Bool
}

fn mock_stream(input : String, max_read : Int, max_write : Int) -> MockStream {
  MockStream::{
    input: @utf8.encode(input),
    offset: 0,
    output: @buffer.new(size_hint=4096),
    max_read,
    max_write,
    is_open: true,
  }
}

pub impl Stream for MockStream with fn read(self : MockStream, buf : Buffer) -> Result[Int, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  let available = self.input.length() - self.offset
  let read_limit = if self.max_read > 0 { self.max_read } else { 1 }
  let limit = if read_limit < available { read_limit } else { available }
  let mut i = 0
  while i < limit {
    buf.write_byte(self.input[self.offset + i])
    i = i + 1
  }
  self.offset = self.offset + limit
  Ok(limit)
}

pub impl Stream for MockStream with fn write(self : MockStream, buf : Buffer) -> Result[Int, NetError] {
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

pub impl Stream for MockStream with fn flush(self : MockStream) -> Result[Unit, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Ok(())
}

pub impl Stream for MockStream with fn close(self : MockStream) -> Result[Unit, NetError] {
  self.is_open = false
  Ok(())
}

pub impl Stream for MockStream with fn set_timeout(self : MockStream, timeout_ms : Int) -> Result[Unit, NetError] {
  let _ = timeout_ms
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Ok(())
}

pub impl Stream for MockStream with fn peer_addr(self : MockStream) -> Result[String, NetError] {
  Ok("mock:0")
}

pub impl Stream for MockStream with fn local_addr(self : MockStream) -> Result[String, NetError] {
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
  let stream = mock_stream("", 0, 3)
  let codec = H1Codec::new(stream)
  let url = Url::parse("http://example.com:8080/path?x=1").unwrap()
  let req = Request::new(GET, url)
  assert_true(codec.encode_request(req) is Ok(_))
  let expected = @utf8.encode("GET /path?x=1 HTTP/1.1\r\nHost: example.com:8080\r\nUser-Agent: Feather/0.1.0\r\n\r\n")
  assert_eq(stream.output.to_bytes(), expected)
}

///|
test "request encoding does not duplicate Content-Length" {
  let stream = mock_stream("", 0, 0)
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
test "response body honors Content-Length" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nX-Test: Yes\r\n\r\nhelloEXTRA"
  let stream = mock_stream(raw, 1, 0)
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
  let stream = mock_stream(raw, 1, 0)
  let codec = H1Codec::new(stream)
  let response = codec.decode_response().unwrap()
  let buf = @buffer.new(size_hint=32)
  assert_eq(response.body.read(buf).unwrap(), 11)
  assert_eq(buf.to_bytes(), @utf8.encode("hello world"))
}

///|
test "invalid Content-Length error is sticky" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: nope\r\n\r\n"
  let stream = mock_stream(raw, 1, 0)
  let codec = H1Codec::new(stream)
  let response = codec.decode_response().unwrap()
  assert_true(response.body.read(@buffer.new(size_hint=4)) is Err(_))
  assert_true(response.body.read(@buffer.new(size_hint=4)) is Err(_))
}

///|
test "204 response has no body" {
  let raw = "HTTP/1.1 204 No Content\r\n\r\nnext-response"
  let stream = mock_stream(raw, 1, 0)
  let codec = H1Codec::new(stream)
  let response = codec.decode_response().unwrap()
  let buf = @buffer.new(size_hint=8)
  assert_eq(response.body.read(buf).unwrap(), 0)
  assert_eq(stream.offset, "HTTP/1.1 204 No Content\r\n\r\n".length())
}

///|
test "HEAD response has no body" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"
  let stream = mock_stream(raw, 1, 0)
  let codec = H1Codec::new(stream)
  let response = codec.decode_response(head=true).unwrap()
  let buf = @buffer.new(size_hint=8)
  assert_eq(response.body.read(buf).unwrap(), 0)
  assert_eq(stream.offset, "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n".length())
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
