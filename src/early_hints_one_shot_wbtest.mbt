///|
test "one-shot responses retain informational headers" {
  let stream : &Stream = AutoDecompressMockStream::{
    input: b"ok",
    offset: 0,
    output: Buffer(size_hint=0),
  }
  let response = Response::new(
    200,
    Headers::new().set("Content-Length", "2"),
    stream,
  ).with_early_hints([
    (103, Headers::new().set("Link", "</style.css>; rel=preload")),
  ])
  let buffered = buffer_one_shot_response(UnifiedClient::new(), Ok(response)).unwrap()
  let hints = buffered.early_hints()
  assert_eq(hints.length(), 1)
  assert_eq(hints[0].0, 103)
  assert_eq(hints[0].1.get("Link"), Some("</style.css>; rel=preload"))
  assert_eq(buffered.read_body().unwrap(), b"ok")
}
