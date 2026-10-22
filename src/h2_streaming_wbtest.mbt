///|
test "http2 streaming body returns DATA as it arrives" {
  let headers = hpack_encode([(":status", "200"), ("content-length", "5")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, headers),
    h2_test_frame(H2_FRAME_DATA, 0, 1, b"he"),
    h2_test_frame(H2_FRAME_DATA, H2_FLAG_END_STREAM, 1, b"llo"),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let request = Request::new(GET, Url::parse("https://example.com/file").unwrap())
  let response = connection.request_streaming(request).unwrap()
  assert_eq(response.version, "HTTP/2")
  assert_eq(response.status, 200)
  let first = Buffer(size_hint=8)
  assert_eq(response.body_stream().read(first).unwrap(), 2)
  assert_eq(@utf8.decode_lossy(first.to_bytes()[:]), "he")
  let second = Buffer(size_hint=8)
  assert_eq(response.body_stream().read(second).unwrap(), 3)
  assert_eq(@utf8.decode_lossy(second.to_bytes()[:]), "llo")
  let eof = Buffer(size_hint=1)
  assert_eq(response.body_stream().read(eof).unwrap(), 0)
  assert_true(connection.is_open())
  assert_true(stream.is_open)
  let _ = connection.close()
}

///|
test "http2 streaming body exposes trailers after END_STREAM" {
  let headers = hpack_encode([(":status", "200"), ("content-length", "4")])
  let trailers = hpack_encode([("x-trailer", "done")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, headers),
    h2_test_frame(H2_FRAME_DATA, 0, 1, b"body"),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM, 1, trailers),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let request = Request::new(GET, Url::parse("https://example.com/trailers").unwrap())
  let response = connection.request_streaming(request).unwrap()
  assert_eq(response.text().unwrap(), "body")
  assert_eq(response.trailers().get("x-trailer"), Some("done"))
}

///|
test "http2 streaming body rejects a Content-Length mismatch" {
  let headers = hpack_encode([(":status", "200"), ("content-length", "5")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, headers),
    h2_test_frame(H2_FRAME_DATA, H2_FLAG_END_STREAM, 1, b"hi"),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let request = Request::new(GET, Url::parse("https://example.com/truncated").unwrap())
  let response = connection.request_streaming(request).unwrap()
  let body = Buffer(size_hint=8)
  match response.body_stream().read(body) {
    Ok(_) => fail("truncated HTTP/2 body was accepted")
    Err(_) => ()
  }
  assert_false(stream.is_open)
}

///|
test "closing a streaming HTTP/2 body resets an unfinished exchange" {
  let headers = hpack_encode([(":status", "200")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, headers),
    h2_test_frame(H2_FRAME_DATA, 0, 1, b"partial"),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let request = Request::new(GET, Url::parse("https://example.com/stream").unwrap())
  let response = connection.request_streaming(request).unwrap()
  let first = Buffer(size_hint=16)
  assert_eq(response.body_stream().read(first).unwrap(), 7)
  assert_true(stream.is_open)
  response.body_stream().close().unwrap()
  assert_false(stream.is_open)
  assert_false(connection.is_open())
}

///|
test "http2 streaming falls back to buffered bodies for uploads" {
  let headers = hpack_encode([(":status", "201"), ("content-length", "2")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, headers),
    h2_test_frame(H2_FRAME_DATA, H2_FLAG_END_STREAM, 1, b"ok"),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let request = Request::new(POST, Url::parse("https://example.com/upload").unwrap())
    .with_body(b"payload")
  let response = connection.request_streaming(request).unwrap()
  assert_eq(response.status, 201)
  assert_eq(response.text().unwrap(), "ok")
}

///|
test "UnifiedClient can opt into lazy HTTP/2 response bodies" {
  let headers = hpack_encode([(":status", "200")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, headers),
    h2_test_frame(H2_FRAME_DATA, 0, 1, b"partial"),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let provider = H2NegotiatingTlsProvider::{ protocol: Some("h2") }
  let client = UnifiedClient::with_transport(
    dialer,
    provider,
    ClientOptions::new()
      .with_http2_streaming(true)
      .with_follow_redirects(false),
  )
  let response = client.get("https://example.com/stream").unwrap()
  assert_eq(response.status, 200)
  assert_eq(client.active_connection_count(), 1)
  let body = Buffer(size_hint=16)
  assert_eq(response.body_stream().read(body).unwrap(), 7)
  assert_eq(@utf8.decode_lossy(body.to_bytes()[:]), "partial")
  response.body_stream().close().unwrap()
  assert_eq(client.active_connection_count(), 0)
  assert_eq(client.idle_connection_count(), 0)
  assert_false(stream.is_open)
}

///|
test "lazy HTTP/2 bodies return the session to the pool after END_STREAM" {
  let headers = hpack_encode([(":status", "200"), ("content-length", "2")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, headers),
    h2_test_frame(H2_FRAME_DATA, H2_FLAG_END_STREAM, 1, b"ok"),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let provider = H2NegotiatingTlsProvider::{ protocol: Some("h2") }
  let client = UnifiedClient::with_transport(
    dialer,
    provider,
    ClientOptions::new()
      .with_http2_streaming(true)
      .with_follow_redirects(false),
  )
  let response = client.get("https://example.com/done").unwrap()
  assert_eq(response.text().unwrap(), "ok")
  assert_eq(client.active_connection_count(), 0)
  assert_eq(client.idle_connection_count(), 1)
  let _ = client.close_all()
  assert_eq(client.connection_count(), 0)
}

///|
test "a streaming HTTP/2 body prevents overlapping exchanges" {
  let first = hpack_encode([(":status", "200"), ("content-length", "2")])
  let second = hpack_encode([(":status", "201")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, first),
    h2_test_frame(H2_FRAME_DATA, H2_FLAG_END_STREAM, 1, b"ok"),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM, 3, second),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let request = Request::new(GET, Url::parse("https://example.com/one").unwrap())
  let response = connection.request_streaming(request).unwrap()
  assert_false(connection.is_open())
  match connection.request_streaming(request) {
    Ok(_) => fail("overlapping HTTP/2 streaming request was accepted")
    Err(err) =>
      assert_eq(
        err,
        ProtocolError("HTTP/2 connection has an outstanding streaming body"),
      )
  }
  assert_eq(response.text().unwrap(), "ok")
  assert_true(connection.is_open())
  let next = connection.request_streaming(request).unwrap()
  assert_eq(next.status, 201)
  assert_eq(next.text().unwrap(), "")
}

///|
test "streaming HTTP/2 body does not reuse a session after GOAWAY" {
  let headers = hpack_encode([(":status", "200"), ("content-length", "2")])
  let goaway = h2_test_frame(
    H2_FRAME_GOAWAY,
    0,
    0,
    b"\x00\x00\x00\x01\x00\x00\x00\x00",
  )
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, headers),
    goaway,
    h2_test_frame(H2_FRAME_DATA, H2_FLAG_END_STREAM, 1, b"ok"),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let request = Request::new(GET, Url::parse("https://example.com/goaway").unwrap())
  let response = connection.request_streaming(request).unwrap()
  assert_eq(response.text().unwrap(), "ok")
  assert_false(connection.is_open())
  let _ = connection.close()
  assert_false(stream.is_open)
}

///|
test "h2_request_streaming provides a one-shot lazy exchange" {
  let headers = hpack_encode([(":status", "200"), ("content-length", "2")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, headers),
    h2_test_frame(H2_FRAME_DATA, H2_FLAG_END_STREAM, 1, b"ok"),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let request = Request::new(GET, Url::parse("https://example.com/one-shot").unwrap())
  let response = h2_request_streaming(stream, request).unwrap()
  assert_eq(response.status, 200)
  assert_eq(response.text().unwrap(), "ok")
  assert_false(stream.is_open)
}

///|
test "bodyless streaming responses release the session without being read" {
  let head_headers = hpack_encode([
    (":status", "200"),
    ("content-length", "9"),
  ])
  let next_headers = hpack_encode([(":status", "204")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(
      H2_FRAME_HEADERS,
      H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM,
      1,
      head_headers,
    ),
    h2_test_frame(
      H2_FRAME_HEADERS,
      H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM,
      3,
      next_headers,
    ),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let head = connection
    .request_streaming(
      Request::new(HEAD, Url::parse("https://example.com/head").unwrap()),
    )
    .unwrap()
  assert_eq(head.status, 200)
  // The empty HEAD body is complete even though the caller never read it, so
  // the session can immediately carry the next stream.
  let next = connection
    .request_streaming(
      Request::new(GET, Url::parse("https://example.com/next").unwrap()),
    )
    .unwrap()
  assert_eq(next.status, 204)
  assert_eq(next.text().unwrap(), "")
  assert_eq(head.text().unwrap(), "")
  assert_true(connection.is_open())
  let _ = connection.close()
}

///|
test "explicit body limits can raise the cap for a streaming response" {
  let headers = hpack_encode([(":status", "200")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, headers),
    h2_test_frame(H2_FRAME_DATA, H2_FLAG_END_STREAM, 1, b"abcdef"),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let request = Request::new(GET, Url::parse("https://example.com/limited").unwrap())
  let response = connection.request_streaming_with_limit(request, 4).unwrap()
  // The caller raises the limit before the DATA frame is consumed, matching
  // H1's explicit `read_body_with_limit` behavior.
  assert_eq(@utf8.decode_lossy(response.read_body_with_limit(8).unwrap()[:]), "abcdef")
  assert_true(connection.is_open())
  let _ = connection.close()
}

///|
test "UnifiedClient returns a streaming HEAD session to the pool unread" {
  let headers = hpack_encode([(":status", "200"), ("content-length", "9")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(
      H2_FRAME_HEADERS,
      H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM,
      1,
      headers,
    ),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let provider = H2NegotiatingTlsProvider::{ protocol: Some("h2") }
  let client = UnifiedClient::with_transport(
    dialer,
    provider,
    ClientOptions::new()
      .with_http2_streaming(true)
      .with_follow_redirects(false),
  )
  let response = client.head("https://example.com/head").unwrap()
  assert_eq(response.status, 200)
  assert_eq(response.text().unwrap(), "")
  assert_eq(client.active_connection_count(), 0)
  assert_eq(client.idle_connection_count(), 1)
  let _ = client.close_all()
  assert_eq(client.connection_count(), 0)
}

///|
test "h2_request_streaming_with_limit bounds and releases a one-shot exchange" {
  let headers = hpack_encode([(":status", "200")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, headers),
    h2_test_frame(H2_FRAME_DATA, H2_FLAG_END_STREAM, 1, b"abcdef"),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let request = Request::new(GET, Url::parse("https://example.com/one-shot-limit").unwrap())
  let response = h2_request_streaming_with_limit(stream, request, 8).unwrap()
  assert_eq(@utf8.decode_lossy(response.read_body_with_limit(8).unwrap()[:]), "abcdef")
  assert_false(stream.is_open)
}

///|
test "streaming body keeps the session after a stream-scoped window reset" {
  let first_headers = hpack_encode([(":status", "200")])
  let second_headers = hpack_encode([(":status", "201")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, first_headers),
    h2_test_frame(H2_FRAME_WINDOW_UPDATE, 0, 1, b"\x00\x00\x00\x00"),
    h2_test_frame(
      H2_FRAME_HEADERS,
      H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM,
      3,
      second_headers,
    ),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let request = Request::new(GET, Url::parse("https://example.com/first").unwrap())
  let response = connection.request_streaming(request).unwrap()
  let body = Buffer(size_hint=8)
  assert_true(response.body_stream().read(body) is Err(_))
  // A zero increment is a stream error; the connection remains usable.
  assert_true(connection.is_open())
  let next = connection.request_streaming(request).unwrap()
  assert_eq(next.status, 201)
  assert_eq(next.text().unwrap(), "")
  assert_true(connection.is_open())
  let _ = connection.close()
}

///|
test "streaming body drains buffered connection frames after END_STREAM" {
  let headers = hpack_encode([(":status", "200"), ("content-length", "2")])
  let ping = b"\x01\x02\x03\x04\x05\x06\x07\x08"
  let goaway = h2_test_frame(
    H2_FRAME_GOAWAY,
    0,
    0,
    b"\x00\x00\x00\x01\x00\x00\x00\x00",
  )
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, headers),
    h2_test_frame(H2_FRAME_DATA, H2_FLAG_END_STREAM, 1, b"ok"),
    h2_test_frame(H2_FRAME_PING, 0, 0, ping),
    goaway,
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let request = Request::new(GET, Url::parse("https://example.com/drain").unwrap())
  let response = connection.request_streaming(request).unwrap()
  assert_eq(response.text().unwrap(), "ok")
  let mut saw_ping_ack = false
  for frame in h2_test_client_frames(stream) {
    if frame.frame_type == H2_FRAME_PING && (frame.flags & H2_FLAG_ACK) != 0 &&
      frame.payload == ping {
      saw_ping_ack = true
    }
  }
  assert_true(saw_ping_ack)
  // The buffered GOAWAY must retire the session instead of pooling it.
  assert_false(connection.is_open())
  let _ = connection.close()
}

///|
test "live CONNECT tunnel rejects overlapping exchanges" {
  let headers = hpack_encode([(":status", "200")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, headers),
    h2_test_frame(H2_FRAME_DATA, H2_FLAG_END_STREAM, 1, b"tunnel"),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let tunnel = connection.request(
    Request::new(CONNECT, Url::parse("https://example.com:443/").unwrap()),
  ).unwrap()
  assert_eq(tunnel.status, 200)
  match connection.request(
    Request::new(GET, Url::parse("https://example.com/other").unwrap()),
  ) {
    Ok(_) => fail("overlapping request on a live HTTP/2 tunnel was accepted")
    Err(err) =>
      assert_eq(
        err,
        ProtocolError("HTTP/2 connection has an outstanding streaming body"),
      )
  }
  assert_eq(tunnel.read_body().unwrap(), b"tunnel")
  assert_false(connection.is_open())
}

///|
test "released HTTP/2 streaming bodies do not retimeout the pooled session" {
  let headers = hpack_encode([(":status", "200"), ("content-length", "2")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, headers),
    h2_test_frame(H2_FRAME_DATA, H2_FLAG_END_STREAM, 1, b"ok"),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let provider = H2NegotiatingTlsProvider::{ protocol: Some("h2") }
  let client = UnifiedClient::with_transport(
    dialer,
    provider,
    ClientOptions::new()
      .with_http2_streaming(true)
      .with_follow_redirects(false),
  )
  let response = client.get("https://example.com/stream").unwrap()
  assert_eq(response.text().unwrap(), "ok")
  assert_eq(client.idle_connection_count(), 1)
  // The body's lease has been returned to the pool. Looking up addresses or
  // changing the timeout through the finished body must not touch the idle
  // connection, which the next request may already be using.
  let before = stream.timeout_calls
  assert_true(response.body.set_timeout(1234) is Ok(_))
  assert_eq(stream.timeout_calls, before)
  assert_true(response.body.peer_addr() is Err(Closed))
  assert_true(response.body.local_addr() is Err(Closed))
  assert_false(response.body.read_ready())
  let _ = client.close_all()
}
