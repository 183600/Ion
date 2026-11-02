///|
struct JsonMockStream {
  input : Bytes
  mut offset : Int
  output : Buffer
  mut is_open : Bool
}

fn json_mock_stream(input : String) -> JsonMockStream {
  json_mock_stream_bytes(@utf8.encode(input))
}

///|
fn json_mock_stream_bytes(input : Bytes) -> JsonMockStream {
  JsonMockStream::{
    input,
    offset: 0,
    output: @buffer.new(size_hint=1024),
    is_open: true,
  }
}

pub impl Stream for JsonMockStream with fn read(self : JsonMockStream, buf : Buffer) -> Result[Int, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  let available = self.input.length() - self.offset
  let mut i = 0
  while i < available {
    buf.write_byte(self.input[self.offset + i])
    i = i + 1
  }
  self.offset = self.offset + available
  Ok(available)
}

pub impl Stream for JsonMockStream with fn write(self : JsonMockStream, buf : Buffer) -> Result[Int, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  let data = buf.to_bytes()
  let mut i = 0
  while i < data.length() {
    self.output.write_byte(data[i])
    i = i + 1
  }
  Ok(data.length())
}

pub impl Stream for JsonMockStream with fn flush(self : JsonMockStream) -> Result[Unit, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Ok(())
}

pub impl Stream for JsonMockStream with fn close(self : JsonMockStream) -> Result[Unit, NetError] {
  self.is_open = false
  Ok(())
}

pub impl Stream for JsonMockStream with fn set_timeout(self : JsonMockStream, _timeout_ms : Int) -> Result[Unit, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Ok(())
}

pub impl Stream for JsonMockStream with fn peer_addr(self : JsonMockStream) -> Result[String, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Ok("json-mock:0")
}

pub impl Stream for JsonMockStream with fn local_addr(_self : JsonMockStream) -> Result[String, NetError] {
  Ok("json-mock:0")
}

///|
fn json_response(body : String) -> Response {
  let stream = json_mock_stream(body)
  Response::new(200, Headers::new().add("Content-Type", "application/json"), stream)
}

/// Build a gzip member that stores `payload` in a single uncompressed
/// DEFLATE block, so the JSON helpers can be exercised against an encoded
/// response body.
fn json_gzip_member(payload : Bytes) -> Bytes {
  let output = Buffer(size_hint=payload.length() + 32)
  // gzip header: magic, deflate, no flags, no mtime, no extra flags, unix.
  output.write_byte(31)
  output.write_byte(139)
  output.write_byte(8)
  output.write_byte(0)
  output.write_byte(0)
  output.write_byte(0)
  output.write_byte(0)
  output.write_byte(0)
  output.write_byte(0)
  output.write_byte(3)
  // One final stored block.
  output.write_byte(1)
  let length = payload.length()
  output.write_byte((length & 0xFF).to_byte())
  output.write_byte(((length >> 8) & 0xFF).to_byte())
  output.write_byte(((length ^ 0xFFFF) & 0xFF).to_byte())
  output.write_byte((((length ^ 0xFFFF) >> 8) & 0xFF).to_byte())
  output.write_bytes(payload)
  let checksum = crc32(payload)
  output.write_byte((checksum & 0xFF).to_byte())
  output.write_byte(((checksum >> 8) & 0xFF).to_byte())
  output.write_byte(((checksum >> 16) & 0xFF).to_byte())
  output.write_byte(((checksum >> 24) & 0xFF).to_byte())
  output.write_byte((length & 0xFF).to_byte())
  output.write_byte(((length >> 8) & 0xFF).to_byte())
  output.write_byte(((length >> 16) & 0xFF).to_byte())
  output.write_byte(((length >> 24) & 0xFF).to_byte())
  output.to_bytes()
}

///|
test "parse_json accepts documents and rejects malformed input" {
  let parsed = parse_json("{\"name\":\"Feather\"}").unwrap()
  assert_eq(parsed.value("name").unwrap().as_string(), Some("Feather"))
  assert_eq(stringify_json(Json::string("hi")), "\"hi\"")
  assert_true(parse_json("{\"name\":") is Err(_))
  assert_true(parse_json("{} trailing") is Err(_))
}

///|
test "Response json parses the decoded body" {
  let response = json_response("{\"ok\":true}")
  let json = response.json().unwrap()
  assert_eq(json.value("ok").unwrap().as_bool(), Some(true))
}

///|
test "Response json rejects malformed documents" {
  let response = json_response("not json")
  match response.json() {
    Err(ProtocolError(message)) => assert_true(message.has_prefix("invalid JSON"))
    _ => fail("expected a protocol error")
  }
}

///|
test "Response json honors the body limit" {
  let response = json_response("{\"padding\":\"0123456789\"}")
  assert_true(response.json_with_limit(4) is Err(_))
}

///|
test "Response json decodes gzip encoded bodies" {
  let compressed = json_gzip_member(@utf8.encode("{\"ok\":1}"))
  let stream = json_mock_stream_bytes(compressed)
  let response = Response::new(
    200,
    Headers::new().add("Content-Encoding", "gzip"),
    stream,
  )
  assert_eq(response.json().unwrap().value("ok").unwrap().as_number(), Some(1.0))
}

///|
test "Request with_json sets the content type and body" {
  let request = Request::from_url(POST, "http://example.com/api").unwrap()
    .with_json(parse_json("{\"a\":1}").unwrap())
  assert_eq(request.get_header("Content-Type"), Some("application/json"))
  assert_eq(@utf8.decode_lossy(request.body.unwrap()[:]), "{\"a\":1}")
}

///|
test "Request with_json keeps an explicit content type" {
  let request = Request::from_url(POST, "http://example.com/api").unwrap()
    .with_header("Content-Type", "application/vnd.api+json")
    .with_json_text("{}")
  assert_eq(
    request.get_header("Content-Type"),
    Some("application/vnd.api+json"),
  )
}

///|
test "Request with_json_value serializes any JSON value" {
  let request = Request::from_url(POST, "http://example.com/api").unwrap()
    .with_json_value(["a", "b"])
  assert_eq(@utf8.decode_lossy(request.body.unwrap()[:]), "[\"a\",\"b\"]")
}

///|
test "post_json sends a JSON body and parses the response" {
  let stream = json_mock_stream(
    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 13\r\n\r\n{\"result\":42}",
  )
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let client = UnifiedClient::{ connector, options: ClientOptions::new(), redirect_count: 0 }
  let response = client
    .post_json("http://example.com/api", parse_json("{\"q\":1}").unwrap())
    .unwrap()
  assert_eq(response.json().unwrap().value("result").unwrap().as_number(), Some(42.0))
  assert_eq(dialer.count, 1)
}
