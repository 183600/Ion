///|
test "CLI treats a lone non-URL argument as a method" {
  let (method, url, body) = parse_cli_request(["/usr/bin/feather", "post"])
  assert_eq(method, "post")
  assert_eq(url, "")
  assert_eq(body, "")
}

///|
test "CLI keeps method-only arguments case-insensitive" {
  let (method, url, body) = parse_cli_request(["/usr/bin/feather", "PATCH"])
  assert_eq(method, "patch")
  assert_eq(url, "")
  assert_eq(body, "")
}

///|
test "CLI does not mistake a lone URL for a method" {
  let (method, url, body) = parse_cli_request([
    "/usr/bin/feather",
    "HTTPS://example.com/x",
  ])
  assert_eq(method, "")
  assert_eq(url, "HTTPS://example.com/x")
  assert_eq(body, "")
}
