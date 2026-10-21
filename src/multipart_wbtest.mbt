fn multipart_test_url() -> Url {
  Url::parse("http://example.com/upload").unwrap()
}

fn multipart_body_text(request : Request) -> String {
  match request.body {
    Some(body) => @utf8.decode_lossy(body[:])
    None => ""
  }
}

test "multipart request encodes fields and files" {
  let request = Request::new(POST, multipart_test_url()).with_multipart(
    [("title", "hello")],
    [
      MultipartFile::new(
        "file",
        "a.txt",
        "text/plain",
        @utf8.encode("payload"),
      ),
    ],
  )
  assert_eq(
    request.get_header("Content-Type"),
    Some("multipart/form-data; boundary=----FeatherFormBoundary"),
  )
  let boundary = "----FeatherFormBoundary"
  let expected = "--" + boundary +
    "\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nhello\r\n--" +
    boundary +
    "\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.txt\"\r\nContent-Type: text/plain\r\n\r\npayload\r\n--" +
    boundary + "--\r\n"
  assert_eq(multipart_body_text(request), expected)
}

test "multipart boundary avoids field contents" {
  let request = Request::new(POST, multipart_test_url()).with_multipart(
    [("value", "contains ----FeatherFormBoundary here")],
    [],
  )
  assert_eq(
    request.get_header("Content-Type"),
    Some("multipart/form-data; boundary=----FeatherFormBoundary1"),
  )
  let body = multipart_body_text(request)
  assert_true(body.has_prefix("------FeatherFormBoundary1\r\n"))
  assert_true(body.has_suffix("------FeatherFormBoundary1--\r\n"))
}

test "multipart escapes quotes and strips line breaks from parameters" {
  let request = Request::new(POST, multipart_test_url()).with_multipart(
    [("line\r\nX-Evil", "value")],
    [
      MultipartFile::new(
        "upload",
        "a\"b\\c.txt",
        "text/plain",
        @utf8.encode("payload"),
      ),
    ],
  )
  let body = multipart_body_text(request)
  assert_true(body.contains("name=\"line  X-Evil\""))
  assert_true(body.contains("filename=\"a\\\"b\\\\c.txt\""))
  assert_false(body.contains("\r\nX-Evil:"))
}

test "multipart handles empty forms and binary data" {
  let empty = Request::new(POST, multipart_test_url()).with_multipart([], [])
  assert_eq(
    multipart_body_text(empty),
    "------FeatherFormBoundary--\r\n",
  )
  let data : Bytes = [0, 13, 10, 255]
  let request = Request::new(POST, multipart_test_url()).with_multipart(
    [],
    [MultipartFile::new("blob", "data.bin", "application/octet-stream", data)],
  )
  let body = match request.body {
    Some(body) => body
    None => abort("missing multipart body")
  }
  let expected = Buffer(size_hint=128)
  expected.write_bytes(
    @utf8.encode(
      "--" +
      "----FeatherFormBoundary" +
      "\r\nContent-Disposition: form-data; name=\"blob\"; filename=\"data.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n",
    ),
  )
  expected.write_bytes(data)
  expected.write_bytes(@utf8.encode("\r\n------FeatherFormBoundary--\r\n"))
  assert_eq(body, expected.to_bytes())
}

test "UnifiedClient sends multipart requests" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
  let stream = regression_mock_stream(raw, 1, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let client = UnifiedClient::{
    connector,
    options: ClientOptions::new().with_follow_redirects(false),
    redirect_count: 0,
  }
  let response = client.post_multipart(
    "http://example.com/upload",
    [("title", "hello")],
    [MultipartFile::new("file", "a.txt", "text/plain", @utf8.encode("payload"))],
  ).unwrap()
  assert_eq(response.status, 200)
  let wire = @utf8.decode(stream.output.to_bytes()[:])
  assert_true(wire.contains("POST /upload HTTP/1.1"))
  assert_true(wire.contains("Content-Type: multipart/form-data; boundary="))
  assert_true(wire.contains("name=\"title\"\r\n\r\nhello"))
  assert_true(wire.contains("filename=\"a.txt\"\r\nContent-Type: text/plain\r\n\r\npayload"))
}

test "multipart preserves content type parameters and sanitizes controls" {
  let request = Request::new(POST, multipart_test_url()).with_multipart(
    [("note\u{0}name", "value")],
    [
      MultipartFile::new(
        "upload",
        "a\u{0}b.txt",
        "text/plain; charset=\"utf-8\"",
        @utf8.encode("payload"),
      ),
    ],
  )
  let body = multipart_body_text(request)
  assert_true(body.contains("name=\"note name\""))
  assert_true(body.contains("filename=\"a b.txt\""))
  assert_true(body.contains("Content-Type: text/plain; charset=\"utf-8\"\r\n\r\n"))
  assert_false(body.contains("\u{0}"))
}
