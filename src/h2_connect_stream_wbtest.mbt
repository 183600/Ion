/// A successful CONNECT response must be returned as soon as its headers are
/// complete: the tunnel may stay open until the remote peer closes, so waiting
/// for END_STREAM would deadlock before the caller can exchange any bytes.
test "http2 CONNECT returns after response headers without END_STREAM" {
  let headers = hpack_encode([(":status", "200")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, headers),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let response = h2_request(
    stream,
    Request::new(CONNECT, Url::parse("http://example.com:80/").unwrap()),
  ).unwrap()
  assert_eq(response.status, 200)
  response.body.close().unwrap()
  assert_false(stream.is_open)
}

test "http2 CONNECT streams DATA frames on demand" {
  let headers = hpack_encode([(":status", "200")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, headers),
    h2_test_frame(H2_FRAME_DATA, 0, 1, @utf8.encode("hel")),
    h2_test_frame(H2_FRAME_DATA, H2_FLAG_END_STREAM, 1, @utf8.encode("lo")),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let response = h2_request(
    stream,
    Request::new(CONNECT, Url::parse("http://example.com:80/").unwrap()),
  ).unwrap()
  assert_eq(response.read_body().unwrap(), b"hello")
  assert_false(stream.is_open)
}

test "http2 CONNECT exposes trailers received after the tunnel data" {
  let headers = hpack_encode([(":status", "200")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, headers),
    h2_test_frame(H2_FRAME_DATA, 0, 1, @utf8.encode("tunnel")),
    h2_test_frame(
      H2_FRAME_HEADERS,
      H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM,
      1,
      hpack_encode([("x-trailer", "done")]),
    ),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let response = h2_request(
    stream,
    Request::new(CONNECT, Url::parse("http://example.com:80/").unwrap()),
  ).unwrap()
  assert_eq(response.read_body().unwrap(), b"tunnel")
  assert_eq(response.trailers().get("x-trailer"), Some("done"))
  assert_false(stream.is_open)
}

test "UnifiedClient keeps an HTTP/2 CONNECT lease until the tunnel closes" {
  let headers = hpack_encode([(":status", "200")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, headers),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let provider = H2NegotiatingTlsProvider::{ protocol: Some("h2") }
  let client = UnifiedClient::with_transport(
    dialer,
    provider,
    ClientOptions::new().with_follow_redirects(false),
  )
  let request = Request::from_url(
    CONNECT,
    "https://example.com:443/",
  ).unwrap()
  let response = client.request(request).unwrap()
  assert_eq(response.status, 200)
  assert_eq(client.connector.pool.val.active.length(), 1)
  response.body.close().unwrap()
  assert_false(stream.is_open)
  assert_eq(client.connector.pool.val.active.length(), 0)
}
