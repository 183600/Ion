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
