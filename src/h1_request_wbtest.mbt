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
