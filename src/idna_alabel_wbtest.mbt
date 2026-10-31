test "IDNA accepts canonical A-label hosts" {
  for (input, expected) in [
    ("http://xn--bcher-kva.example/", "xn--bcher-kva.example"),
    ("http://xn--r8jz45g.xn--zckzah/", "xn--r8jz45g.xn--zckzah"),
    ("http://xn--fa-hia.de/", "xn--fa-hia.de"),
    ("http://XN--BCHER-KVA.example/", "XN--BCHER-KVA.example"),
    ("http://example.xn--zckzah./", "example.xn--zckzah."),
  ] {
    let url = Url::parse(input).unwrap()
    assert_eq(url.host, expected)
  }
}

test "IDNA rejects malformed A-labels" {
  for input in [
    "http://xn--/",
    "http://xn--a.example/",
    "http://xn--abc-.example/",
    "http://xn--0.example/",
    "http://xn---.example/",
    "http://xn--a_b.example/",
    "http://" + "xn--" + "a".repeat(60) + ".example/",
    "http://例え.xn--abc-.example/",
  ] {
    assert_true(Url::parse(input) is Err(_))
  }
}
