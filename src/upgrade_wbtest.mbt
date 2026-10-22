///|
test "Request::with_upgrade merges the Connection nomination" {
  let url = Url::parse("http://example.com/socket").unwrap()
  let plain = Request::new(GET, url).with_upgrade("websocket")
  assert_eq(plain.get_header("Upgrade"), Some("websocket"))
  assert_eq(plain.get_header("Connection"), Some("Upgrade"))

  let merged = Request::new(GET, url)
    .with_header("Connection", "keep-alive")
    .with_upgrade("h2c")
  assert_eq(merged.get_header("Upgrade"), Some("h2c"))
  assert_eq(merged.get_header("Connection"), Some("keep-alive, Upgrade"))

  let already = Request::new(GET, url)
    .with_header("Connection", "upgrade, close")
    .with_upgrade("websocket")
  assert_eq(already.get_header("Connection"), Some("upgrade, close"))
  assert_eq(already.get_header("Upgrade"), Some("websocket"))
}

///|
test "HTTP/1 upgrade exposes a writable tunnel after 101" {
  let stream = regression_mock_stream(
    "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n",
    0,
    0,
  )
  let codec = H1Codec::new(stream)
  codec.encode_request(
    Request::new(GET, Url::parse("http://example.com/socket").unwrap())
      .with_upgrade("websocket"),
  ).unwrap()
  let wire = @utf8.decode_lossy(stream.output.to_bytes()[:])
  assert_true(wire.contains("Connection: Upgrade\r\n"))
  assert_true(wire.contains("Upgrade: websocket\r\n"))

  let response = codec.decode_response().unwrap()
  assert_eq(response.status, 101)
  assert_eq(response.get_header("Upgrade"), Some("websocket"))
  let payload = Buffer(size_hint=6)
  payload.write_bytes(b"client")
  assert_eq(response.body.write(payload).unwrap(), 6)
  assert_true(
    @utf8.decode_lossy(stream.output.to_bytes()[:]).has_suffix("client"),
  )

  response.body.close().unwrap()
  assert_false(stream.is_open)
}

///|
test "HTTP/1 upgrade streams server bytes as body data" {
  let stream = regression_mock_stream(
    "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\nserver",
    0,
    0,
  )
  let codec = H1Codec::new(stream)
  codec.encode_request(
    Request::new(GET, Url::parse("http://example.com/socket").unwrap())
      .with_upgrade("websocket"),
  ).unwrap()
  let response = codec.decode_response().unwrap()
  assert_eq(response.status, 101)
  assert_eq(response.read_body().unwrap(), b"server")
  assert_false(stream.is_open)
}

///|
test "HTTP/1 upgrade rejects framing headers on 101" {
  let stream = regression_mock_stream(
    "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nContent-Length: 4\r\n\r\n",
    0,
    0,
  )
  let codec = H1Codec::new(stream)
  codec.encode_request(
    Request::new(GET, Url::parse("http://example.com/socket").unwrap())
      .with_upgrade("websocket"),
  ).unwrap()
  match codec.decode_response() {
    Ok(_) => fail("101 response with framing headers was accepted")
    Err(err) => assert_true(err is ProtocolError(_))
  }
}

///|
test "UnifiedClient keeps an HTTP/1 upgrade tunnel out of the pool" {
  let stream = regression_mock_stream(
    "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\nhello",
    0,
    0,
  )
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let client = UnifiedClient::{
    connector,
    options: ClientOptions::new().with_follow_redirects(false),
    redirect_count: 0,
  }
  let request = Request::new(
    GET,
    Url::parse("http://example.com/socket").unwrap(),
  ).with_upgrade("websocket")
  let response = client.request(request).unwrap()
  assert_eq(response.status, 101)
  assert_eq(client.connector.pool.val.active.length(), 1)
  assert_eq(response.read_body().unwrap(), b"hello")
  assert_eq(client.connector.pool.val.active.length(), 0)
  assert_false(stream.is_open)
  let _ = client.close_all()
}

///|
test "HTTP/2 extended CONNECT carries the upgraded protocol and target" {
  let url = Url::parse("https://example.com/socket?x=1").unwrap()
  let request = Request::new(GET, url).with_upgrade("websocket")
  let fields = h2_request_headers_with_protocol(
    request,
    Some("websocket"),
  ).unwrap()
  assert_eq(h2_test_header_value(fields, ":method"), Some("CONNECT"))
  assert_eq(h2_test_header_value(fields, ":scheme"), Some("https"))
  assert_eq(h2_test_header_value(fields, ":authority"), Some("example.com"))
  assert_eq(h2_test_header_value(fields, ":path"), Some("/socket?x=1"))
  assert_eq(h2_test_header_value(fields, ":protocol"), Some("websocket"))
  // Upgrade and Connection are connection-specific fields, not HTTP/2 fields.
  assert_eq(h2_test_header_value(fields, "upgrade"), None)
  assert_eq(h2_test_header_value(fields, "connection"), None)

  let rejected = Request::new(POST, url).with_upgrade("websocket")
  match h2_request_headers_with_protocol(rejected, Some("websocket")) {
    Ok(_) => fail("POST extended CONNECT was accepted")
    Err(err) =>
      assert_eq(
        err,
        ProtocolError("Extended CONNECT requires a GET or CONNECT request"),
      )
  }
}

///|
test "HTTP/2 rejects an invalid extended CONNECT setting" {
  for invalid in [2, -1] {
    let flow = H2FlowState::new()
    let payload = h2_settings_payload([
      (H2_SETTINGS_ENABLE_CONNECT_PROTOCOL, invalid),
    ])
    match h2_apply_settings(payload, flow) {
      Ok(_) => fail("invalid SETTINGS_ENABLE_CONNECT_PROTOCOL was accepted")
      Err(err) =>
        assert_eq(
          err,
          ProtocolError("Invalid HTTP/2 enable connect protocol"),
        )
    }
  }
}

///|
test "HTTP/2 upgrade requires the server to enable extended CONNECT" {
  let stream = h2_frame_mock_stream(h2_test_settings(), 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let request = Request::new(
    GET,
    Url::parse("https://example.com/socket").unwrap(),
  ).with_upgrade("websocket")
  match connection.request(request) {
    Ok(_) => fail("extended CONNECT without server support was accepted")
    Err(err) =>
      assert_eq(
        err,
        ProtocolError("HTTP/2 server did not enable extended CONNECT"),
      )
  }
  for frame in h2_test_client_frames(stream) {
    assert_true(frame.frame_type != H2_FRAME_HEADERS)
  }
}

///|
test "HTTP/2 extended CONNECT exposes a writable tunnel" {
  let settings = h2_test_frame(
    H2_FRAME_SETTINGS,
    0,
    0,
    h2_settings_payload([
      (H2_SETTINGS_INITIAL_WINDOW_SIZE, H2_DEFAULT_WINDOW_SIZE),
      (H2_SETTINGS_ENABLE_CONNECT_PROTOCOL, 1),
    ]),
  )
  let response_headers = hpack_encode([(":status", "200")])
  let input = h2_test_concat([
    settings,
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, response_headers),
    h2_test_frame(H2_FRAME_DATA, 0, 1, b"server"),
    h2_test_frame(H2_FRAME_DATA, H2_FLAG_END_STREAM, 1, b""),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let request = Request::new(
    GET,
    Url::parse("https://example.com/socket").unwrap(),
  ).with_upgrade("websocket")
  let response = connection.request(request).unwrap()
  assert_eq(response.status, 200)
  let payload = Buffer(size_hint=6)
  payload.write_bytes(b"client")
  assert_eq(response.body.write(payload).unwrap(), 6)
  assert_eq(response.read_body().unwrap(), b"server")
  assert_false(stream.is_open)

  let frames = h2_test_client_frames(stream)
  let mut header_frame : H2Frame? = None
  let mut data_frame : H2Frame? = None
  let mut setting_seen = false
  for frame in frames {
    if frame.frame_type == H2_FRAME_HEADERS && header_frame is None {
      header_frame = Some(frame)
    }
    if frame.frame_type == H2_FRAME_DATA {
      data_frame = Some(frame)
    }
    if frame.frame_type == H2_FRAME_SETTINGS && (frame.flags & H2_FLAG_ACK) == 0 {
      let mut offset = 0
      while offset + 6 <= frame.payload.length() {
        let identifier = (frame.payload[offset].to_int() << 8) |
          frame.payload[offset + 1].to_int()
        let value = (frame.payload[offset + 2].to_int() << 24) |
          (frame.payload[offset + 3].to_int() << 16) |
          (frame.payload[offset + 4].to_int() << 8) |
          frame.payload[offset + 5].to_int()
        if identifier == H2_SETTINGS_ENABLE_CONNECT_PROTOCOL && value == 1 {
          setting_seen = true
        }
        offset = offset + 6
      }
    }
  }
  assert_true(setting_seen)
  let header_frame = header_frame.unwrap()
  assert_eq(header_frame.flags & H2_FLAG_END_STREAM, 0)
  let fields = HpackDecoder::new().decode(header_frame.payload).unwrap()
  assert_eq(h2_test_header_value(fields, ":method"), Some("CONNECT"))
  assert_eq(h2_test_header_value(fields, ":protocol"), Some("websocket"))
  assert_eq(h2_test_header_value(fields, ":path"), Some("/socket"))
  let data_frame = data_frame.unwrap()
  assert_eq(data_frame.payload, b"client")
  assert_eq(data_frame.flags & H2_FLAG_END_STREAM, 0)
}

///|
test "UnifiedClient keeps an HTTP/2 upgrade lease until the tunnel closes" {
  let settings = h2_test_frame(
    H2_FRAME_SETTINGS,
    0,
    0,
    h2_settings_payload([
      (H2_SETTINGS_INITIAL_WINDOW_SIZE, H2_DEFAULT_WINDOW_SIZE),
      (H2_SETTINGS_ENABLE_CONNECT_PROTOCOL, 1),
    ]),
  )
  let response_headers = hpack_encode([(":status", "200")])
  let input = h2_test_concat([
    settings,
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, response_headers),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let provider = H2NegotiatingTlsProvider::{ protocol: Some("h2") }
  let client = UnifiedClient::with_transport(
    dialer,
    provider,
    ClientOptions::new().with_follow_redirects(false),
  )
  let request = Request::from_url(
    GET,
    "https://example.com/socket",
  ).unwrap().with_upgrade("websocket")
  let response = client.request(request).unwrap()
  assert_eq(response.status, 200)
  assert_eq(client.connector.pool.val.active.length(), 1)
  response.body.close().unwrap()
  assert_false(stream.is_open)
  assert_eq(client.connector.pool.val.active.length(), 0)
}

///|
test "HTTP/1 upgrade requires a matching confirmation from the server" {
  let url = Url::parse("http://example.com/socket").unwrap()
  for raw in [
    "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: h2c\r\n\r\n",
    "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\n\r\n",
    "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n",
  ] {
    let stream = regression_mock_stream(raw, 0, 0)
    let codec = H1Codec::new(stream)
    codec.encode_request(
      Request::new(GET, url).with_upgrade("websocket"),
    ).unwrap()
    match codec.decode_response() {
      Ok(_) => fail("unconfirmed HTTP/1 upgrade was accepted")
      Err(err) =>
        assert_eq(
          err,
          ProtocolError("HTTP/1.1 101 response does not confirm the requested upgrade"),
        )
    }
    assert_false(stream.is_open)
  }
}

///|
test "HTTP/1 upgrade protocols must be HTTP tokens" {
  let url = Url::parse("http://example.com/socket").unwrap()
  for protocol in ["bad protocol", ""] {
    let stream = regression_mock_stream("", 0, 0)
    let codec = H1Codec::new(stream)
    match codec.encode_request(Request::new(GET, url).with_upgrade(protocol)) {
      Ok(_) => fail("invalid Upgrade protocol was encoded")
      Err(err) => assert_eq(err, InvalidHeader("Upgrade"))
    }
    assert_eq(stream.output.to_bytes().length(), 0)
  }
}
