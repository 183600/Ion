fn h2_test_concat(frames : Array[Bytes]) -> Bytes {
  let output = Buffer(size_hint=1024)
  for frame in frames {
    output.write_bytes(frame)
  }
  output.to_bytes()
}

fn h2_test_frame(
  frame_type : Int,
  flags : Int,
  stream_id : Int,
  payload : Bytes,
) -> Bytes {
  h2_frame_bytes(frame_type, flags, stream_id, payload)
}

fn h2_test_settings() -> Bytes {
  h2_test_frame(
    H2_FRAME_SETTINGS,
    0,
    0,
    h2_settings_payload([(H2_SETTINGS_INITIAL_WINDOW_SIZE, H2_DEFAULT_WINDOW_SIZE)]),
  )
}

fn h2_test_header_value(fields : Array[(String, String)], name : String) -> String? {
  for field in fields {
    let (field_name, field_value) = field
    if field_name == name {
      return Some(field_value)
    }
  }
  None
}

fn h2_test_client_frames(stream : H2FrameMockStream) -> Array[H2Frame] {
  let reader = StreamReader::new(h2_frame_mock_stream(stream.output.to_bytes(), 0))
  let preface : Array[Byte] = []
  reader.read_exact(H2_PREFACE.length(), preface).unwrap()
  let frames : Array[H2Frame] = []
  while true {
    match h2_read_frame(reader) {
      Ok(frame) => frames.push(frame)
      Err(_) => break
    }
  }
  frames
}

test "http2 request returns a buffered response body" {
  let response_headers = hpack_encode([
    (":status", "200"),
    ("content-type", "text/plain"),
    ("x-test", "ok"),
  ])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM, 1, response_headers),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let request = Request::new(GET, Url::parse("https://example.com/path?q=1").unwrap())
  let response = h2_request(stream, request).unwrap()
  assert_eq(response.version, "HTTP/2")
  assert_eq(response.status, 200)
  assert_eq(response.headers.get("content-type"), Some("text/plain"))
  assert_eq(response.headers.get("x-test"), Some("ok"))
  assert_eq(response.read_body().unwrap(), b"")
}

test "http2 request sends pseudo headers and body data" {
  let response_headers = hpack_encode([(":status", "201"), ("x-response", "yes")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, response_headers),
    h2_test_frame(H2_FRAME_DATA, H2_FLAG_END_STREAM, 1, @utf8.encode("response")),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let request = Request::new(POST, Url::parse("https://example.com/upload?x=1").unwrap())
    .with_body(@utf8.encode("payload"))
    .set_header("X-Custom", "custom")
    .set_header("Host", "ignored.example")
    .set_header("Connection", "close")
  let response = h2_request(stream, request).unwrap()
  assert_eq(response.status, 201)
  assert_eq(response.read_body().unwrap(), @utf8.encode("response"))

  let frames = h2_test_client_frames(stream)
  assert_eq(frames[0].frame_type, H2_FRAME_SETTINGS)
  let mut header_frame : H2Frame? = None
  let mut data_frame : H2Frame? = None
  for frame in frames {
    if frame.frame_type == H2_FRAME_HEADERS && header_frame is None {
      header_frame = Some(frame)
    }
    if frame.frame_type == H2_FRAME_DATA && data_frame is None {
      data_frame = Some(frame)
    }
  }
  let header_frame = header_frame.unwrap()
  assert_eq(header_frame.stream_id, 1)
  let decoder = HpackDecoder::new()
  let fields = decoder.decode(header_frame.payload).unwrap()
  assert_eq(h2_test_header_value(fields, ":method"), Some("POST"))
  assert_eq(h2_test_header_value(fields, ":scheme"), Some("https"))
  assert_eq(h2_test_header_value(fields, ":authority"), Some("example.com"))
  assert_eq(h2_test_header_value(fields, ":path"), Some("/upload?x=1"))
  assert_eq(h2_test_header_value(fields, "content-length"), Some("7"))
  assert_eq(h2_test_header_value(fields, "x-custom"), Some("custom"))
  assert_eq(h2_test_header_value(fields, "host"), None)
  assert_eq(h2_test_header_value(fields, "connection"), None)
  let data_frame = data_frame.unwrap()
  assert_eq(data_frame.flags, H2_FLAG_END_STREAM)
  assert_eq(@utf8.decode_lossy(data_frame.payload[:]), "payload")
}

test "http2 skips informational responses and records trailers" {
  let informational = hpack_encode([(":status", "103"), ("link", "</style.css>; rel=preload")])
  let final_headers = hpack_encode([(":status", "200"), ("content-type", "text/plain")])
  let trailers = hpack_encode([("x-trailer", "done")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, informational),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, final_headers),
    h2_test_frame(H2_FRAME_DATA, 0, 1, @utf8.encode("hello ")),
    h2_test_frame(H2_FRAME_DATA, 0, 1, @utf8.encode("world")),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM, 1, trailers),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  let response = h2_request(stream, request).unwrap()
  assert_eq(response.status, 200)
  assert_eq(response.headers.get("link"), None)
  assert_eq(response.read_body().unwrap(), @utf8.encode("hello world"))
  assert_eq(response.trailers().get("x-trailer"), Some("done"))
}

test "http2 applies flow control while sending a large body" {
  let response_headers = hpack_encode([(":status", "204")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(
      H2_FRAME_WINDOW_UPDATE,
      0,
      1,
      h2_window_update_payload(100000),
    ),
    h2_test_frame(
      H2_FRAME_WINDOW_UPDATE,
      0,
      0,
      h2_window_update_payload(100000),
    ),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM, 1, response_headers),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let request = Request::new(POST, Url::parse("https://example.com/large").unwrap())
    .with_body(Bytes::make(70000, b'x'))
  let response = h2_request(stream, request).unwrap()
  assert_eq(response.status, 204)
  let frames = h2_test_client_frames(stream)
  let mut body_bytes = 0
  for frame in frames {
    if frame.frame_type == H2_FRAME_DATA {
      body_bytes = body_bytes + frame.payload.length()
    }
  }
  assert_eq(body_bytes, 70000)
}

test "http2 rejects a response body over the configured limit" {
  let response_headers = hpack_encode([(":status", "200")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, response_headers),
    h2_test_frame(H2_FRAME_DATA, H2_FLAG_END_STREAM, 1, @utf8.encode("too large")),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  match h2_request_with_limit(stream, request, 4) {
    Ok(_) => fail("HTTP/2 body limit was not enforced")
    Err(err) => assert_eq(err, ProtocolError("HTTP/2 response body too large"))
  }
}

test "http2 rejects an out-of-range initial window setting" {
  let flow = H2FlowState::new()
  let too_large = h2_settings_payload([
    (H2_SETTINGS_INITIAL_WINDOW_SIZE, -2147483648),
  ])
  match h2_apply_settings(too_large, flow) {
    Err(err) => assert_eq(err, ProtocolError("Invalid HTTP/2 initial window size"))
    Ok(_) => fail("out-of-range HTTP/2 initial window was accepted")
  }

  let maximum = h2_settings_payload([
    (H2_SETTINGS_INITIAL_WINDOW_SIZE, H2_MAX_WINDOW_SIZE),
  ])
  h2_apply_settings(maximum, flow).unwrap()
  assert_eq(flow.peer_initial_window, H2_MAX_WINDOW_SIZE)
  assert_eq(flow.stream_send_window, H2_MAX_WINDOW_SIZE)

  for invalid in [0, H2_MAX_FRAME_SIZE - 1, H2_MAX_FRAME_SIZE_LIMIT + 1] {
    let payload = h2_settings_payload([(H2_SETTINGS_MAX_FRAME_SIZE, invalid)])
    match h2_apply_settings(payload, flow) {
      Err(err) => assert_eq(err, ProtocolError("Invalid HTTP/2 max frame size"))
      Ok(_) => fail("invalid HTTP/2 max frame size was accepted")
    }
  }
  let valid = h2_settings_payload([(H2_SETTINGS_MAX_FRAME_SIZE, H2_MAX_FRAME_SIZE)])
  h2_apply_settings(valid, flow).unwrap()

  let overflow = H2FlowState::new()
  let zero = h2_settings_payload([(H2_SETTINGS_INITIAL_WINDOW_SIZE, 0)])
  h2_apply_settings(zero, overflow).unwrap()
  assert_eq(overflow.stream_send_window, 0)
  overflow.stream_send_window = H2_MAX_WINDOW_SIZE
  let maximum_again = h2_settings_payload([
    (H2_SETTINGS_INITIAL_WINDOW_SIZE, H2_MAX_WINDOW_SIZE),
  ])
  match h2_apply_settings(maximum_again, overflow) {
    Err(err) => assert_eq(err, ProtocolError("HTTP/2 stream window overflow"))
    Ok(_) => fail("HTTP/2 stream window overflow was accepted")
  }
  assert_eq(overflow.stream_send_window, H2_MAX_WINDOW_SIZE)
  assert_eq(overflow.peer_initial_window, 0)

  match h2_apply_settings(b"\x00\x04\x00\x00\x00", flow) {
    Err(err) => assert_eq(err, ProtocolError("Invalid HTTP/2 SETTINGS length"))
    Ok(_) => fail("truncated HTTP/2 SETTINGS was accepted")
  }
}

test "http2 propagates stream reset and GOAWAY errors" {
  let reset = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_RST_STREAM, 0, 1, b"\x00\x00\x00\x08"),
  ])
  let stream = h2_frame_mock_stream(reset, 0)
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  match h2_request(stream, request) {
    Ok(_) => fail("HTTP/2 RST_STREAM was ignored")
    Err(err) => assert_eq(err, ProtocolError("HTTP/2 stream reset by server"))
  }

  let goaway = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_GOAWAY, 0, 0, b"\x00\x00\x00\x00\x00\x00\x00\x00"),
  ])
  let stream = h2_frame_mock_stream(goaway, 0)
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  match h2_request(stream, request) {
    Ok(_) => fail("HTTP/2 GOAWAY was ignored")
    Err(err) => assert_eq(err, ProtocolError("HTTP/2 connection closed by GOAWAY"))
  }
}

test "http2 fragments oversized request header blocks" {
  let response_headers = hpack_encode([(":status", "200")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM, 1, response_headers),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let large_value = "a".repeat(20000)
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
    .with_header("X-Large", large_value)
  let response = h2_request(stream, request).unwrap()
  assert_eq(response.status, 200)

  let frames = h2_test_client_frames(stream)
  let block = Buffer(size_hint=21000)
  let mut saw_headers = false
  let mut continuations = 0
  for frame in frames {
    if frame.stream_id != 1 {
      continue
    }
    if frame.frame_type == H2_FRAME_HEADERS {
      saw_headers = true
      assert_eq(frame.flags & H2_FLAG_END_HEADERS, 0)
      assert_true((frame.flags & H2_FLAG_END_STREAM) != 0)
      block.write_bytes(frame.payload)
    } else if frame.frame_type == H2_FRAME_CONTINUATION {
      continuations = continuations + 1
      block.write_bytes(frame.payload)
    }
  }
  assert_true(saw_headers)
  assert_true(continuations > 0)
  let decoder = HpackDecoder::new()
  let fields = decoder.decode(block.to_bytes()).unwrap()
  assert_eq(h2_test_header_value(fields, "x-large").unwrap().length(), 20000)
}

test "http2 rejects forbidden trailer fields" {
  let response_headers = hpack_encode([(":status", "200")])
  let trailers = hpack_encode([("content-length", "5")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, response_headers),
    h2_test_frame(H2_FRAME_DATA, 0, 1, @utf8.encode("hello")),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM, 1, trailers),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  match h2_request(stream, request) {
    Ok(_) => fail("HTTP/2 framing trailer field was accepted")
    Err(err) => assert_eq(err, ProtocolError("Invalid HTTP/2 trailer field"))
  }
}

test "http2 enforces response content length" {  let headers = hpack_encode([(":status", "200"), ("content-length", "10")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, headers),
    h2_test_frame(H2_FRAME_DATA, H2_FLAG_END_STREAM, 1, @utf8.encode("hello")),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  match h2_request(stream, request) {
    Ok(_) => fail("HTTP/2 Content-Length mismatch was accepted")
    Err(err) =>
      assert_eq(err, ProtocolError("HTTP/2 response body does not match Content-Length"))
  }

  let matching = hpack_encode([(":status", "200"), ("content-length", "5")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, matching),
    h2_test_frame(H2_FRAME_DATA, H2_FLAG_END_STREAM, 1, @utf8.encode("hello")),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let response = h2_request(stream, request).unwrap()
  assert_eq(response.read_body().unwrap(), @utf8.encode("hello"))

  let trailers = hpack_encode([("x-trailer", "done")])
  let truncated_input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, headers),
    h2_test_frame(H2_FRAME_DATA, 0, 1, @utf8.encode("hello")),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM, 1, trailers),
  ])
  let truncated_stream = h2_frame_mock_stream(truncated_input, 0)
  match h2_request(truncated_stream, request) {
    Ok(_) => fail("truncated HTTP/2 body ending in trailers was accepted")
    Err(err) =>
      assert_eq(err, ProtocolError("HTTP/2 response body does not match Content-Length"))
  }
}

test "http2 rejects bodies on HEAD and bodyless responses" {
  let head_headers = hpack_encode([(":status", "200"), ("content-length", "100")])
  let head_input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, head_headers),
    h2_test_frame(H2_FRAME_DATA, H2_FLAG_END_STREAM, 1, @utf8.encode("bogus")),
  ])
  let head_stream = h2_frame_mock_stream(head_input, 0)
  let head_request = Request::new(HEAD, Url::parse("https://example.com/").unwrap())
  match h2_request(head_stream, head_request) {
    Ok(_) => fail("HTTP/2 HEAD response body was accepted")
    Err(err) => assert_eq(err, ProtocolError("HTTP/2 response must not include a body"))
  }

  let empty_head_input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM, 1, head_headers),
  ])
  let empty_head_stream = h2_frame_mock_stream(empty_head_input, 0)
  let empty_head_request = Request::new(HEAD, Url::parse("https://example.com/").unwrap())
  let response = h2_request(empty_head_stream, empty_head_request).unwrap()
  assert_eq(response.read_body().unwrap(), b"")

  let no_content = hpack_encode([(":status", "204")])
  let no_content_input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, no_content),
    h2_test_frame(H2_FRAME_DATA, H2_FLAG_END_STREAM, 1, @utf8.encode("bogus")),
  ])
  let no_content_stream = h2_frame_mock_stream(no_content_input, 0)
  let get_request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  match h2_request(no_content_stream, get_request) {
    Ok(_) => fail("HTTP/2 204 response body was accepted")
    Err(err) => assert_eq(err, ProtocolError("HTTP/2 response must not include a body"))
  }
}




test "http2 request content length accepts HTTP whitespace and leading zeroes" {
  let url = Url::parse("https://example.com/upload").unwrap()
  for declared in [" 5 ", "05", "005"] {
    let request = Request::new(POST, url)
      .with_header("Content-Length", declared)
      .with_body(@utf8.encode("hello"))
    let headers = h2_request_headers(request).unwrap()
    assert_eq(h2_test_header_value(headers, "content-length"), Some("5"))
  }
  let request = Request::new(POST, url)
    .with_header("Content-Length", "6")
    .with_body(@utf8.encode("hello"))
  assert_eq(h2_request_headers(request), Err(InvalidHeader("Content-Length")))
}

struct H2FlushGatedStream {
  inner : H2FrameMockStream
  mut flushed : Bool
}

fn h2_flush_gated_stream(input : Bytes) -> H2FlushGatedStream {
  H2FlushGatedStream::{ inner: h2_frame_mock_stream(input, 0), flushed: false }
}

pub impl Stream for H2FlushGatedStream with fn read(
  self : H2FlushGatedStream,
  buf : Buffer,
) -> Result[Int, NetError] {
  if !self.flushed {
    return Err(NetError::ReadError("read before flush"))
  }
  self.inner.read(buf)
}

pub impl Stream for H2FlushGatedStream with fn write(
  self : H2FlushGatedStream,
  buf : Buffer,
) -> Result[Int, NetError] {
  self.inner.write(buf)
}

pub impl Stream for H2FlushGatedStream with fn flush(
  self : H2FlushGatedStream,
) -> Result[Unit, NetError] {
  self.flushed = true
  self.inner.flush()
}

pub impl Stream for H2FlushGatedStream with fn close(
  self : H2FlushGatedStream,
) -> Result[Unit, NetError] {
  self.inner.close()
}

pub impl Stream for H2FlushGatedStream with fn set_timeout(
  self : H2FlushGatedStream,
  timeout_ms : Int,
) -> Result[Unit, NetError] {
  self.inner.set_timeout(timeout_ms)
}

pub impl Stream for H2FlushGatedStream with fn peer_addr(
  self : H2FlushGatedStream,
) -> Result[String, NetError] {
  self.inner.peer_addr()
}

pub impl Stream for H2FlushGatedStream with fn local_addr(
  self : H2FlushGatedStream,
) -> Result[String, NetError] {
  self.inner.local_addr()
}

test "http2 flushes the request before waiting for a response" {
  let response_headers = hpack_encode([(":status", "200")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM, 1, response_headers),
  ])
  let stream = h2_flush_gated_stream(input)
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  let response = h2_request(stream, request).unwrap()
  assert_eq(response.status, 200)
  assert_true(stream.flushed)
}

test "http2 rejects frames on unknown streams" {
  let response_headers = hpack_encode([(":status", "200")])
  let data_input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_DATA, H2_FLAG_END_STREAM, 3, @utf8.encode("pushed")),
  ])
  let data_stream = h2_frame_mock_stream(data_input, 0)
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  match h2_request(data_stream, request) {
    Ok(_) => fail("HTTP/2 DATA on an unknown stream was accepted")
    Err(err) => assert_eq(err, ProtocolError("HTTP/2 DATA on unknown stream"))
  }

  let headers_input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 3, response_headers),
  ])
  let headers_stream = h2_frame_mock_stream(headers_input, 0)
  match h2_request(headers_stream, request) {
    Ok(_) => fail("HTTP/2 HEADERS on an unknown stream was accepted")
    Err(err) => assert_eq(err, ProtocolError("HTTP/2 HEADERS on unknown stream"))
  }
}

test "http2 rejects leading and trailing whitespace in field values" {
  for value in [" leading", "trailing ", "\ttabbed", "tabbed\t"] {
    let response_headers = hpack_encode([(":status", "200"), ("x-test", value)])
    let input = h2_test_concat([
      h2_test_settings(),
      h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM, 1, response_headers),
    ])
    let stream = h2_frame_mock_stream(input, 0)
    let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
    match h2_request(stream, request) {
      Ok(_) => fail("HTTP/2 field value with surrounding whitespace was accepted")
      Err(err) => assert_eq(err, ProtocolError("Invalid HTTP/2 response header"))
    }
  }

  let response_headers = hpack_encode([(":status", "200"), ("x-test", "inner space")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM, 1, response_headers),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  let response = h2_request(stream, request).unwrap()
  assert_eq(response.headers.get("x-test"), Some("inner space"))
}

test "http2 strips headers nominated by Connection" {
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
    .set_header("Connection", "X-Hop, x-hop, X-Custom")
    .set_header("X-Hop", "drop me")
    .set_header("X-Custom", "drop me too")
    .set_header("X-Keep", "keep me")
  let fields = h2_request_headers(request).unwrap()
  assert_eq(h2_test_header_value(fields, "connection"), None)
  assert_eq(h2_test_header_value(fields, "x-hop"), None)
  assert_eq(h2_test_header_value(fields, "x-custom"), None)
  assert_eq(h2_test_header_value(fields, "x-keep"), Some("keep me"))
}

test "http2 accepts ENABLE_PUSH=0 and rejects enabling server push" {
  let disabled = h2_settings_payload([(H2_SETTINGS_ENABLE_PUSH, 0)])
  h2_apply_settings(disabled, H2FlowState::new()).unwrap()

  let payload = h2_settings_payload([(H2_SETTINGS_ENABLE_PUSH, 1)])
  match h2_apply_settings(payload, H2FlowState::new()) {
    Ok(_) => fail("server SETTINGS_ENABLE_PUSH=1 was accepted")
    Err(err) => assert_eq(err, ProtocolError("HTTP/2 server sent ENABLE_PUSH"))
  }

  let invalid = h2_settings_payload([(H2_SETTINGS_ENABLE_PUSH, 2)])
  match h2_apply_settings(invalid, H2FlowState::new()) {
    Ok(_) => fail("invalid SETTINGS_ENABLE_PUSH value was accepted")
    Err(err) => assert_eq(err, ProtocolError("Invalid HTTP/2 ENABLE_PUSH"))
  }

  let input = h2_test_concat([
    h2_test_frame(H2_FRAME_SETTINGS, 0, 0, payload),
    h2_test_frame(H2_FRAME_SETTINGS, H2_FLAG_ACK, 0, b""),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  match h2_request(stream, request) {
    Ok(_) => fail("HTTP/2 connection with server ENABLE_PUSH was accepted")
    Err(err) => assert_eq(err, ProtocolError("HTTP/2 server sent ENABLE_PUSH"))
  }
}

test "http2 client connection reuses one stream for sequential requests" {
  let first = hpack_encode([(":status", "200"), ("x-request", "first")])
  let second = hpack_encode([(":status", "201"), ("x-request", "second")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM, 1, first),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM, 3, second),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let request = Request::new(GET, Url::parse("https://example.com/one").unwrap())
  let first_response = connection.request(request).unwrap()
  assert_eq(first_response.status, 200)
  assert_eq(first_response.headers.get("x-request"), Some("first"))
  let second_response = connection.request(request).unwrap()
  assert_eq(second_response.status, 201)
  assert_eq(second_response.headers.get("x-request"), Some("second"))
  assert_true(connection.is_open())

  let frames = h2_test_client_frames(stream)
  let mut settings_count = 0
  let header_streams : Array[Int] = []
  for frame in frames {
    if frame.frame_type == H2_FRAME_SETTINGS && (frame.flags & H2_FLAG_ACK) == 0 {
      settings_count = settings_count + 1
    }
    if frame.frame_type == H2_FRAME_HEADERS {
      header_streams.push(frame.stream_id)
    }
  }
  assert_eq(settings_count, 1)
  assert_eq(header_streams, [1, 3])
}

test "http2 completes an accepted stream after a graceful GOAWAY" {
  let response_headers = hpack_encode([(":status", "200"), ("x-graceful", "yes")])
  let goaway = h2_test_frame(
    H2_FRAME_GOAWAY,
    0,
    0,
    b"\x00\x00\x00\x01\x00\x00\x00\x00",
  )
  // The response head was already in flight when the GOAWAY arrived, so the
  // accepted stream still completes even though no new stream may be opened.
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, response_headers),
    goaway,
    h2_test_frame(H2_FRAME_DATA, H2_FLAG_END_STREAM, 1, b"ok"),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  let response = connection.request(request).unwrap()
  assert_eq(response.status, 200)
  assert_eq(response.headers.get("x-graceful"), Some("yes"))
  assert_eq(response.text().unwrap(), "ok")
  // The server will not accept another stream, even though this response was
  // delivered successfully.
  assert_false(connection.is_open())
  let _ = connection.close()
  assert_false(stream.is_open)
}

test "http2 GOAWAY last stream ids must not increase" {
  let response_headers = hpack_encode([(":status", "200")])
  let input = h2_test_concat([
    h2_test_settings(),
    // Keep a response head ahead of the GOAWAYs so the request opens its
    // stream first and both GOAWAY frames are processed in order.
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, response_headers),
    h2_test_frame(H2_FRAME_GOAWAY, 0, 0, b"\x00\x00\x00\x01\x00\x00\x00\x00"),
    h2_test_frame(H2_FRAME_GOAWAY, 0, 0, b"\x00\x00\x00\x03\x00\x00\x00\x00"),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  match connection.request(request) {
    Ok(_) => fail("increasing HTTP/2 GOAWAY stream id was accepted")
    Err(err) => assert_eq(err, ProtocolError("HTTP/2 GOAWAY stream id increased"))
  }
  assert_false(connection.is_open())
}

test "http2 validates Content-Length on bodyless responses" {
  let head_headers = hpack_encode([(":status", "200"), ("content-length", "invalid")])
  let head_input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM, 1, head_headers),
  ])
  let head_request = Request::new(HEAD, Url::parse("https://example.com/").unwrap())
  match h2_request(h2_frame_mock_stream(head_input, 0), head_request) {
    Ok(_) => fail("invalid HTTP/2 HEAD Content-Length was accepted")
    Err(err) => assert_eq(err, ProtocolError("Invalid HTTP/2 Content-Length"))
  }

  let no_content_headers = hpack_encode([(":status", "204"), ("content-length", "0, 1")])
  let no_content_input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM, 1, no_content_headers),
  ])
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  match h2_request(h2_frame_mock_stream(no_content_input, 0), request) {
    Ok(_) => fail("conflicting HTTP/2 204 Content-Length was accepted")
    Err(err) => assert_eq(err, ProtocolError("Invalid HTTP/2 Content-Length"))
  }
}

test "http2 rejects ambiguous path and query delimiters" {
  let url = Url::parse("https://example.com/").unwrap()
  for path in ["/a?b", "/a#b"] {
    let request = Request::new(GET, url.with_path(path))
    assert_eq(h2_request_headers(request), Err(InvalidUrl("Invalid request target")))
  }
  let request = Request::new(GET, url.with_query("a#b"))
  assert_eq(h2_request_headers(request), Err(InvalidUrl("Invalid request target")))
}

test "http2 resets the request stream after an early response" {
  let response_headers = hpack_encode([(":status", "413"), ("content-length", "0")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM, 1, response_headers),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let request = Request::new(POST, Url::parse("https://example.com/upload").unwrap())
    .with_body(Bytes::make(70000, b'x'))
  let response = h2_request(stream, request).unwrap()
  assert_eq(response.status, 413)

  let frames = h2_test_client_frames(stream)
  let mut reset : H2Frame? = None
  for frame in frames {
    if frame.frame_type == H2_FRAME_RST_STREAM && frame.stream_id == 1 {
      reset = Some(frame)
    }
  }
  match reset {
    Some(frame) => assert_eq(frame.payload, b"\x00\x00\x00\x08")
    None => fail("unfinished HTTP/2 request stream was not reset")
  }
}

test "http2 ignores late DATA on an already closed stream" {
  let first_headers = hpack_encode([(":status", "413"), ("content-length", "0")])
  let second_headers = hpack_encode([(":status", "200"), ("x-request", "second")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(
      H2_FRAME_HEADERS,
      H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM,
      1,
      first_headers,
    ),
    h2_test_frame(H2_FRAME_DATA, H2_FLAG_END_STREAM, 1, b"late"),
    h2_test_frame(
      H2_FRAME_HEADERS,
      H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM,
      3,
      second_headers,
    ),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let upload = Request::new(POST, Url::parse("https://example.com/upload").unwrap())
    .with_body(Bytes::make(70000, b'x'))
  assert_eq(connection.request(upload).unwrap().status, 413)
  let second = connection.request(
    Request::new(GET, Url::parse("https://example.com/two").unwrap()),
  ).unwrap()
  assert_eq(second.status, 200)
  assert_eq(second.headers.get("x-request"), Some("second"))
  assert_true(connection.is_open())
}

test "http2 closes a connection after a failed exchange" {
  let reset = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_RST_STREAM, 0, 1, b"\x00\x00\x00\x08"),
  ])
  let stream = h2_frame_mock_stream(reset, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  match connection.request(request) {
    Ok(_) => fail("HTTP/2 reset exchange was accepted")
    Err(err) => assert_eq(err, ProtocolError("HTTP/2 stream reset by server"))
  }
  assert_false(connection.is_open())
  match connection.request(request) {
    Ok(_) => fail("failed HTTP/2 connection was reused")
    Err(err) => assert_eq(err, ConnectionClosed)
  }
}

test "http2 surfaces a nonzero GOAWAY error code" {
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_GOAWAY, 0, 0, b"\x00\x00\x00\x01\x00\x00\x00\x01"),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  match connection.request(request) {
    Ok(_) => fail("nonzero HTTP/2 GOAWAY error code was ignored")
    Err(err) => assert_eq(
      err,
      ProtocolError(
        "HTTP/2 connection closed by GOAWAY before opening a stream (error 1)",
      ),
    )
  }
  assert_false(connection.is_open())
}

test "http2 consumes a GOAWAY buffered after the response" {
  let response_headers = hpack_encode([(":status", "200")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM, 1, response_headers),
    h2_test_frame(H2_FRAME_GOAWAY, 0, 0, b"\x00\x00\x00\x01\x00\x00\x00\x00"),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  let response = connection.request(request).unwrap()
  assert_eq(response.status, 200)
  assert_false(connection.is_open())
}

test "http2 acknowledges a PING buffered after the response" {
  let response_headers = hpack_encode([(":status", "200")])
  let ping = b"\x01\x02\x03\x04\x05\x06\x07\x08"
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM, 1, response_headers),
    h2_test_frame(H2_FRAME_PING, 0, 0, ping),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  let _ = connection.request(request).unwrap()
  assert_true(connection.is_open())

  let frames = h2_test_client_frames(stream)
  let mut acknowledged = false
  for frame in frames {
    if frame.frame_type == H2_FRAME_PING && (frame.flags & H2_FLAG_ACK) != 0 {
      assert_eq(frame.payload, ping)
      acknowledged = true
    }
  }
  assert_true(acknowledged)
}

test "http2 filters synthesized headers nominated by Connection" {
  let request = Request::new(POST, Url::parse("https://example.com/").unwrap())
    .with_header("Connection", "User-Agent, Content-Length")
    .with_body(@utf8.encode("hello"))
  let fields = h2_request_headers(request).unwrap()
  assert_eq(h2_test_header_value(fields, "user-agent"), None)
  assert_eq(h2_test_header_value(fields, "content-length"), None)
}

test "http2 rejects surrounding whitespace in outgoing field values" {
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
    .with_header("X-Test", " value ")
  assert_eq(h2_request_headers(request), Err(InvalidHeader("X-Test")))
}

test "http2 accepts a Host field in a response" {
  let response_headers = hpack_encode([(":status", "200"), ("host", "backend.example")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM, 1, response_headers),
  ])
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  let response = h2_request(h2_frame_mock_stream(input, 0), request).unwrap()
  assert_eq(response.headers.get("host"), Some("backend.example"))
}

test "http2 rejects 101 Switching Protocols" {
  let response_headers = hpack_encode([(":status", "101")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, response_headers),
  ])
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  match h2_request(h2_frame_mock_stream(input, 0), request) {
    Ok(_) => fail("HTTP/2 101 response was accepted")
    Err(err) => assert_eq(err, ProtocolError("HTTP/2 does not allow 101 Switching Protocols"))
  }
}

test "http2 reports REFUSED_STREAM distinctly" {
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_RST_STREAM, 0, 1, b"\x00\x00\x00\x07"),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  match connection.request(request) {
    Ok(_) => fail("refused HTTP/2 stream was accepted")
    Err(err) => assert_eq(err, ProtocolError("HTTP/2 stream refused"))
  }
  assert_false(connection.is_open())
}

test "http2 honors a zero max concurrent streams setting before opening a stream" {
  let input = h2_test_concat([
    h2_test_frame(
      H2_FRAME_SETTINGS,
      0,
      0,
      h2_settings_payload([(H2_SETTINGS_MAX_CONCURRENT_STREAMS, 0)]),
    ),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  match h2_request(stream, request) {
    Ok(_) => fail("HTTP/2 stream was opened with zero max concurrent streams")
    Err(err) => assert_eq(err, ProtocolError("HTTP/2 max concurrent streams is zero"))
  }
  let frames = h2_test_client_frames(stream)
  for frame in frames {
    assert_true(frame.frame_type != H2_FRAME_HEADERS)
  }
}

test "http2 honors a small max header list setting" {
  let input = h2_test_concat([
    h2_test_frame(
      H2_FRAME_SETTINGS,
      0,
      0,
      h2_settings_payload([(H2_SETTINGS_MAX_HEADER_LIST_SIZE, 32)]),
    ),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  match h2_request(stream, request) {
    Ok(_) => fail("oversized HTTP/2 request header list was sent")
    Err(err) => assert_eq(err, ProtocolError("HTTP/2 request header list too large"))
  }
  let frames = h2_test_client_frames(stream)
  for frame in frames {
    assert_true(frame.frame_type != H2_FRAME_HEADERS)
  }
}

test "http2 applies buffered SETTINGS before sending a request body" {
  let response_headers = hpack_encode([(":status", "200")])
  let input = h2_test_concat([
    h2_test_frame(
      H2_FRAME_SETTINGS,
      0,
      0,
      h2_settings_payload([(H2_SETTINGS_INITIAL_WINDOW_SIZE, 0)]),
    ),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM, 1, response_headers),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let request = Request::new(POST, Url::parse("https://example.com/").unwrap())
    .with_body(@utf8.encode("hello"))
  let response = h2_request(stream, request).unwrap()
  assert_eq(response.status, 200)
  let frames = h2_test_client_frames(stream)
  for frame in frames {
    assert_true(frame.frame_type != H2_FRAME_DATA)
  }
}

test "http2 accepts ordinary fields in trailers" {
  let response_headers = hpack_encode([(":status", "200")])
  let trailers = hpack_encode([("content-type", "text/plain"), ("cache-control", "no-store")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, response_headers),
    h2_test_frame(H2_FRAME_DATA, 0, 1, @utf8.encode("hello")),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM, 1, trailers),
  ])
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  let response = h2_request(h2_frame_mock_stream(input, 0), request).unwrap()
  assert_eq(response.read_body().unwrap(), @utf8.encode("hello"))
  assert_eq(response.trailers().get("content-type"), Some("text/plain"))
  assert_eq(response.trailers().get("cache-control"), Some("no-store"))
}

test "http2 accepts an empty trailer block that ends the stream" {
  let response_headers = hpack_encode([(":status", "200"), ("content-length", "5")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, response_headers),
    h2_test_frame(H2_FRAME_DATA, 0, 1, @utf8.encode("hello")),
    h2_test_frame(
      H2_FRAME_HEADERS,
      H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM,
      1,
      b"",
    ),
  ])
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  let response = h2_request(h2_frame_mock_stream(input, 0), request).unwrap()
  assert_eq(response.read_body().unwrap(), @utf8.encode("hello"))
  assert_eq(response.trailers().length(), 0)
}

test "http2 rejects an empty trailer block that does not end the stream" {
  let response_headers = hpack_encode([(":status", "200")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, response_headers),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, b""),
  ])
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  match h2_request(h2_frame_mock_stream(input, 0), request) {
    Ok(_) => fail("HTTP/2 empty trailers without END_STREAM were accepted")
    Err(err) =>
      assert_eq(err, ProtocolError("HTTP/2 trailers did not end the stream"))
  }
}

test "http2 rejects a SETTINGS_ENABLE_PUSH value with the high bit set" {
  let flow = H2FlowState::new()
  let invalid = h2_settings_payload([(H2_SETTINGS_ENABLE_PUSH, -1)])
  match h2_apply_settings(invalid, flow) {
    Err(err) => assert_eq(err, ProtocolError("Invalid HTTP/2 ENABLE_PUSH"))
    Ok(_) => fail("invalid HTTP/2 ENABLE_PUSH was accepted")
  }
}

test "http2 honors a buffered GOAWAY before writing request headers" {
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_GOAWAY, 0, 0, b"\x00\x00\x00\x00\x00\x00\x00\x00"),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  match connection.request(request) {
    Ok(_) => fail("GOAWAY before a request was ignored")
    Err(err) => assert_eq(err, ProtocolError("HTTP/2 connection closed by GOAWAY"))
  }
  let frames = h2_test_client_frames(stream)
  for frame in frames {
    assert_true(frame.frame_type != H2_FRAME_HEADERS)
  }
  assert_false(connection.is_open())
}

test "http2 does not open a stream after a buffered GOAWAY with a later id" {
  // A GOAWAY still forbids new streams when its last-stream-id covers the
  // would-be stream (RFC 9113 §6.8); the id only describes what was accepted
  // before the GOAWAY was sent.
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_GOAWAY, 0, 0, b"\x7f\xff\xff\xff\x00\x00\x00\x00"),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  match connection.request(request) {
    Ok(_) => fail("a stream was opened after a buffered GOAWAY")
    Err(err) => assert_eq(err, ProtocolError("HTTP/2 connection closed by GOAWAY"))
  }
  for frame in h2_test_client_frames(stream) {
    assert_true(frame.frame_type != H2_FRAME_HEADERS)
  }
  assert_false(connection.is_open())
}

test "http2 processes SETTINGS buffered behind a WINDOW_UPDATE" {
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_WINDOW_UPDATE, 0, 0, b"\x00\x00\x00\x01"),
    h2_test_frame(
      H2_FRAME_SETTINGS,
      0,
      0,
      h2_settings_payload([(H2_SETTINGS_ENABLE_PUSH, -1)]),
    ),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  match connection.request(request) {
    Ok(_) => fail("invalid SETTINGS behind WINDOW_UPDATE was ignored")
    Err(err) => assert_eq(err, ProtocolError("Invalid HTTP/2 ENABLE_PUSH"))
  }
  let frames = h2_test_client_frames(stream)
  for frame in frames {
    assert_true(frame.frame_type != H2_FRAME_HEADERS)
  }
}

test "http2 rejects frames on an idle stream" {
  let response_headers = hpack_encode([(":status", "200")])
  for frame in [
    h2_test_frame(H2_FRAME_WINDOW_UPDATE, 0, 3, b"\x00\x00\x00\x01"),
    h2_test_frame(H2_FRAME_RST_STREAM, 0, 3, b"\x00\x00\x00\x00"),
  ] {
    let input = h2_test_concat([
      h2_test_settings(),
      frame,
      h2_test_frame(
        H2_FRAME_HEADERS,
        H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM,
        1,
        response_headers,
      ),
    ])
    let stream = h2_frame_mock_stream(input, 0)
    let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
    match h2_request(stream, request) {
      Ok(_) => fail("frame on an idle HTTP/2 stream was ignored")
      Err(_) => ()
    }
  }
}

test "http2 rejects trailers on a bodyless response" {
  let response_headers = hpack_encode([(":status", "204")])
  let trailers = hpack_encode([("x-trailer", "done")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, response_headers),
    h2_test_frame(
      H2_FRAME_HEADERS,
      H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM,
      1,
      trailers,
    ),
  ])
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  match h2_request(h2_frame_mock_stream(input, 0), request) {
    Ok(_) => fail("HTTP/2 trailers on a 204 response were accepted")
    Err(err) =>
      assert_eq(err, ProtocolError("HTTP/2 response must not include trailers"))
  }
}

test "http2 closes a session with an invalid buffered frame after the response" {
  let response_headers = hpack_encode([(":status", "200")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(
      H2_FRAME_HEADERS,
      H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM,
      1,
      response_headers,
    ),
    h2_test_frame(H2_FRAME_PUSH_PROMISE, 0, 3, b"\x00\x00\x00\x01"),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  let response = connection.request(request).unwrap()
  assert_eq(response.status, 200)
  assert_false(connection.is_open())
}

test "http2 ignores WINDOW_UPDATE for a stream that already ended" {
  let settings = h2_test_frame(
    H2_FRAME_SETTINGS,
    0,
    0,
    h2_settings_payload([(H2_SETTINGS_INITIAL_WINDOW_SIZE, H2_MAX_WINDOW_SIZE)]),
  )
  let response_headers = hpack_encode([(":status", "200")])
  let input = h2_test_concat([
    settings,
    h2_test_frame(
      H2_FRAME_HEADERS,
      H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM,
      1,
      response_headers,
    ),
    h2_test_frame(H2_FRAME_WINDOW_UPDATE, 0, 1, b"\x00\x00\x00\x01"),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  let response = connection.request(request).unwrap()
  assert_eq(response.status, 200)
  assert_true(connection.is_open())
}

test "http2 applies the last duplicate setting and ignores unknown ones" {
  let flow = H2FlowState::new()
  let known = h2_settings_payload([
    (H2_SETTINGS_MAX_FRAME_SIZE, H2_MAX_FRAME_SIZE),
    (H2_SETTINGS_MAX_FRAME_SIZE, H2_MAX_FRAME_SIZE + 1),
    (0x99, 1),
    (0x99, 2),
  ])
  match h2_apply_settings(known, flow) {
    Ok(_) => ()
    Err(err) => fail("valid repeated HTTP/2 settings were rejected: " + @debug.to_string(err))
  }
  // The second occurrence is the value that remains in effect.
  assert_eq(flow.peer_max_frame_size, H2_MAX_FRAME_SIZE + 1)

  let unknown_only = h2_settings_payload([(0x99, 1), (0x99, 2)])
  assert_true(h2_apply_settings(unknown_only, flow) is Ok(_))

  let response_headers = hpack_encode([(":status", "200")])
  let input = h2_test_concat([
    h2_test_frame(H2_FRAME_SETTINGS, 0, 0, known),
    h2_test_frame(
      H2_FRAME_HEADERS,
      H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM,
      1,
      response_headers,
    ),
  ])
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  let response = h2_request(h2_frame_mock_stream(input, 0), request).unwrap()
  assert_eq(response.status, 200)
}

test "http2 server preface must not begin with a settings acknowledgement" {
  let response_headers = hpack_encode([(":status", "200")])
  let input = h2_test_concat([
    h2_test_frame(H2_FRAME_SETTINGS, H2_FLAG_ACK, 0, b""),
    h2_test_settings(),
    h2_test_frame(
      H2_FRAME_HEADERS,
      H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM,
      1,
      response_headers,
    ),
  ])
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  match h2_request(h2_frame_mock_stream(input, 0), request) {
    Ok(_) => fail("HTTP/2 settings acknowledgement was accepted as the preface")
    Err(err) =>
      assert_eq(err, ProtocolError("HTTP/2 server did not start with SETTINGS"))
  }
}

test "http2 bounds informational responses" {
  let informational = hpack_encode([(":status", "103"), ("link", "</style.css>")])
  let frames : Array[Bytes] = [h2_test_settings()]
  for _ in 0..<9 {
    frames.push(
      h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, informational),
    )
  }
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  match h2_request(h2_frame_mock_stream(h2_test_concat(frames), 0), request) {
    Ok(_) => fail("unbounded HTTP/2 informational responses were accepted")
    Err(err) =>
      assert_eq(err, ProtocolError("Too many informational HTTP/2 responses"))
  }
}

test "http2 rejects non-SETTINGS frames in the server preface" {
  let response_headers = hpack_encode([(":status", "200")])
  let input = h2_test_concat([
    h2_test_frame(H2_FRAME_PING, 0, 0, b"\x01\x02\x03\x04\x05\x06\x07\x08"),
    h2_test_settings(),
    h2_test_frame(
      H2_FRAME_HEADERS,
      H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM,
      1,
      response_headers,
    ),
  ])
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  match h2_request(h2_frame_mock_stream(input, 0), request) {
    Ok(_) => fail("non-SETTINGS frame was accepted as the server preface")
    Err(err) =>
      assert_eq(err, ProtocolError("HTTP/2 server did not start with SETTINGS"))
  }
}

test "http2 rejects Content-Length on 204 and informational responses" {
  let informational = hpack_encode([(":status", "103"), ("content-length", "0")])
  let no_content = hpack_encode([(":status", "204"), ("content-length", "0")])
  for input in [
    h2_test_concat([
      h2_test_settings(),
      h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, informational),
      h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM, 1, hpack_encode([(":status", "200")])),
    ]),
    h2_test_concat([
      h2_test_settings(),
      h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM, 1, no_content),
    ]),
  ] {
    let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
    match h2_request(h2_frame_mock_stream(input, 0), request) {
      Ok(_) => fail("HTTP/2 response with forbidden Content-Length was accepted")
      Err(_) => ()
    }
  }
}

test "http2 only allows a zero Content-Length on 205" {
  let invalid = hpack_encode([(":status", "205"), ("content-length", "1")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM, 1, invalid),
  ])
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  match h2_request(h2_frame_mock_stream(input, 0), request) {
    Ok(_) => fail("HTTP/2 205 response with a body length was accepted")
    Err(err) =>
      assert_eq(
        err,
        ProtocolError("HTTP/2 205 response must not have a non-zero Content-Length"),
      )
  }

  let valid = hpack_encode([(":status", "205"), ("content-length", "0")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM, 1, valid),
  ])
  let response = h2_request(h2_frame_mock_stream(input, 0), request).unwrap()
  assert_eq(response.status, 205)
  assert_eq(response.read_body().unwrap(), b"")
}

test "http2 ignores unknown extension frames buffered after a response" {
  let first = hpack_encode([(":status", "200")])
  let second = hpack_encode([(":status", "201"), ("x-request", "second")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(
      H2_FRAME_HEADERS,
      H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM,
      1,
      first,
    ),
    // Unknown frame types must be ignored and discarded (RFC 9113 §4.1).
    h2_test_frame(250, 0, 0, b"extension"),
    h2_test_frame(
      H2_FRAME_HEADERS,
      H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM,
      3,
      second,
    ),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let url = Url::parse("https://example.com/").unwrap()
  assert_eq(connection.request(Request::new(GET, url)).unwrap().status, 200)
  assert_true(connection.is_open())
  let response = connection.request(Request::new(GET, url)).unwrap()
  assert_eq(response.status, 201)
  assert_eq(response.headers.get("x-request"), Some("second"))
  assert_true(connection.is_open())
}

test "http2 strips connection-nominated Content-Length without validating it" {
  let request = Request::new(POST, Url::parse("https://example.com/").unwrap())
    .with_body(b"hello")
    .with_header("Connection", "Content-Length")
    .with_header("Content-Length", "999")
  let headers = h2_request_headers(request).unwrap()
  assert_eq(h2_test_header_value(headers, "connection"), None)
  assert_eq(h2_test_header_value(headers, "content-length"), None)
  assert_eq(h2_test_header_value(headers, ":method"), Some("POST"))
}

test "http2 rejects TE in responses" {
  let response_headers = hpack_encode([(":status", "200"), ("te", "trailers")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(
      H2_FRAME_HEADERS,
      H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM,
      1,
      response_headers,
    ),
  ])
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  match h2_request(h2_frame_mock_stream(input, 0), request) {
    Ok(_) => fail("HTTP/2 response with TE was accepted")
    Err(err) =>
      assert_eq(err, ProtocolError("Connection-specific HTTP/2 response header"))
  }
}

///|
test "http2 rejects invalid padded DATA buffered after the response" {
  let response_headers = hpack_encode([(":status", "204")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(
      H2_FRAME_HEADERS,
      H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM,
      1,
      response_headers,
    ),
    // Pad Length 5 exceeds the two-byte payload.
    h2_test_frame(H2_FRAME_DATA, H2_FLAG_PADDED, 1, b"\x05\x00"),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  match connection.request(request) {
    Ok(_) => fail("invalid buffered DATA padding was accepted")
    Err(err) => assert_eq(err, ProtocolError("Invalid HTTP/2 DATA padding"))
  }
  assert_false(connection.is_open())
}

///|
test "http2 keeps the session after a self-dependent PRIORITY frame" {
  let response_headers = hpack_encode([(":status", "204")])
  let input = h2_test_concat([
    h2_test_settings(),
    // PRIORITY on idle stream 3 depending on itself is a stream-scoped
    // priority violation, not a connection failure.
    h2_test_frame(H2_FRAME_PRIORITY, 0, 3, b"\x00\x00\x00\x03\x10"),
    h2_test_frame(
      H2_FRAME_HEADERS,
      H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM,
      1,
      response_headers,
    ),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  let response = connection.request(request).unwrap()
  assert_eq(response.status, 204)
  assert_true(connection.is_open())
  let _ = connection.close()
}

///|
test "http2 resets only the stream after a zero WINDOW_UPDATE increment" {
  let first_headers = hpack_encode([(":status", "204")])
  let second_headers = hpack_encode([(":status", "200"), ("x-request", "second")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_WINDOW_UPDATE, 0, 1, b"\x00\x00\x00\x00"),
    h2_test_frame(
      H2_FRAME_HEADERS,
      H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM,
      1,
      first_headers,
    ),
    h2_test_frame(
      H2_FRAME_HEADERS,
      H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM,
      3,
      second_headers,
    ),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  match connection.request(request) {
    Ok(_) => fail("zero WINDOW_UPDATE increment was accepted")
    Err(err) =>
      assert_eq(
        err,
        ProtocolError("HTTP/2 stream WINDOW_UPDATE increment is zero"),
      )
  }
  assert_true(connection.is_open())
  let second = connection.request(request).unwrap()
  assert_eq(second.status, 200)
  assert_eq(second.headers.get("x-request"), Some("second"))
  assert_true(connection.is_open())
  let _ = connection.close()
}

///|
test "http2 ignores a self-dependent priority on response HEADERS" {
  let response_headers = hpack_encode([(":status", "204")])
  let payload = h2_test_concat([b"\x00\x00\x00\x01\x10", response_headers])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(
      H2_FRAME_HEADERS,
      H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM | H2_FLAG_PRIORITY,
      1,
      payload,
    ),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  let response = connection.request(request).unwrap()
  assert_eq(response.status, 204)
  assert_true(connection.is_open())
  let _ = connection.close()
}
