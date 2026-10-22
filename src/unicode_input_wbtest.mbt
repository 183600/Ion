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

test "astral characters in host names remain rejected" {
  assert_true(Url::parse("http://🙂.example/") is Err(_))
  assert_true(Url::parse("http://example.com/") is Ok(_))
}

test "raw non-ASCII host names are rejected consistently" {
  for url in [
    "http://éxample.com/",
    "http://exa中mple.com/",
    "http://example.comé/",
  ] {
    assert_true(Url::parse(url) is Err(_))
  }
  // Paths, queries, and fragments still accept non-ASCII text.
  assert_true(Url::parse("http://example.com/é?q=中") is Ok(_))
}

test "response Connection values with astral characters do not panic" {
  let raw = "HTTP/1.1 200 OK\r\nConnection: 🙂, keep-alive\r\nContent-Length: 2\r\n\r\nok"
  let stream = regression_mock_stream(raw, 1, 0)
  let response = H1Codec::new(stream).decode_response().unwrap()
  assert_eq(response.text().unwrap(), "ok")
}

test "invalid Transfer-Encoding with astral characters is rejected" {
  let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: 🙂\r\n\r\n"
  let stream = regression_mock_stream(raw, 1, 0)
  let response = H1Codec::new(stream).decode_response().unwrap()
  assert_true(response.text() is Err(_))
}

test "chunk extensions and trailers accept astral characters" {
  let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5;note=\"🙂\"\r\nhello\r\n0\r\nX-Trailer: 🙂\r\n\r\n"
  let stream = regression_mock_stream(raw, 1, 0)
  let response = H1Codec::new(stream).decode_response().unwrap()
  assert_eq(response.text().unwrap(), "hello")
  assert_eq(response.trailers().get("x-trailer"), Some("🙂"))
}

test "unquoted astral chunk extensions are rejected without panicking" {
  let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5;🙂\r\nhello\r\n0\r\n\r\n"
  let stream = regression_mock_stream(raw, 1, 0)
  let response = H1Codec::new(stream).decode_response().unwrap()
  assert_true(response.text() is Err(_))
}

test "proxy bypass patterns with astral characters do not panic" {
  assert_false(proxy_bypass_matches("🙂", "example.com", 80))
  assert_false(proxy_bypass_matches("example.com🙂", "example.com", 80))
}
