///|
test "CLI treats a lone non-URL argument as a method" {
  let request = parse_cli_args(["/usr/bin/feather", "post"]).unwrap()
  assert_eq(request.method_text, "post")
  assert_eq(request.url, "")
  assert_eq(request.body, "")
}

///|
test "CLI keeps method-only arguments case-insensitive" {
  let request = parse_cli_args(["/usr/bin/feather", "PATCH"]).unwrap()
  assert_eq(request.method_text, "patch")
  assert_eq(request.url, "")
  assert_eq(request.body, "")
}

///|
test "CLI does not mistake a lone URL for a method" {
  let request = parse_cli_args([
    "/usr/bin/feather",
    "HTTPS://example.com/x",
  ]).unwrap()
  assert_eq(request.method_text, "")
  assert_eq(request.url, "HTTPS://example.com/x")
  assert_eq(request.body, "")
}
