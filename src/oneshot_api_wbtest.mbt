///|
test "one-shot helpers validate URLs before dialing" {
  for result in [
    get("not a url"),
    post("not a url", b"body"),
    put("not a url", b"body"),
    delete("not a url"),
    head("not a url"),
    options("not a url"),
    patch("not a url", b"body"),
    trace("not a url"),
    post_form("not a url", [("a", "b")]),
    post_multipart("not a url", [("a", "b")], []),
  ] {
    assert_true(result is Err(InvalidUrl(_)))
  }
  // `request` takes an already parsed URL; connector validation still rejects
  // an invalid authority before any socket is opened.
  let url = Url::new("http", "bad host", 80)
  assert_true(request(Request::new(GET, url)) is Err(InvalidUrl(_)))
}

///|
test "Response exposes its body stream" {
  let stream = regression_mock_stream("hello", 0, 0)
  let response = Response::new(200, Headers::new(), stream)
  let buf = @buffer.new(size_hint=8)
  assert_eq(response.body_stream().read(buf).unwrap(), 5)
  assert_eq(buf.to_bytes(), b"hello")
}
