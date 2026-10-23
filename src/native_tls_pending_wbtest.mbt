#cfg(target="native")
fn pending_tls_handle() -> NativeTlsHandle {
  feather_tls_new(
    @utf8.encode("example.com"),
    b"",
    0,
    0,
    0,
    b"",
    0,
    b"",
    0,
    b"",
    0,
  )
}

/// A record dequeued from OpenSSL's write BIO must survive until the transport
/// confirms it was written. Otherwise a write timeout silently drops the tail
/// of a TLS record and a retry emits a corrupt stream.
#cfg(target="native")
test "native TLS retains dequeued record bytes until they are consumed" {
  let tls = pending_tls_handle()
  // Generate the ClientHello record without requiring a peer.
  let _ = feather_tls_handshake(tls)
  let capacity = 65536
  let first = Bytes::new(capacity)
  let length = feather_tls_receive_pending(tls, first, capacity)
  assert_true(length > 4)

  // Reading again without acknowledging anything returns the same prefix, so a
  // failed transport write cannot lose it.
  let repeated = Bytes::new(capacity)
  assert_eq(feather_tls_receive_pending(tls, repeated, capacity), length)
  assert_eq(repeated.exact_view(start=0, end=length), first.exact_view(start=0, end=length))

  assert_eq(feather_tls_consume_pending(tls, 2), 2)
  let tail = Bytes::new(capacity)
  let tail_length = feather_tls_receive_pending(tls, tail, capacity)
  assert_eq(tail_length, length - 2)
  assert_eq(
    tail.exact_view(start=0, end=tail_length),
    first.exact_view(start=2, end=length),
  )
  assert_eq(feather_tls_consume_pending(tls, tail_length), tail_length)

  let empty = Bytes::new(capacity)
  assert_eq(feather_tls_receive_pending(tls, empty, capacity), 0)
}
