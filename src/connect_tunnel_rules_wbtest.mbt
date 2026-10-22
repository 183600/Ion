test "CONNECT requests reject Content-Length in both HTTP versions" {
  let url = Url::parse("http://example.com:80/").unwrap()
  let request = Request::new(CONNECT, url).with_header("Content-Length", "0")
  let codec = H1Codec::new(regression_mock_stream("", 0, 0))
  assert_true(codec.encode_request(request) is Err(InvalidHeader(_)))
  assert_true(h2_request_headers(request) is Err(InvalidHeader(_)))
}

test "HTTP/1 CONNECT tunnel bytes are not capped as a response body" {
  let stream = regression_mock_stream(
    "HTTP/1.1 200 Connection Established\r\n\r\nhello",
    0,
    0,
  )
  let codec = H1Codec::new_with_limit(stream, 4)
  codec.encode_request(
    Request::new(CONNECT, Url::parse("http://example.com:80/").unwrap()),
  ).unwrap()
  let response = codec.decode_response().unwrap()
  assert_eq(response.read_body().unwrap(), b"hello")
}

test "HTTP/2 CONNECT tunnel bytes are not capped as a response body" {
  let headers = hpack_encode([(":status", "200")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, headers),
    h2_test_frame(H2_FRAME_DATA, H2_FLAG_END_STREAM, 1, @utf8.encode("hello")),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let response = h2_request_with_limit(
    stream,
    Request::new(CONNECT, Url::parse("http://example.com:80/").unwrap()),
    4,
  ).unwrap()
  assert_eq(response.status, 200)
  assert_eq(response.read_body().unwrap(), b"hello")
}
