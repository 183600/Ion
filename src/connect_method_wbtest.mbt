///|
test "CONNECT parses and serializes as an HTTP method" {
  assert_eq(HttpMethod::parse("connect"), Ok(CONNECT))
  assert_eq(HttpMethod::parse("CONNECT"), Ok(CONNECT))
  assert_eq(CONNECT.to_string(), "CONNECT")
}

///|
test "HTTP/1 CONNECT uses authority-form and always includes the port" {
  let url = Url::parse("http://example.com/").unwrap()
  assert_eq(url.connect_authority(), "example.com:80")
  let stream = regression_mock_stream("", 0, 0)
  let codec = H1Codec::new(stream)
  codec.encode_request(Request::new(CONNECT, url)).unwrap()
  assert_eq(
    @utf8.decode(stream.output.to_bytes()[:]),
    "CONNECT example.com:80 HTTP/1.1\r\nHost: example.com:80\r\nUser-Agent: Feather/0.1.0\r\n\r\n",
  )

  let ipv6 = Url::parse("https://[::1]:8443/").unwrap()
  let ipv6_stream = regression_mock_stream("", 0, 0)
  let ipv6_codec = H1Codec::new(ipv6_stream)
  ipv6_codec.encode_request(Request::new(CONNECT, ipv6)).unwrap()
  assert_true(
    @utf8.decode(ipv6_stream.output.to_bytes()[:]).has_prefix(
      "CONNECT [::1]:8443 HTTP/1.1\r\nHost: [::1]:8443\r\n",
    ),
  )
}

///|
test "HTTP/1 CONNECT rejects URL paths and request content" {
  let url = Url::parse("http://example.com/").unwrap()
  let with_path = Url::parse("http://example.com/tunnel").unwrap()
  let with_query = Url::parse("http://example.com/?target=x").unwrap()
  for target in [with_path, with_query] {
    let codec = H1Codec::new(regression_mock_stream("", 0, 0))
    assert_true(
      codec.encode_request(Request::new(CONNECT, target)) is Err(InvalidUrl(_)),
    )
  }
  let cases = [
    Request::new(CONNECT, url).with_body(@utf8.encode("x")),
    Request::new(CONNECT, url).with_trailer("X-Trailer", "v"),
    Request::new(CONNECT, url).with_header("Transfer-Encoding", "chunked"),
  ]
  for request in cases {
    let codec = H1Codec::new(regression_mock_stream("", 0, 0))
    assert_true(
      codec.encode_request(request) is Err(InvalidHeader(_)),
    )
  }
}

///|
test "HTTP/1 successful CONNECT exposes the tunnel as the response stream" {
  let stream = regression_mock_stream(
    "HTTP/1.1 200 Connection Established\r\n\r\nhello",
    0,
    0,
  )
  let codec = H1Codec::new(stream)
  codec.encode_request(
    Request::new(CONNECT, Url::parse("http://example.com:80/").unwrap()),
  ).unwrap()
  let response = codec.decode_response().unwrap()
  assert_eq(response.status, 200)
  assert_eq(response.read_body().unwrap(), b"hello")
  assert_false(stream.is_open)
}

///|
test "HTTP/1 successful CONNECT rejects HTTP body framing" {
  for raw in [
    "HTTP/1.1 200 Connection Established\r\nContent-Length: 0\r\n\r\n",
    "HTTP/1.1 200 Connection Established\r\nTransfer-Encoding: chunked\r\n\r\n",
  ] {
    let codec = H1Codec::new(regression_mock_stream(raw, 0, 0))
    codec.encode_request(
      Request::new(CONNECT, Url::parse("http://example.com:80/").unwrap()),
    ).unwrap()
    match codec.decode_response() {
      Ok(_) => fail("CONNECT response with framing headers was accepted")
      Err(ProtocolError(message)) =>
        assert_true(message.contains("CONNECT response"))
      Err(_) => fail("unexpected CONNECT response error")
    }
  }
}

///|
test "HTTP/1 failed CONNECT still carries an ordinary response body" {
  let stream = regression_mock_stream(
    "HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 4\r\n\r\nnope",
    0,
    0,
  )
  let codec = H1Codec::new(stream)
  codec.encode_request(
    Request::new(CONNECT, Url::parse("http://example.com:80/").unwrap()),
  ).unwrap()
  let response = codec.decode_response().unwrap()
  assert_eq(response.status, 407)
  assert_eq(response.read_body().unwrap(), b"nope")
}

///|
test "HTTP/2 CONNECT omits :scheme and :path" {
  let fields = h2_request_headers(
    Request::new(CONNECT, Url::parse("http://example.com:8080/").unwrap()),
  ).unwrap()
  assert_eq(
    fields,
    [
      (":method", "CONNECT"),
      (":authority", "example.com:8080"),
      ("user-agent", "Feather/0.1.0"),
    ],
  )
  let with_path = Url::parse("http://example.com/tunnel").unwrap()
  assert_eq(
    h2_request_headers(Request::new(CONNECT, with_path)),
    Err(InvalidUrl("CONNECT requires an authority-form target")),
  )
  let with_body = Request::new(
    CONNECT,
    Url::parse("http://example.com/").unwrap(),
  ).with_body(b"x")
  assert_eq(
    h2_request_headers(with_body),
    Err(InvalidHeader("CONNECT request content is not allowed")),
  )
}

///|
test "HTTP/2 successful CONNECT reads tunnel DATA until END_STREAM" {
  let headers = hpack_encode([(":status", "200")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, headers),
    h2_test_frame(H2_FRAME_DATA, H2_FLAG_END_STREAM, 1, b"hello"),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let connection = H2ClientConnection::new(stream).unwrap()
  let response = connection.request(
    Request::new(CONNECT, Url::parse("http://example.com:80/").unwrap()),
  ).unwrap()
  assert_eq(response.status, 200)
  assert_eq(response.read_body().unwrap(), b"hello")
}

///|
test "HTTP/2 successful CONNECT rejects Content-Length" {
  let headers = hpack_encode([(":status", "200"), ("content-length", "0")])
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
  let connection = H2ClientConnection::new(stream).unwrap()
  match connection.request(
    Request::new(CONNECT, Url::parse("http://example.com:80/").unwrap()),
  ) {
    Ok(_) => fail("CONNECT response with Content-Length was accepted")
    Err(err) =>
      assert_eq(
        err,
        ProtocolError("Successful CONNECT response must not include Content-Length"),
      )
  }
}

///|
test "UnifiedClient exposes a CONNECT convenience method" {
  let stream = regression_mock_stream(
    "HTTP/1.1 200 Connection Established\r\n\r\ntunnel",
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
  let response = client.connect("http://example.com:80/").unwrap()
  assert_eq(response.status, 200)
  assert_eq(response.read_body().unwrap(), b"tunnel")
  let wire = @utf8.decode(stream.output.to_bytes()[:])
  assert_true(wire.has_prefix("CONNECT example.com:80 HTTP/1.1\r\n"))
  let _ = client.close_all()
}

///|
test "CONNECT responses are not followed as redirects" {
  let raw = "HTTP/1.1 303 See Other\r\nLocation: http://evil.example/pwn\r\nContent-Length: 0\r\n\r\n"
  let stream = regression_mock_stream(raw, 4096, 4096)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let client = UnifiedClient::{
    connector,
    options: ClientOptions::new(),
    redirect_count: 0,
  }
  let response = client.connect("http://example.com:80/").unwrap()
  assert_eq(response.status, 303)
  assert_eq(response.get_header("Location"), Some("http://evil.example/pwn"))
  assert_eq(response.read_body().unwrap(), b"")
  assert_eq(dialer.count, 1)
  let wire = @utf8.decode(stream.output.to_bytes()[:])
  assert_true(!wire.contains("GET http://evil.example/pwn"))
  assert_true(!wire.contains("CONNECT evil.example"))
  let _ = client.close_all()
}
