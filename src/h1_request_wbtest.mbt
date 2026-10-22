///|
test "h1_request runs a request and response over a caller-provided stream" {
  let stream = regression_mock_stream(
    "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello",
    0,
    0,
  )
  let request = Request::from_url(GET, "http://example.com/path?q=1").unwrap()
  let response = h1_request(stream, request).unwrap()
  assert_eq(response.status, 200)
  assert_eq(response.text().unwrap(), "hello")
  let wire = @utf8.decode_lossy(stream.output.to_bytes()[:])
  assert_true(wire.has_prefix("GET /path?q=1 HTTP/1.1\r\n"))
  assert_true(wire.contains("Host: example.com\r\n"))
}

///|
test "h1_request supports an explicit response limit and absolute-form" {
  let stream = regression_mock_stream(
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok",
    0,
    0,
  )
  let request = Request::from_url(GET, "http://example.com/proxied").unwrap()
  let response = h1_request_with_limit(
    stream,
    request,
    1,
    absolute_form=true,
  ).unwrap()
  assert_true(response.read_body() is Err(_))
  let wire = @utf8.decode_lossy(stream.output.to_bytes()[:])
  assert_true(wire.has_prefix("GET http://example.com/proxied HTTP/1.1\r\n"))
}

///|
test "h1_request honors absolute-form for an https target" {
  let stream = regression_mock_stream(
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok",
    0,
    0,
  )
  let request = Request::from_url(GET, "https://example.com/proxied").unwrap()
  let response = h1_request(stream, request, absolute_form=true).unwrap()
  assert_eq(response.text().unwrap(), "ok")
  let wire = @utf8.decode_lossy(stream.output.to_bytes()[:])
  assert_true(wire.has_prefix("GET https://example.com/proxied HTTP/1.1\r\n"))
}

///|
test "h1_request frames HEAD responses without a body" {
  let stream = regression_mock_stream(
    "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n",
    0,
    0,
  )
  let request = Request::from_url(HEAD, "http://example.com/head").unwrap()
  let response = h1_request(stream, request).unwrap()
  assert_eq(response.status, 200)
  assert_eq(response.read_body().unwrap(), b"")
}

///|
test "H1Codec implements HttpClient and reuses buffered input" {
  let stream = codec_reuse_stream([
    "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\none",
    "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\ntwo",
  ])
  let codec = H1Codec::new(stream)
  let client : &HttpClient = codec
  match client.get("http://example.com/one") {
    Ok(response) => assert_eq(response.text().unwrap(), "one")
    Err(err) => fail("trait request failed: " + @debug.to_string(err))
  }
  match client.get("http://example.com/two") {
    Ok(response) => assert_eq(response.text().unwrap(), "two")
    Err(err) => fail("second trait request failed: " + @debug.to_string(err))
  }
}

///|
test "H1Codec::request keeps a shared reader across exchanges" {
  let stream = codec_reuse_stream([
    "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\none",
    "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\ntwo",
  ])
  let codec = H1Codec::new(stream)
  let first = Request::from_url(GET, "http://example.com/one").unwrap()
  assert_eq(codec.request(first).unwrap().text().unwrap(), "one")
  let second = Request::from_url(GET, "http://example.com/two").unwrap()
  assert_eq(codec.request(second).unwrap().text().unwrap(), "two")
}

///|
test "H1Codec request rejects an invalid request without sending it" {
  let stream = regression_mock_stream("", 0, 0)
  let codec = H1Codec::new(stream)
  let url = Url::parse("http://example.com/").unwrap()
  let request = Request::new(GET, url).with_header("Bad Header", "x")
  assert_true(codec.request(request) is Err(InvalidHeader(_)))
  assert_eq(stream.output.length(), 0)
}
