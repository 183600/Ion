/// Equivalent textual forms of the same IPv6 address must share cookie
/// identity, otherwise a server using an expanded/uppercase spelling stores a
/// cookie that is invisible to requests using the compressed form.

test "equivalent IPv6 spellings share host-only cookie identity" {
  let jar = CookieJar::new()
  let expanded = Url::parse("http://[2001:0db8:0:0:0:0:0:1]/").unwrap()
  let compressed = Url::parse("http://[2001:db8::1]/").unwrap()
  let uppercase = Url::parse("http://[2001:DB8::1]/").unwrap()
  jar.store_at(expanded, "sid=first; Path=/", 1000)
  assert_eq(jar.cookie_header_at(compressed, 1000), Some("sid=first"))
  assert_eq(jar.cookie_header_at(uppercase, 1000), Some("sid=first"))

  // Replacing the cookie from another spelling must not create a duplicate.
  jar.store_at(compressed, "sid=second; Path=/", 1000)
  assert_eq(jar.length(), 1)
  assert_eq(jar.cookie_header_at(expanded, 1000), Some("sid=second"))
}

/// A zone identifier still distinguishes link-local authorities.
test "IPv6 cookie canonicalization preserves the zone identifier" {
  let jar = CookieJar::new()
  let zone1 = Url::parse("http://[fe80:0:0:0:0:0:0:1%25eth0]/").unwrap()
  let zone2 = Url::parse("http://[fe80::1%25eth1]/").unwrap()
  jar.store_at(zone1, "sid=zone0; Path=/", 1000)
  assert_eq(jar.cookie_header_at(zone1, 1000), Some("sid=zone0"))
  assert_eq(jar.cookie_header_at(zone2, 1000), None)
}
