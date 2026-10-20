///|
test "CLI arguments skip the executable prefix" {
  let (method, url, body) = parse_cli_request([
    "/usr/bin/feather",
    "http://example.com/path",
  ])
  assert_eq(method, "")
  assert_eq(url, "http://example.com/path")
  assert_eq(body, "")
}

///|
test "CLI accepts a method, URL, and optional body" {
  let (method, url, body) = parse_cli_request([
    "/usr/bin/feather",
    "post",
    "https://example.com/submit",
    "payload",
  ])
  assert_eq(method, "post")
  assert_eq(url, "https://example.com/submit")
  assert_eq(body, "payload")
}

///|
test "CLI handles the no-argument case" {
  let (method, url, body) = parse_cli_request([])
  assert_eq(method, "")
  assert_eq(url, "")
  assert_eq(body, "")
}

///|
test "CLI methods map to their HTTP verbs" {
  for (text, verb) in [
    ("get", GET),
    ("post", POST),
    ("put", PUT),
    ("delete", DELETE),
    ("head", HEAD),
    ("options", OPTIONS),
    ("patch", PATCH),
  ] {
    assert_true(HttpMethod::parse(text) is Ok(_))
    assert_eq(HttpMethod::parse(text).unwrap(), verb)
  }
  assert_true(HttpMethod::parse("brew") is Err(InvalidMethod(_)))
}
