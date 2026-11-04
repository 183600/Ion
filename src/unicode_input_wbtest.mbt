///|
test "URL and request encoding accept astral characters" {
  let url = Url::parse("http://example.com/🙂/é?q=🙂#中").unwrap()
  assert_eq(url.path, "/🙂/é")
  assert_eq(url.query, "q=🙂")
  assert_eq(url.to_string(), "http://example.com/🙂/é?q=🙂#中")
  let stream = regression_mock_stream("", 0, 0)
  let codec = H1Codec::new(stream)
  let request = Request::new(GET, url).with_header("Connection", "🙂")
  codec.encode_request(request).unwrap()
  let wire = @utf8.decode(stream.output.to_bytes()[:])
  assert_true(wire.has_prefix("GET /🙂/é?q=🙂 HTTP/1.1\r\n"))
  assert_true(wire.contains("Connection: 🙂\r\n"))
}

///|
test "astral characters in host names are converted with IDNA" {
  let url = Url::parse("http://🙂.example/").unwrap()
  assert_eq(url.host, "xn--938h.example")
  assert_true(Url::parse("http://example.com/") is Ok(_))
}

///|
test "raw non-ASCII host names are converted with IDNA" {
  for
    (url, host) in [
      ("http://éxample.com/", "xn--xample-9ua.com"),
      ("http://exa中mple.com/", "xn--example-i43k.com"),
      ("http://example.comé/", "example.xn--com-dma"),
    ] {
    assert_eq(Url::parse(url).unwrap().host, host)
  }
  // Paths, queries, and fragments still accept non-ASCII text.
  let url = Url::parse("http://example.com/é?q=中").unwrap()
  assert_eq(url.path, "/é")
  assert_eq(url.query, "q=中")
}

///|
test "response Connection values with astral characters do not panic" {
  let raw = "HTTP/1.1 200 OK\r\nConnection: 🙂, keep-alive\r\nContent-Length: 2\r\n\r\nok"
  let stream = regression_mock_stream(raw, 1, 0)
  let response = H1Codec::new(stream).decode_response().unwrap()
  assert_eq(response.text().unwrap(), "ok")
}

///|
test "invalid Transfer-Encoding with astral characters is rejected" {
  let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: 🙂\r\n\r\n"
  let stream = regression_mock_stream(raw, 1, 0)
  let response = H1Codec::new(stream).decode_response().unwrap()
  assert_true(response.text() is Err(_))
}

///|
test "chunk extensions and trailers accept astral characters" {
  let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5;note=\"🙂\"\r\nhello\r\n0\r\nX-Trailer: 🙂\r\n\r\n"
  let stream = regression_mock_stream(raw, 1, 0)
  let response = H1Codec::new(stream).decode_response().unwrap()
  assert_eq(response.text().unwrap(), "hello")
  assert_eq(response.trailers().get("x-trailer"), Some("🙂"))
}

///|
test "unquoted astral chunk extensions are rejected without panicking" {
  let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5;🙂\r\nhello\r\n0\r\n\r\n"
  let stream = regression_mock_stream(raw, 1, 0)
  let response = H1Codec::new(stream).decode_response().unwrap()
  assert_true(response.text() is Err(_))
}

///|
test "proxy bypass patterns with astral characters do not panic" {
  assert_false(proxy_bypass_matches("🙂", "example.com", 80))
  assert_false(proxy_bypass_matches("example.com🙂", "example.com", 80))
}
