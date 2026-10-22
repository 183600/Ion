///|
fn response_copy_stream(input : Bytes) -> RegressionMockStream {
  RegressionMockStream::{
    input,
    offset: 0,
    output: @buffer.new(size_hint=16),
    max_read: 0,
    max_write: 0,
    is_open: true,
    last_timeout: 0,
  }
}

///|
/// A transfer coding before `chunked` is part of framing, so `copy_body_to`
/// must decode it even though `Content-Encoding` is deliberately left applied.
test "Response::copy_body_to decodes non-chunked transfer codings" {
  let compressed = inflate_bytes_of([
    31, 139, 8, 0, 57, 223, 215, 106, 2, 255, 203, 72, 205, 201, 201, 7, 0, 134,
    166, 16, 54, 5, 0, 0, 0,
  ])
  let response = Response::new(
    200,
    Headers::new().set("Transfer-Encoding", "gzip, chunked"),
    response_copy_stream(compressed),
  )
  let sink = response_copy_stream(b"")
  assert_eq(response.copy_body_to(sink).unwrap(), 5)
  assert_eq(@utf8.decode_lossy(sink.output.to_bytes()[:]), "hello")
}

///|
test "Response::copy_body_to rejects an unsupported transfer coding" {
  let response = Response::new(
    200,
    Headers::new().set("Transfer-Encoding", "compress, chunked"),
    response_copy_stream(b"payload"),
  )
  let sink = response_copy_stream(b"")
  match response.copy_body_to(sink) {
    Ok(_) => fail("unsupported transfer coding was copied as a body")
    Err(err) =>
      assert_eq(err, ProtocolError("unsupported Transfer-Encoding: compress"))
  }
  assert_eq(sink.output.to_bytes().length(), 0)
}
