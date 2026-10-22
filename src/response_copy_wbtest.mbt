///|
test "Response::copy_body_to streams a body into a sink" {
  let source = regression_mock_stream("hello world", 0, 0)
  let response = Response::new(200, Headers::new(), source)
  let sink = regression_mock_stream("", 0, 0)
  assert_eq(response.copy_body_to(sink).unwrap(), 11)
  assert_eq(@utf8.decode_lossy(sink.output.to_bytes()[:]), "hello world")
}

///|
test "Response::copy_body_to propagates sink write failures" {
  let source = regression_mock_stream("payload", 0, 0)
  let response = Response::new(200, Headers::new(), source)
  let sink = regression_mock_stream("", 0, 0)
  let _ = sink.close()
  match response.copy_body_to(sink) {
    Ok(_) => fail("failing sink accepted a response body")
    Err(_) => ()
  }
  assert_false(source.is_open)
}
