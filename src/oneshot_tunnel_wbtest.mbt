fn oneshot_test_client() -> UnifiedClient {
  UnifiedClient::{
    connector: Connector::new(TcpDialer::new(), MockTlsProvider::new("test")),
    options: ClientOptions::new().with_follow_redirects(false),
    redirect_count: 0,
  }
}

/// A one-shot helper buffers a response, so it cannot hand back an interactive
/// upgraded stream. It must fail instead of reading the tunnel until EOF.
test "one-shot buffering rejects a switched protocol response" {
  let stream = regression_mock_stream(
    "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n",
    0,
    0,
  )
  let codec = H1Codec::new(stream)
  codec.encode_request(
    Request::new(GET, Url::parse("http://example.com/chat").unwrap())
      .with_upgrade("websocket"),
  ).unwrap()
  let response = codec.decode_response().unwrap()
  let client = oneshot_test_client()
  match buffer_one_shot_response(client, Ok(response), upgrade=true) {
    Ok(_) => fail("one-shot buffering accepted an upgraded stream")
    Err(ProtocolError(message)) =>
      assert_true(message.contains("tunnel"))
    Err(err) => fail("unexpected error: " + @debug.to_string(err))
  }
  assert_false(stream.is_open)
}

/// A successful CONNECT is a tunnel too.
test "one-shot buffering rejects a successful CONNECT" {
  let stream = regression_mock_stream(
    "HTTP/1.1 200 Connection Established\r\n\r\n",
    0,
    0,
  )
  let codec = H1Codec::new(stream)
  codec.encode_request(
    Request::new(CONNECT, Url::parse("http://example.com:80/").unwrap()),
  ).unwrap()
  let response = codec.decode_response().unwrap()
  let client = oneshot_test_client()
  match buffer_one_shot_response(client, Ok(response), connect=true) {
    Ok(_) => fail("one-shot buffering accepted a CONNECT tunnel")
    Err(ProtocolError(message)) =>
      assert_true(message.contains("tunnel"))
    Err(err) => fail("unexpected error: " + @debug.to_string(err))
  }
  assert_false(stream.is_open)
}

/// A normal response to an upgrade offer is still bufferable.
test "one-shot buffering keeps an ordinary response to an upgrade offer" {
  let stream = regression_mock_stream(
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok",
    0,
    0,
  )
  let codec = H1Codec::new(stream)
  codec.encode_request(
    Request::new(GET, Url::parse("http://example.com/chat").unwrap())
      .with_upgrade("websocket"),
  ).unwrap()
  let response = codec.decode_response().unwrap()
  let client = oneshot_test_client()
  let buffered = buffer_one_shot_response(client, Ok(response), upgrade=true).unwrap()
  assert_eq(buffered.read_body().unwrap(), b"ok")
}
