// Public convenience methods should send the same request shape as the
// equivalent `Request` built by hand, and closing a client must release every
// pooled connection.

///|
fn client_for_response(raw : String) -> (UnifiedClient, RegressionMockStream) {
  let stream = regression_mock_stream(raw, 0, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0, }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let options = ClientOptions::new().with_follow_redirects(false)
  (UnifiedClient::{ connector, options, redirect_count: 0, }, stream)
}

///|
test "UnifiedClient convenience methods use the right verbs and bodies" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
  let (client, stream) = client_for_response(raw)
  assert_true(
    client.put("http://example.com/put", @utf8.encode("put-body")) is Ok(_),
  )
  let wire = @utf8.decode_lossy(stream.output.to_bytes()[:])
  assert_true(wire.has_prefix("PUT /put HTTP/1.1\r\n"))
  assert_true(wire.has_suffix("\r\n\r\nput-body"))

  let (client, stream) = client_for_response(raw)
  assert_true(
    client.patch("http://example.com/patch", @utf8.encode("patch-body"))
    is Ok(_),
  )
  let wire = @utf8.decode_lossy(stream.output.to_bytes()[:])
  assert_true(wire.has_prefix("PATCH /patch HTTP/1.1\r\n"))
  assert_true(wire.has_suffix("\r\n\r\npatch-body"))

  let (client, stream) = client_for_response(raw)
  assert_true(client.delete("http://example.com/delete") is Ok(_))
  let wire = @utf8.decode_lossy(stream.output.to_bytes()[:])
  assert_true(wire.has_prefix("DELETE /delete HTTP/1.1\r\n"))
  assert_true(!wire.contains("Content-Length"))

  let (client, stream) = client_for_response(raw)
  assert_true(client.options("http://example.com/options") is Ok(_))
  let wire = @utf8.decode_lossy(stream.output.to_bytes()[:])
  assert_true(wire.has_prefix("OPTIONS /options HTTP/1.1\r\n"))
  assert_true(!wire.contains("Content-Length"))

  let (client, stream) = client_for_response(raw)
  assert_true(client.head("http://example.com/head") is Ok(_))
  let wire = @utf8.decode_lossy(stream.output.to_bytes()[:])
  assert_true(wire.has_prefix("HEAD /head HTTP/1.1\r\n"))
  assert_true(!wire.contains("Content-Length"))
}

///|
test "UnifiedClient form and multipart helpers post encoded bodies" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
  let (client, stream) = client_for_response(raw)
  assert_true(
    client.post_form("http://example.com/form", [("q", "a b"), ("x", "1+2")])
    is Ok(_),
  )
  let wire = @utf8.decode_lossy(stream.output.to_bytes()[:])
  assert_true(wire.has_prefix("POST /form HTTP/1.1\r\n"))
  assert_true(
    wire.contains("Content-Type: application/x-www-form-urlencoded\r\n"),
  )
  assert_true(wire.has_suffix("\r\n\r\nq=a+b&x=1%2B2"))

  let (client, stream) = client_for_response(raw)
  assert_true(
    client.post_multipart("http://example.com/upload", [("name", "value")], [
      MultipartFile::new("file", "a.txt", "text/plain", @utf8.encode("data")),
    ])
    is Ok(_),
  )
  let wire = @utf8.decode_lossy(stream.output.to_bytes()[:])
  assert_true(wire.has_prefix("POST /upload HTTP/1.1\r\n"))
  assert_true(wire.contains("Content-Type: multipart/form-data; boundary="))
  assert_true(
    wire.contains(
      "Content-Disposition: form-data; name=\"file\"; filename=\"a.txt\"",
    ),
  )
}

///|
test "UnifiedClient close releases the idle connection" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
  let (client, stream) = client_for_response(raw)
  assert_true(client.get("http://example.com/") is Ok(_))
  assert_true(stream.is_open)
  assert_true(client.close() is Ok(_))
  assert_false(stream.is_open)
}

///|
test "Connector close removes idle and active connections for an origin" {
  let stream = regression_mock_stream("", 0, 0)
  let dialer = RegressionQueueDialer::{ streams: [stream], index: 0, }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let url = Url::parse("http://example.com/").unwrap()
  assert_true(connector.connect(url) is Ok(_))
  assert_true(stream.is_open)
  assert_true(connector.close(url) is Ok(_))
  assert_false(stream.is_open)
  // Closing again is harmless.
  assert_true(connector.close(url) is Ok(_))
}
