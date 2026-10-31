fn early_hints_h1_response(raw : String) -> Response {
  let stream : &Stream = AutoDecompressMockStream::{
    input: @utf8.encode(raw),
    offset: 0,
    output: Buffer(size_hint=0),
  }
  H1Codec::new(stream).decode_response().unwrap()
}

test "HTTP/1.1 responses expose informational headers in wire order" {
  let response = early_hints_h1_response(
    "HTTP/1.1 103 Early Hints\r\nLink: </style.css>; rel=preload\r\n\r\n" +
    "HTTP/1.1 100 Continue\r\n\r\n" +
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok",
  )
  let hints = response.early_hints()
  assert_eq(hints.length(), 2)
  let (first_status, first_headers) = hints[0]
  assert_eq(first_status, 103)
  assert_eq(first_headers.get("link"), Some("</style.css>; rel=preload"))
  let (second_status, _) = hints[1]
  assert_eq(second_status, 100)
  assert_eq(response.status, 200)
  assert_eq(response.headers.get("link"), None)
  assert_eq(response.read_body().unwrap(), b"ok")
}

test "responses without informational headers expose an empty hint list" {
  let response = early_hints_h1_response(
    "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n",
  )
  assert_eq(response.early_hints().length(), 0)
}

test "HTTP/2 responses expose informational headers alongside final headers" {
  let informational = hpack_encode([
    (":status", "103"),
    ("link", "</app.css>; rel=preload"),
  ])
  let final_headers = hpack_encode([
    (":status", "200"),
    ("content-type", "text/plain"),
  ])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, informational),
    h2_test_frame(
      H2_FRAME_HEADERS,
      H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM,
      1,
      final_headers,
    ),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let request = Request::new(GET, Url::parse("https://example.com/").unwrap())
  let response = h2_request(stream, request).unwrap()
  let hints = response.early_hints()
  assert_eq(hints.length(), 1)
  let (status, headers) = hints[0]
  assert_eq(status, 103)
  assert_eq(headers.get("link"), Some("</app.css>; rel=preload"))
  assert_eq(response.status, 200)
  assert_eq(response.headers.get("link"), None)
  assert_eq(response.read_body().unwrap(), b"")
}
