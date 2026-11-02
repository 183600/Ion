///|
test "Request::with_url replaces only the target" {
  let url = Url::parse("http://example.com/original").unwrap()
  let moved = Request::new(POST, url)
    .with_header("X-Test", "value")
    .with_body(b"body")
    .with_url(Url::parse("https://other.example/next?q=1").unwrap())
  assert_eq(moved.verb, POST)
  assert_eq(moved.url.to_string(), "https://other.example/next?q=1")
  assert_eq(moved.get_header("X-Test"), Some("value"))
  assert_eq(moved.body, Some(b"body"))
}

///|
test "Request::with_bearer_auth replaces existing authorization" {
  let url = Url::parse("https://example.com/").unwrap()
  let request = Request::new(GET, url)
    .with_header("Authorization", "Basic old")
    .with_bearer_auth("token-123")
  assert_eq(request.get_header("Authorization"), Some("Bearer token-123"))
  assert_eq(request.get_header_all("Authorization").length(), 1)
}
