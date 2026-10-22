///|
test "CLI trims whitespace around methods and URLs" {
  let (method, url, body) = parse_cli_request([
    "/usr/bin/feather",
    "  POST  ",
    "  https://example.com/submit  ",
    "  payload with spaces  ",
  ])
  assert_eq(method, "post")
  assert_eq(url, "https://example.com/submit")
  // Request bodies are data, not configuration, and must be preserved exactly.
  assert_eq(body, "  payload with spaces  ")
}

///|
test "CLI trims whitespace around URL-only arguments and help flags" {
  let (method, url, body) = parse_cli_request([
    "/usr/bin/feather",
    "  HTTP://example.com/path  ",
  ])
  assert_eq(method, "")
  assert_eq(url, "HTTP://example.com/path")
  assert_eq(body, "")
  assert_true(wants_help(["/usr/bin/feather", "  --help  "]))
}
