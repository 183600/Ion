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

