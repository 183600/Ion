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
