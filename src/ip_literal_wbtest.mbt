///|
///|
test "IPvFuture literals accept every RFC 3986 address character" {
  for raw in [
    "http://[v1.hy,Af]/",
    "http://[vF.a-b_c~d!$&'()*+;=:]/",
  ] {
    let url = Url::parse(raw).unwrap()
    assert_true(url.bracketed)
  }
  let url = Url::parse("http://[v1.hy,Af]:8080/x").unwrap()
  assert_eq(url.host, "v1.hy,Af")
  assert_eq(url.authority(), "[v1.hy,Af]:8080")
  assert_eq(url.to_string(), "http://[v1.hy,Af]:8080/x")
  assert_true(
    H1Codec::new(regression_mock_stream("", 0, 0))
      .encode_request(
        Request::new(GET, url).with_header("Host", "[v1.hy,Af]:8080"),
      )
      is Ok(_),
  )
}

///|
test "IPv4 literals reject leading-zero octets" {
  for value in [
    "http://[::ffff:192.168.001.1]/",
    "http://[::ffff:01.2.3.4]/",
    "http://[::ffff:1.2.3.04]/",
  ] {
    assert_true(Url::parse(value) is Err(_))
  }
  for value in [
    "http://[::ffff:192.168.1.1]/",
    "http://[::ffff:0.0.0.0]/",
    "http://[::ffff:255.255.255.255]/",
  ] {
    assert_true(Url::parse(value) is Ok(_))
  }
}
