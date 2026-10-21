// Edge-case regression tests covering URL parsing corner cases, form
// encoding, redirect resolution, transfer-encoding handling, and
// header-validation behavior of the codec.

test "url userinfo and host parsing edge cases" {
  // Invalid percent escapes, backslashes and brackets are rejected in userinfo.
  assert_true(Url::parse("http://%zz@example.com/") is Err(_))
  assert_true(Url::parse("http://us\\er@example.com/") is Err(_))
  assert_true(Url::parse("http://us[er@example.com/") is Err(_))
  // Empty userinfo and empty passwords are allowed.
  assert_true(Url::parse("http://@example.com/") is Ok(_))
  assert_true(Url::parse("http://user:@example.com/") is Ok(_))
  // Percent escapes in the host and leading zeros in the port are accepted.
  assert_true(Url::parse("http://exa%2Fmple.com/") is Ok(_))
  assert_true(Url::parse("http://example.com:0080/") is Ok(_))
}

test "form encoding escapes tilde space and percent literally" {
  let form = Request::new(POST, Url::new("http", "x", 80)).with_form([
    ("a", "~"),
    ("b", "*"),
    ("c", " "),
    ("d", "%"),
  ])
  assert_eq(
    @utf8.decode_lossy(form.body.unwrap()[:]),
    "a=%7E&b=*&c=+&d=%25",
  )
}

test "redirect resolution handles query scheme-relative and absolute targets" {
  let base = Url::parse("http://example.com/dir/page?q=1").unwrap()
  assert_eq(
    resolve_redirect_url(base, "?x=2").unwrap().to_string(),
    "http://example.com/dir/page?x=2",
  )
  assert_eq(
    resolve_redirect_url(base, "//other/x").unwrap().to_string(),
    "http://other/x",
  )
  assert_eq(
    resolve_redirect_url(base, "HTTP://OTHER/x").unwrap().to_string(),
    "http://OTHER/x",
  )
  assert_eq(
    resolve_redirect_url(base, "next").unwrap().to_string(),
    "http://example.com/dir/next",
  )
  // Schemes are case-insensitive; the authority is preserved as written.
  let up = Url::parse("HTTP://Example.COM:80/").unwrap()
  assert_eq(up.authority(), "Example.COM")
}

test "response with gzip transfer-encoding and chunked framing decodes body" {
  let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n"
  let codec = H1Codec::new(regression_mock_stream(raw, 0, 0))
  let response = codec.decode_response().unwrap()
  assert_eq(@utf8.decode_lossy(response.read_body().unwrap()[:]), "hello")
}

test "request encoding accepts cl whitespace and host trailing dot" {
  let stream = regression_mock_stream("", 0, 0)
  let codec = H1Codec::new(stream)
  let url = Url::parse("http://example.com/").unwrap()
  let req = Request::new(POST, url)
    .with_header("Content-Length", " 5 ")
    .with_body(@utf8.encode("hello"))
  assert_true(codec.encode_request(req) is Ok(_))
  let wire = @utf8.decode_lossy(stream.output.to_bytes()[:])
  assert_true(wire.has_prefix("POST / HTTP/1.1\r\n"))
  assert_true(wire.has_suffix("hello"))

  let stream3 = regression_mock_stream("", 0, 0)
  let codec3 = H1Codec::new(stream3)
  assert_true(
    codec3
      .encode_request(
        Request::new(GET, url).with_header("Host", "example.com."),
      )
      is Ok(_),
  )
}

test "status line without reason phrase and 304 without body" {
  // A status line may omit the reason phrase.
  let raw2 = "HTTP/1.1 200\r\nContent-Length: 0\r\n\r\n"
  assert_true(
    H1Codec::new(regression_mock_stream(raw2, 0, 0))
      .decode_response()
      is Ok(_),
  )
  // 304 responses carry no body: the reader stops right after the headers,
  // leaving the remaining bytes (here "helloNEXT") for the connection pool.
  let raw3 = "HTTP/1.1 304 Not Modified\r\nContent-Length: 5\r\n\r\nhelloNEXT"
  let s3 = regression_mock_stream(raw3, 1, 0)
  let c3 = H1Codec::new(s3)
  let response = c3.decode_response().unwrap()
  let buf = @buffer.new(size_hint=8)
  assert_eq(response.body.read(buf).unwrap(), 0)
  assert_eq(s3.offset, 48)
}
