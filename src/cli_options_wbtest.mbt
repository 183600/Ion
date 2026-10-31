///|
test "CLI options parse method, repeated headers, and body" {
  let request = parse_cli_args([
    "/usr/bin/feather",
    "-X",
    "PATCH",
    "-H",
    "X-Test: one",
    "--header=Accept: application/json",
    "-d",
    "payload",
    "https://example.com/items",
  ]).unwrap()
  assert_eq(request.method_text, "patch")
  assert_eq(request.url, "https://example.com/items")
  assert_eq(request.body, "payload")
  assert_true(request.has_body)
  assert_eq(request.headers.length(), 2)
  let (first_name, first_value) = request.headers[0]
  assert_eq(first_name, "X-Test")
  assert_eq(first_value, "one")
  let (second_name, second_value) = request.headers[1]
  assert_eq(second_name, "Accept")
  assert_eq(second_value, "application/json")
}

///|
test "CLI data defaults to POST when no method is given" {
  let request = parse_cli_args([
    "/usr/bin/feather",
    "-d",
    "payload",
    "https://example.com/submit",
  ]).unwrap()
  assert_eq(request.method_text, "post")
  assert_eq(request.body, "payload")
  assert_true(request.has_body)
}

///|
test "CLI explicit method wins over the data default" {
  let request = parse_cli_args([
    "/usr/bin/feather",
    "-X",
    "GET",
    "-d",
    "payload",
    "https://example.com/query",
  ]).unwrap()
  assert_eq(request.method_text, "get")
  assert_eq(request.body, "payload")
}

///|
test "CLI flags configure redirects, timeout, and HTTP version" {
  let request = parse_cli_args([
    "/usr/bin/feather",
    "--no-location",
    "--max-redirects",
    "3",
    "--timeout=1500",
    "--http1.1",
    "https://example.com/",
  ]).unwrap()
  assert_false(request.follow_redirects)
  assert_eq(request.max_redirects, 3)
  assert_eq(request.timeout_ms, 1500)
  assert_false(request.http2)
}

///|
test "CLI head option selects HEAD" {
  let request = parse_cli_args([
    "/usr/bin/feather",
    "-I",
    "https://example.com/",
  ]).unwrap()
  assert_eq(request.method_text, "head")
}

///|
test "CLI double dash allows a body beginning with a dash" {
  let request = parse_cli_args([
    "/usr/bin/feather",
    "post",
    "https://example.com/",
    "--",
    "-d",
  ]).unwrap()
  assert_eq(request.method_text, "post")
  assert_eq(request.body, "-d")
  assert_true(request.has_body)
}

///|
test "CLI help is recognized after the URL" {
  let request = parse_cli_args([
    "/usr/bin/feather",
    "https://example.com/",
    "--help",
  ]).unwrap()
  assert_true(request.help)
}

///|
test "CLI rejects unknown options" {
  assert_true(parse_cli_args([
    "/usr/bin/feather",
    "--bogus",
    "https://example.com/",
  ]) is Err(_))
}

///|
test "CLI rejects malformed headers" {
  assert_true(parse_cli_args([
    "/usr/bin/feather",
    "-H",
    "MissingColon",
    "https://example.com/",
  ]) is Err(_))
}

///|
test "CLI rejects options without required values" {
  assert_true(parse_cli_args(["/usr/bin/feather", "-X"]) is Err(_))
  assert_true(parse_cli_args([
    "/usr/bin/feather",
    "--max-redirects",
  ]) is Err(_))
}

///|
test "CLI rejects negative numeric options" {
  assert_true(parse_cli_args([
    "/usr/bin/feather",
    "--max-redirects",
    "-1",
    "https://example.com/",
  ]) is Err(_))
  assert_true(parse_cli_args([
    "/usr/bin/feather",
    "--timeout",
    "-5",
    "https://example.com/",
  ]) is Err(_))
}

///|
test "CLI TLS options override environment-derived settings" {
  let request = parse_cli_args([
    "/usr/bin/feather",
    "-k",
    "--ca",
    "ca.pem",
    "--client-cert=cert.pem",
    "--client-key",
    "key.pem",
    "--keylog",
    "https://example.com/",
  ]).unwrap()
  assert_eq(request.tls.insecure, Some(true))
  assert_eq(request.tls.ca_path, Some("ca.pem"))
  assert_eq(request.tls.client_cert, Some("cert.pem"))
  assert_eq(request.tls.client_key, Some("key.pem"))
  assert_eq(request.tls.key_log, Some(true))
}

///|
test "CLI can explicitly disable key logging" {
  let request = parse_cli_args([
    "/usr/bin/feather",
    "--no-keylog",
    "https://example.com/",
  ]).unwrap()
  assert_eq(request.tls.key_log, Some(false))
  assert_eq(request.tls.insecure, None)
}

///|
test "CLI rejects TLS options without required values" {
  assert_true(parse_cli_args([
    "/usr/bin/feather",
    "--ca",
  ]) is Err(_))
  assert_true(parse_cli_args([
    "/usr/bin/feather",
    "--ca=",
    "https://example.com/",
  ]) is Err(_))
  assert_true(parse_cli_args([
    "/usr/bin/feather",
    "--client-cert",
  ]) is Err(_))
  assert_true(parse_cli_args([
    "/usr/bin/feather",
    "--client-key",
  ]) is Err(_))
}
