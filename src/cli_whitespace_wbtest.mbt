///|
test "CLI trims whitespace around methods and URLs" {
  let request = parse_cli_args([
    "/usr/bin/feather",
    "  POST  ",
    "  https://example.com/submit  ",
    "  payload with spaces  ",
  ]).unwrap()
  assert_eq(request.method_text, "post")
  assert_eq(request.url, "https://example.com/submit")
  // Request bodies are data, not configuration, and must be preserved exactly.
  assert_eq(request.body, "  payload with spaces  ")
}

///|
test "CLI trims whitespace around URL-only arguments and help flags" {
  let request = parse_cli_args([
    "/usr/bin/feather",
    "  HTTP://example.com/path  ",
  ]).unwrap()
  assert_eq(request.method_text, "")
  assert_eq(request.url, "HTTP://example.com/path")
  assert_eq(request.body, "")
  assert_true(wants_help(["/usr/bin/feather", "  --help  "]))
}
