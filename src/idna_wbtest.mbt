test "URL parses internationalized hosts as A-labels" {
  for (input, expected) in [
    ("http://例え.テスト/", "xn--r8jz45g.xn--zckzah"),
    ("https://bücher.example/", "xn--bcher-kva.example"),
    ("http://BÜCHER.Example/", "xn--bcher-kva.example"),
    ("http://中文.测试/", "xn--fiq228c.xn--0zwm56d"),
    ("http://münchen.de/", "xn--mnchen-3ya.de"),
    ("http://faß.de/", "xn--fa-hia.de"),
  ] {
    let url = Url::parse(input).unwrap()
    assert_eq(url.host, expected)
    assert_eq(url.authority(), expected)
  }
}

test "IDNA hosts are used by request serialization and TLS validation" {
  let url = Url::parse("https://例え.テスト/経路?q=中").unwrap()
  assert_eq(url.host, "xn--r8jz45g.xn--zckzah")
  assert_eq(url.path, "/経路")
  assert_eq(url.query, "q=中")
  assert_eq(
    url.to_string(),
    "https://xn--r8jz45g.xn--zckzah/経路?q=中",
  )
  TlsConfig::new(url.host).validate().unwrap()
  let stream = regression_mock_stream("", 0, 0)
  H1Codec::new(stream).encode_request(Request::new(GET, url)).unwrap()
  let wire = @utf8.decode(stream.output.to_bytes()[:])
  assert_true(wire.contains("Host: xn--r8jz45g.xn--zckzah\r\n"))
}

test "IDNA maps fullwidth characters and dot separators" {
  let dots = Url::parse("http://例え。テスト/").unwrap()
  assert_eq(dots.host, "xn--r8jz45g.xn--zckzah")
  let fullwidth = Url::parse("http://ｅｘａｍｐｌｅ．ｃｏｍ/").unwrap()
  assert_eq(fullwidth.host, "example.com")
  let trailing = Url::parse("http://例え.テスト./").unwrap()
  assert_eq(trailing.host, "xn--r8jz45g.xn--zckzah.")
}

test "Url::new and redirects normalize IDNA hosts" {
  let constructed = Url::new("https", "münchen.de", 443)
  assert_eq(constructed.host, "xn--mnchen-3ya.de")
  let base = Url::parse("http://例え.テスト/a/b").unwrap()
  let joined = base.join("https://中文.测试/").unwrap()
  assert_eq(joined.host, "xn--fiq228c.xn--0zwm56d")
  assert_eq(joined, Url::parse("https://中文.测试/").unwrap())
}

test "cookie Domain attributes accept IDNA spellings" {
  let url = Url::parse("https://例え.テスト/").unwrap()
  let jar = CookieJar::new()
  jar.store_at(url, "session=1; Domain=例え.テスト; Secure", 1000UL)
  assert_eq(jar.cookie_header_at(url, 1001UL), Some("session=1"))
  let ascii = Url::parse("https://xn--r8jz45g.xn--zckzah/").unwrap()
  assert_eq(jar.cookie_header_at(ascii, 1001UL), Some("session=1"))
}

test "percent-encoded UTF-8 host names use IDNA" {
  let encoded = Url::parse(
    "http://%E4%BE%8B%E3%81%88.%E3%83%86%E3%82%B9%E3%83%88/",
  ).unwrap()
  assert_eq(encoded.host, "xn--r8jz45g.xn--zckzah")
  let mixed = Url::parse("http://b%C3%BCcher.example/").unwrap()
  assert_eq(mixed.host, "xn--bcher-kva.example")
  for input in [
    "http://%FF.example/",
    "http://%C3.example/",
    "http://%E4%BE.example/",
  ] {
    assert_true(Url::parse(input) is Err(_))
  }
}

test "invalid IDNA hosts are rejected" {
  for input in [
    "http://例え..テスト/",
    "http://例え.テスト../",
    "http://.例え.テスト/",
    "http://例え%zz.テスト/",
    "http://例え\u{200B}.テスト/",
    "http://" + "é".repeat(63) + ".com/",
  ] {
    assert_true(Url::parse(input) is Err(_))
  }
}
