///|
test "TRACE requests reject content in both HTTP versions" {
  let url = Url::parse("http://example.com/trace").unwrap()
  let request = Request::new(TRACE, url).with_body(b"payload")

  let stream = regression_mock_stream("", 0, 0)
  let h1 = H1Codec::new(stream)
  match h1.encode_request(request) {
    Ok(_) => fail("HTTP/1.1 TRACE content was accepted")
    Err(err) => assert_eq(
      err,
      InvalidHeader("TRACE request content is not allowed"),
    )
  }
  assert_eq(stream.output.to_bytes().length(), 0)

  match h2_request_headers(request) {
    Ok(_) => fail("HTTP/2 TRACE content was accepted")
    Err(err) => assert_eq(
      err,
      InvalidHeader("TRACE request content is not allowed"),
    )
  }
}

///|
test "TRACE requests reject trailers even with an empty body" {
  let url = Url::parse("http://example.com/trace").unwrap()
  let request = Request::new(TRACE, url).with_trailer("X-Done", "yes")

  let stream = regression_mock_stream("", 0, 0)
  match H1Codec::new(stream).encode_request(request) {
    Ok(_) => fail("HTTP/1.1 TRACE trailers were accepted")
    Err(err) => assert_eq(
      err,
      InvalidHeader("TRACE request content is not allowed"),
    )
  }

  match h2_request_headers(request) {
    Ok(_) => fail("HTTP/2 TRACE trailers were accepted")
    Err(err) => assert_eq(
      err,
      InvalidHeader("TRACE request content is not allowed"),
    )
  }
}
