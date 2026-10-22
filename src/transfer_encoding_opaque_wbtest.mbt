/// A response whose `chunked` coding is not final is close-delimited and its
/// payload is opaque, but declared coding names must still be understood.
test "opaque non-final chunked coding rejects unsupported transfer codings" {
  for body in [b"", b"payload"] {
    let stream = transfer_response_stream(
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked, compress\r\n\r\n",
      body,
      "",
    )
    let response = H1Codec::new(stream).decode_response().unwrap()
    match response.read_body_decoded() {
      Ok(_) => fail("unsupported opaque transfer coding was returned raw")
      Err(err) =>
        assert_eq(err, ProtocolError("unsupported Transfer-Encoding: compress"))
    }
  }
}

test "copy_body_to rejects unsupported opaque transfer codings" {
  let stream = transfer_response_stream(
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked, compress\r\n\r\n",
    @utf8.encode("payload"),
    "",
  )
  let response = H1Codec::new(stream).decode_response().unwrap()
  let sink = response_copy_stream(b"")
  match response.copy_body_to(sink) {
    Ok(_) => fail("unsupported opaque transfer coding was copied")
    Err(err) =>
      assert_eq(err, ProtocolError("unsupported Transfer-Encoding: compress"))
  }
  assert_eq(sink.output.to_bytes().length(), 0)
}
