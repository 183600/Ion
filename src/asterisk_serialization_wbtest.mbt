///|
test "an asterisk-form path still serializes as a URL" {
  let url = Url::parse("http://example.com").unwrap().with_path("*")
  assert_eq(url.request_target(), "*")
  assert_eq(url.to_string(), "http://example.com/*")
}

///|
test "asterisk-form rejects a query in both HTTP versions" {
  let url = Url::parse("http://example.com").unwrap()
    .with_path("*")
    .with_query("q=1")
  let h1 = H1Codec::new(regression_mock_stream("", 0, 0))
  match h1.encode_request(Request::new(OPTIONS, url)) {
    Ok(_) => fail("HTTP/1.1 asterisk-form with a query was accepted")
    Err(err) => assert_eq(err, InvalidUrl("Asterisk-form cannot include a query"))
  }
  match h2_request_headers(Request::new(OPTIONS, url)) {
    Ok(_) => fail("HTTP/2 asterisk-form with a query was accepted")
    Err(err) => assert_eq(err, InvalidUrl("Asterisk-form cannot include a query"))
  }
}
