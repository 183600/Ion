/// Transfer-Encoding is message framing, not representation metadata. The
/// response stream removes chunked framing; `read_body_decoded` must also undo
/// any other transfer codings before applying Content-Encoding.

fn transfer_response_stream(
  head : String,
  body : Bytes,
  tail : String,
) -> InflateMockStream {
  let input = Buffer(size_hint=head.length() + body.length() + tail.length())
  input.write_bytes(@utf8.encode(head))
  input.write_bytes(body)
  input.write_bytes(@utf8.encode(tail))
  InflateMockStream::{ input: input.to_bytes(), offset: 0 }
}

test "read_body_decoded applies gzip transfer coding before chunked framing" {
  // gzip("hello"), as produced by RFC 1952 with the standard header.
  let gzip_hello = Bytes::from_array([
    31, 139, 8, 0, 57, 223, 215, 106, 2, 255, 203, 72, 205, 201, 201, 7, 0,
    134, 166, 16, 54, 5, 0, 0, 0,
  ])
  let stream = transfer_response_stream(
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n19\r\n",
    gzip_hello,
    "\r\n0\r\n\r\n",
  )
  let response = H1Codec::new(stream).decode_response().unwrap()
  assert_eq(response.read_body_decoded().unwrap(), b"hello")
}

test "read_body_decoded applies deflate transfer coding" {
  // zlib("hello").
  let deflate_hello = Bytes::from_array([
    120, 218, 203, 72, 205, 201, 201, 7, 0, 6, 44, 2, 21,
  ])
  let stream = transfer_response_stream(
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: deflate, chunked\r\n\r\nd\r\n",
    deflate_hello,
    "\r\n0\r\n\r\n",
  )
  let response = H1Codec::new(stream).decode_response().unwrap()
  assert_eq(response.read_body_decoded().unwrap(), b"hello")
}

test "read_body_decoded bounds transfer-decoded output" {
  let gzip_hello = Bytes::from_array([
    31, 139, 8, 0, 57, 223, 215, 106, 2, 255, 203, 72, 205, 201, 201, 7, 0,
    134, 166, 16, 54, 5, 0, 0, 0,
  ])
  let stream = transfer_response_stream(
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n19\r\n",
    gzip_hello,
    "\r\n0\r\n\r\n",
  )
  let response = H1Codec::new(stream).decode_response().unwrap()
  assert_true(response.read_body_decoded_with_limit(4) is Err(_))
}

test "read_body_decoded rejects unsupported transfer codings" {
  let stream = transfer_response_stream(
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: compress, chunked\r\n\r\n5\r\n",
    @utf8.encode("hello"),
    "\r\n0\r\n\r\n",
  )
  let response = H1Codec::new(stream).decode_response().unwrap()
  match response.read_body_decoded() {
    Ok(_) => fail("unsupported transfer coding was silently returned")
    Err(err) =>
      assert_eq(err, ProtocolError("unsupported Transfer-Encoding: compress"))
  }
}

test "read_body_decoded applies close-delimited transfer codings" {
  let gzip_hello_world = Bytes::from_array([
    31, 139, 8, 0, 0, 0, 0, 0, 2, 3, 203, 72, 205, 201, 201, 87, 40, 207, 47,
    202, 73, 1, 0, 133, 17, 74, 13, 11, 0, 0, 0,
  ])
  let raw_stream = transfer_response_stream(
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\n\r\n",
    gzip_hello_world,
    "",
  )
  let raw_response = H1Codec::new(raw_stream).decode_response().unwrap()
  assert_eq(raw_response.read_body().unwrap(), gzip_hello_world)

  let stream = transfer_response_stream(
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\n\r\n",
    gzip_hello_world,
    "",
  )
  let response = H1Codec::new(stream).decode_response().unwrap()
  assert_eq(response.read_body_decoded().unwrap(), b"hello world")

  let deflate_hello = Bytes::from_array([
    120, 218, 203, 72, 205, 201, 201, 7, 0, 6, 44, 2, 21,
  ])
  let stream = transfer_response_stream(
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: deflate\r\n\r\n",
    deflate_hello,
    "",
  )
  let response = H1Codec::new(stream).decode_response().unwrap()
  assert_eq(response.read_body_decoded().unwrap(), b"hello")
}

test "read_body_decoded rejects an unsupported close-delimited transfer coding" {
  let stream = transfer_response_stream(
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: compress\r\n\r\n",
    @utf8.encode("hello"),
    "",
  )
  let response = H1Codec::new(stream).decode_response().unwrap()
  match response.read_body_decoded() {
    Ok(_) => fail("unsupported close-delimited transfer coding was returned raw")
    Err(err) =>
      assert_eq(err, ProtocolError("unsupported Transfer-Encoding: compress"))
  }
}

test "identity transfer coding before chunked leaves the body unchanged" {
  let stream = transfer_response_stream(
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: identity, chunked\r\n\r\n5\r\n",
    @utf8.encode("hello"),
    "\r\n0\r\n\r\n",
  )
  let response = H1Codec::new(stream).decode_response().unwrap()
  assert_eq(response.read_body_decoded().unwrap(), b"hello")
}

test "non-final chunked coding remains close-delimited when decoded" {
  let stream = transfer_response_stream(
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked, gzip\r\n\r\n",
    @utf8.encode("5\r\nhello\r\n0\r\n\r\n"),
    "",
  )
  let response = H1Codec::new(stream).decode_response().unwrap()
  assert_eq(
    response.read_body_decoded().unwrap(),
    @utf8.encode("5\r\nhello\r\n0\r\n\r\n"),
  )
}

test "read_body_decoded accepts the legacy x-deflate alias" {
  // zlib("hello"), as produced by the historical x-deflate coding.
  let deflate_hello = Bytes::from_array([
    120, 218, 203, 72, 205, 201, 201, 7, 0, 6, 44, 2, 21,
  ])
  let encoded = Response::new(
    200,
    Headers::new().set("Content-Encoding", "x-deflate"),
    response_copy_stream(deflate_hello),
  )
  assert_eq(encoded.read_body_decoded().unwrap(), b"hello")
  let transfer = transfer_response_stream(
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: x-deflate, chunked\r\n\r\nd\r\n",
    deflate_hello,
    "\r\n0\r\n\r\n",
  )
  let response = H1Codec::new(transfer).decode_response().unwrap()
  assert_eq(response.read_body_decoded().unwrap(), b"hello")
}

test "empty bodies still reject unsupported x-deflate-looking codings" {
  let response = Response::new(
    200,
    Headers::new().set("Content-Encoding", "x-compress"),
    response_copy_stream(b""),
  )
  match response.read_body_decoded() {
    Ok(_) => fail("unsupported coding was accepted for an empty body")
    Err(err) =>
      assert_eq(err, ProtocolError("unsupported Content-Encoding: x-compress"))
  }
}

