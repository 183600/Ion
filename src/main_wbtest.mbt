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
test "CLI preserves extension method spelling" {
  let (method, url, body) = parse_cli_request([
    "/usr/bin/feather",
    "PROPFIND",
    "https://example.com/dav",
    "depth",
  ])
  assert_eq(method, "PROPFIND")
  assert_eq(url, "https://example.com/dav")
  assert_eq(body, "depth")
  assert_eq(HttpMethod::custom(method).unwrap(), Custom("PROPFIND"))
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

///|
test "TLS config carries a key-log sink" {
  let capturing = CapturingKeyLogSink::{ lines: [] }
  let config = TlsConfig::new("example.com").with_key_log(capturing)
  assert_true(config.key_log is Some(_))
  capturing.log("CLIENT_RANDOM", @utf8.encode("CLIENT_RANDOM abc def"))
  assert_eq(capturing.lines.length(), 1)
  assert_eq(capturing.lines[0], "CLIENT_RANDOM abc def")
}

///|
test "the print key-log sink can be constructed" {
  let sink : &KeyLogSink = PrintKeyLogSink::{}
  sink.log("LABEL", @utf8.encode("LABEL x y"))
}

///|
struct CapturingKeyLogSink {
  lines : Array[String]
}

///|
impl KeyLogSink for CapturingKeyLogSink with fn log(
  self : CapturingKeyLogSink,
  environment : String,
  keylog : Bytes,
) -> Unit {
  let _ = environment
  self.lines.push(@utf8.decode_lossy(keylog))
}

///|
test "CLI reports response body read errors" {
  let response = Response::new(200, Headers::new(), ReadErrorStream::{ is_open: true })
  assert_false(print_response(response))
}
