/// An empty encoded payload was already treated as empty by
/// `read_body_decoded`; `copy_body_to` must make the same decision instead of
/// trying to decode a zero-byte gzip member.
test "copy_body_to leaves an empty transfer-coded body empty" {
  let source = response_copy_stream(b"")
  let response = Response::new(
    200,
    Headers::new().set("Transfer-Encoding", "gzip, chunked"),
    source,
  )
  assert_eq(response.read_body_decoded().unwrap(), b"")
}

test "copy_body_to writes no bytes for an empty transfer-coded body" {
  let source = response_copy_stream(b"")
  let response = Response::new(
    200,
    Headers::new().set("Transfer-Encoding", "gzip, chunked"),
    source,
  )
  let sink = response_copy_stream(b"")
  assert_eq(response.copy_body_to(sink).unwrap(), 0)
  assert_eq(sink.output.to_bytes(), b"")
}

test "copy_body_to still rejects unsupported codings on an empty body" {
  let source = response_copy_stream(b"")
  let response = Response::new(
    200,
    Headers::new().set("Transfer-Encoding", "compress, chunked"),
    source,
  )
  let sink = response_copy_stream(b"")
  match response.copy_body_to(sink) {
    Ok(_) => fail("unsupported transfer coding was accepted")
    Err(err) =>
      assert_eq(err, ProtocolError("unsupported Transfer-Encoding: compress"))
  }
  assert_eq(sink.output.to_bytes(), b"")
}
