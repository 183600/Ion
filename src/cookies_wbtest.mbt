///|
fn cookie_test_url(url : String) -> Url {
  Url::parse(url).unwrap()
}

///|
test "cookie jar stores host-only cookies" {
  let jar = CookieJar::new()
  let origin = cookie_test_url("http://example.com/account/login")
  jar.store_at(origin, "session=abc123; Path=/; HttpOnly", 1000)
  assert_eq(jar.length(), 1)
  assert_eq(
    jar.cookie_header_at(cookie_test_url("http://example.com/dashboard"), 1000),
    Some("session=abc123"),
  )
  assert_eq(
    jar.cookie_header_at(
      cookie_test_url("http://other.example/dashboard"),
      1000,
    ),
    None,
  )
  assert_eq(
    jar.cookie_header_at(cookie_test_url("https://example.com/dashboard"), 1000),
    Some("session=abc123"),
  )
}

///|
test "cookie jar honors the Domain attribute" {
  let jar = CookieJar::new()
  jar.store_at(
    cookie_test_url("http://www.example.com/"),
    "id=1; Domain=.example.com; Path=/",
    1000,
  )
  assert_eq(
    jar.cookie_header_at(cookie_test_url("http://api.example.com/x"), 1000),
    Some("id=1"),
  )
  assert_eq(
    jar.cookie_header_at(cookie_test_url("http://example.com/x"), 1000),
    Some("id=1"),
  )
  assert_eq(
    jar.cookie_header_at(cookie_test_url("http://badexample.com/x"), 1000),
    None,
  )
  // A response must not be able to set cookies for an unrelated domain.
  jar.store_at(
    cookie_test_url("http://example.com/"),
    "id=2; Domain=evil.example; Path=/",
    1000,
  )
  assert_eq(jar.length(), 1)
}

///|
test "cookie jar matches request paths" {
  let jar = CookieJar::new()
  jar.store_at(cookie_test_url("http://example.com/a/b"), "p=1; Path=/a", 1000)
  jar.store_at(cookie_test_url("http://example.com/a/b"), "q=2; Path=/a/", 1000)
  assert_eq(
    jar.cookie_header_at(cookie_test_url("http://example.com/a"), 1000),
    Some("p=1"),
  )
  assert_eq(
    jar.cookie_header_at(cookie_test_url("http://example.com/a/b/c"), 1000),
    Some("q=2; p=1"),
  )
  assert_eq(
    jar.cookie_header_at(cookie_test_url("http://example.com/abc"), 1000),
    None,
  )
  assert_eq(
    jar.cookie_header_at(cookie_test_url("http://example.com/a2"), 1000),
    None,
  )
}

///|
test "cookie jar only sends Secure cookies over HTTPS" {
  let jar = CookieJar::new()
  jar.store_at(
    cookie_test_url("https://example.com/"),
    "token=secret; Secure; Path=/",
    1000,
  )
  assert_eq(
    jar.cookie_header_at(cookie_test_url("https://example.com/x"), 1000),
    Some("token=secret"),
  )
  assert_eq(
    jar.cookie_header_at(cookie_test_url("http://example.com/x"), 1000),
    None,
  )
}

///|
test "non-secure origins cannot set Secure cookies" {
  let jar = CookieJar::new()
  jar.store_at(
    cookie_test_url("http://example.com/"),
    "token=secret; Secure; Path=/",
    1000,
  )
  assert_eq(jar.length(), 0)
  jar.store_at(
    cookie_test_url("https://example.com/"),
    "token=secret; Secure; Path=/",
    1000,
  )
  assert_eq(
    jar.cookie_header_at(cookie_test_url("https://example.com/x"), 1000),
    Some("token=secret"),
  )
}

///|
test "non-secure origins cannot overwrite Secure cookies" {
  let jar = CookieJar::new()
  let secure = cookie_test_url("https://example.com/")
  let plain = cookie_test_url("http://example.com/")
  jar.store_at(secure, "token=secret; Secure; Path=/", 1000)
  jar.store_at(plain, "token=attacker; Path=/", 1000)
  assert_eq(
    jar.cookie_header_at(secure, 1000),
    Some("token=secret"),
  )
  jar.store_at(plain, "token=; Max-Age=0; Path=/", 1000)
  assert_eq(
    jar.cookie_header_at(secure, 1000),
    Some("token=secret"),
  )
  assert_eq(jar.length(), 1)
}

///|
test "host-only changes cannot bypass Secure cookie protection" {
  let jar = CookieJar::new()
  let secure = cookie_test_url("https://example.com/")
  let plain = cookie_test_url("http://example.com/")
  // A domain-scoped Secure cookie...
  jar.store_at(secure, "token=secret; Secure; Domain=example.com; Path=/", 1000)
  // ...must still block a non-secure host-only cookie in the same slot.
  jar.store_at(plain, "token=attacker; Path=/", 1000)
  assert_eq(jar.cookie_header_at(secure, 1000), Some("token=secret"))
  assert_eq(jar.length(), 1)

  let jar = CookieJar::new()
  // The reverse direction: a host-only Secure cookie blocks a domain cookie.
  jar.store_at(secure, "token=secret; Secure; Path=/", 1000)
  jar.store_at(plain, "token=attacker; Domain=example.com; Path=/", 1000)
  assert_eq(jar.cookie_header_at(secure, 1000), Some("token=secret"))
  assert_eq(jar.length(), 1)
}

///|
test "expired Secure cookies can be replaced from non-secure origins" {
  let jar = CookieJar::new()
  let secure = cookie_test_url("https://example.com/")
  let plain = cookie_test_url("http://example.com/")
  jar.store_at(secure, "token=old; Secure; Max-Age=1; Path=/", 1000)
  jar.store_at(plain, "token=new; Path=/", 2000)
  assert_eq(
    jar.cookie_header_at(secure, 2000),
    Some("token=new"),
  )
  assert_eq(jar.length(), 1)
}

///|
test "cookie jar honors Max-Age and deletes expired cookies" {
  let jar = CookieJar::new()
  jar.store_at(
    cookie_test_url("http://example.com/"),
    "m=1; Max-Age=2; Path=/",
    1000,
  )
  assert_eq(
    jar.cookie_header_at(cookie_test_url("http://example.com/x"), 2999),
    Some("m=1"),
  )
  assert_eq(
    jar.cookie_header_at(cookie_test_url("http://example.com/x"), 3000),
    None,
  )
  jar.store_at(cookie_test_url("http://example.com/"), "m=2; Path=/", 4000)
  assert_eq(
    jar.cookie_header_at(cookie_test_url("http://example.com/x"), 4000),
    Some("m=2"),
  )
  jar.store_at(
    cookie_test_url("http://example.com/"),
    "m=; Max-Age=0; Path=/",
    5000,
  )
  assert_eq(jar.length(), 0)
  assert_eq(
    jar.cookie_header_at(cookie_test_url("http://example.com/x"), 5000),
    None,
  )
}

///|
test "Max-Age values beyond Int32 are honored" {
  let url = cookie_test_url("http://example.com/")
  let jar = CookieJar::new()
  jar.store_at(url, "m=1; Max-Age=2147483648; Path=/", 1000)
  let expires_at : UInt64 = 2147483649000L.to_uint64()
  assert_eq(jar.cookie_header_at(url, expires_at - 1), Some("m=1"))
  assert_eq(jar.cookie_header_at(url, expires_at), None)

  let jar = CookieJar::new()
  jar.store_at(url, "m=1; Max-Age=999999999999999999999999; Path=/", 1000)
  match jar.cookies().head() {
    Some(cookie) =>
      assert_eq(cookie.expires_at_ms, Some(0xFFFFFFFFFFFFFFFFUL))
    None => fail("huge Max-Age should keep the cookie")
  }

  let jar = CookieJar::new()
  jar.store_at(url, "m=1; Max-Age=2147483648; Path=/", 1000)
  jar.store_at(url, "m=; Max-Age=-999999999999999999999; Path=/", 1000)
  assert_eq(jar.cookie_header_at(url, 1000), None)
}

///|
test "cookie jar parses Expires dates in the standard formats" {
  let jar = CookieJar::new()
  jar.store_at(
    cookie_test_url("http://example.com/"),
    "a=1; Expires=Wed, 21 Oct 2026 07:28:00 GMT; Path=/",
    0,
  )
  jar.store_at(
    cookie_test_url("http://example.com/"),
    "b=2; Expires=Saturday, 06-Nov-27 08:49:37 GMT; Path=/",
    0,
  )
  jar.store_at(
    cookie_test_url("http://example.com/"),
    "c=3; Expires=Sat Nov  6 08:49:37 2027; Path=/",
    0,
  )
  let expiry : UInt64 = 1792567680000L.to_uint64()
  assert_eq(
    jar.cookie_header_at(cookie_test_url("http://example.com/x"), expiry - 1),
    Some("a=1; b=2; c=3"),
  )
  assert_eq(
    jar.cookie_header_at(cookie_test_url("http://example.com/x"), expiry),
    Some("b=2; c=3"),
  )
}

///|
test "cookie jar ignores malformed cookies" {
  let jar = CookieJar::new()
  let url = cookie_test_url("http://example.com/")
  jar.store_at(url, "=missing-name; Path=/", 1000)
  jar.store_at(url, "bad name=value; Path=/", 1000)
  jar.store_at(url, "bad=value\r\nInjected: yes; Path=/", 1000)
  jar.store_at(url, "bad; Path=/", 1000)
  assert_eq(jar.length(), 0)
}

///|
test "cookie jar ignores oversized cookies" {
  let jar = CookieJar::new()
  let url = cookie_test_url("http://example.com/")
  let largest = "b=" + "b".repeat(4094)
  assert_eq(@utf8.encode(largest).length(), 4096)
  jar.store_at(url, largest, 1000)
  assert_eq(jar.length(), 1)

  jar.store_at(url, "token=old; Path=/", 1000)
  let oversized = "token=" + "a".repeat(4096)
  assert_true(@utf8.encode(oversized).length() > 4096)
  jar.store_at(url, oversized, 1000)
  assert_eq(
    jar.cookie_header_at(cookie_test_url("http://example.com/x"), 1000),
    Some("b=" + "b".repeat(4094) + "; token=old"),
  )
  assert_eq(jar.length(), 2)
}

///|
test "UnifiedClient replays stored cookies on later requests" {
  let raw = "HTTP/1.1 200 OK\r\nSet-Cookie: sid=xyz; Path=/\r\nContent-Length: 2\r\n\r\nok" +
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
  let stream = regression_mock_stream(raw, 1, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0, }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let client = UnifiedClient::{
    connector,
    options: ClientOptions::new().with_follow_redirects(false),
    redirect_count: 0,
  }.with_cookies()
  let first = client.get("http://example.com/set").unwrap()
  assert_eq(first.read_body().unwrap(), b"ok")
  let second = client.get("http://example.com/next").unwrap()
  assert_eq(second.read_body().unwrap(), b"ok")
  let wire = @utf8.decode(stream.output.to_bytes()[:])
  let second_index = wire.find("GET /next HTTP/1.1").unwrap()
  let second_request = wire.substring(start=second_index)
  assert_true(second_request.contains("Cookie: sid=xyz"))
  assert_eq(client.cookie_jar().length(), 1)
}

test "UnifiedClient preserves explicit cookies across same-origin redirects" {
  let raw = "HTTP/1.1 302 Found\r\nLocation: /next\r\nSet-Cookie: sid=jar; Path=/\r\nContent-Length: 0\r\n\r\n" +
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
  let stream = regression_mock_stream(raw, 1, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let client = UnifiedClient::{
    connector,
    options: ClientOptions::new(),
    redirect_count: 0,
  }.with_cookies()
  let response = client.request(
    Request::new(GET, cookie_test_url("http://example.com/start"))
      .with_header("Cookie", "manual=1"),
  ).unwrap()
  assert_eq(response.read_body().unwrap(), b"ok")
  let wire = @utf8.decode(stream.output.to_bytes()[:])
  let next_index = wire.find("GET /next HTTP/1.1").unwrap()
  let second_request = wire.substring(start=next_index)
  assert_true(second_request.contains("Cookie: manual=1"))
  assert_false(second_request.contains("Cookie: sid=jar"))
}

test "jar cookies are not replayed across redirect origins" {
  let raw = "HTTP/1.1 302 Found\r\nLocation: http://other.example/next\r\nSet-Cookie: sid=secret; Path=/\r\nContent-Length: 0\r\n\r\n" +
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
  let stream = regression_mock_stream(raw, 1, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let client = UnifiedClient::{
    connector,
    options: ClientOptions::new(),
    redirect_count: 0,
  }.with_cookies()
  let response = client.get("http://example.com/start").unwrap()
  assert_eq(response.read_body().unwrap(), b"ok")
  let wire = @utf8.decode(stream.output.to_bytes()[:])
  let next_index = wire.find("GET /next HTTP/1.1").unwrap()
  let second_request = wire.substring(start=next_index)
  assert_true(second_request.contains("Host: other.example"))
  assert_false(second_request.contains("Cookie:"))
}

test "redirect responses can set cookies for the next hop" {
  let raw = "HTTP/1.1 302 Found\r\nLocation: /next\r\nSet-Cookie: sid=jar; Path=/\r\nContent-Length: 0\r\n\r\n" +
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
  let stream = regression_mock_stream(raw, 1, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let client = UnifiedClient::{
    connector,
    options: ClientOptions::new(),
    redirect_count: 0,
  }.with_cookies()
  let response = client.get("http://example.com/start").unwrap()
  assert_eq(response.read_body().unwrap(), b"ok")
  let wire = @utf8.decode(stream.output.to_bytes()[:])
  let next_index = wire.find("GET /next HTTP/1.1").unwrap()
  let second_request = wire.substring(start=next_index)
  assert_true(second_request.contains("Cookie: sid=jar"))
}

test "updating a cookie preserves its creation order" {
  let jar = CookieJar::new()
  let url = cookie_test_url("http://example.com/")
  jar.store_at(url, "a=1; Path=/", 1000)
  jar.store_at(url, "b=2; Path=/", 1000)
  jar.store_at(url, "a=3; Path=/", 1000)
  assert_eq(
    jar.cookie_header_at(cookie_test_url("http://example.com/x"), 1000),
    Some("a=3; b=2"),
  )
}

test "RFC 850 expiry dates are applied" {
  let jar = CookieJar::new()
  let url = cookie_test_url("http://example.com/")
  jar.store_at(
    url,
    "old=1; Expires=Saturday, 06-Nov-27 08:49:37 GMT; Path=/",
    0,
  )
  let expires_at : UInt64 = 1825490977000L.to_uint64()
  assert_eq(
    jar.cookie_header_at(url, expires_at - 1),
    Some("old=1"),
  )
  assert_eq(jar.cookie_header_at(url, expires_at), None)
}

test "RFC 850 expiry dates without GMT are applied" {
  let jar = CookieJar::new()
  let url = cookie_test_url("http://example.com/")
  jar.store_at(url, "old=1; Expires=06-Nov-27 08:49:37; Path=/", 0)
  let expires_at : UInt64 = 1825490977000L.to_uint64()
  assert_eq(jar.cookie_header_at(url, expires_at - 1), Some("old=1"))
  assert_eq(jar.cookie_header_at(url, expires_at), None)
}

test "single-digit year tokens do not satisfy the year production" {
  let jar = CookieJar::new()
  let url = cookie_test_url("http://example.com/")
  jar.store_at(url, "y=1; Expires=Wed, 01 Jan 5 00:00:00 GMT; Path=/", 0)
  // RFC 6265 requires 2-4 digits for a year, so "5" is not a year and the
  // cookie remains a session cookie.
  let after_2030 : UInt64 = 2000000000000L.to_uint64()
  assert_eq(jar.cookie_header_at(url, after_2030), Some("y=1"))
}

test "leading-zero expiry years are normalized by value" {
  let jar = CookieJar::new()
  let url = cookie_test_url("http://example.com/")
  jar.store_at(url, "y=1; Expires=Wed, 01 Jan 069 00:00:00 GMT; Path=/", 0)
  let expires_at : UInt64 = 3124224000000L.to_uint64()
  assert_eq(jar.cookie_header_at(url, expires_at - 1), Some("y=1"))
  assert_eq(jar.cookie_header_at(url, expires_at), None)

  let jar = CookieJar::new()
  jar.store_at(url, "y=1; Expires=Wed, 01 Jan 070 00:00:00 GMT; Path=/", 0)
  assert_eq(jar.cookie_header_at(url, 1000), None)

  let jar = CookieJar::new()
  jar.store_at(url, "y=1; Expires=Wed, 01 Jan 0005 00:00:00 GMT; Path=/", 0)
  let expires_at : UInt64 = 1104537600000L.to_uint64()
  assert_eq(jar.cookie_header_at(url, expires_at - 1), Some("y=1"))
  assert_eq(jar.cookie_header_at(url, expires_at), None)
}

test "expiry years longer than four digits are ignored" {
  let jar = CookieJar::new()
  let url = cookie_test_url("http://example.com/")
  jar.store_at(url, "y=1; Expires=Wed, 01 Jan 02026 00:00:00 GMT; Path=/", 0)
  match jar.cookies().head() {
    Some(cookie) => assert_eq(cookie.expires_at_ms, None)
    None => fail("cookie with an invalid expiry year should remain a session cookie")
  }
}

test "cookie expiry dates accept RFC date delimiters and token order" {
  let jar = CookieJar::new()
  let url = cookie_test_url("http://example.com/")
  let expiry : UInt64 = 1792567680000L.to_uint64()
  for value in [
    "a=1; Expires=Wed,\t21-Oct-2026\t07:28:00\tGMT; Path=/",
    "b=2; Expires=07:28:00,2026-Oct-21; Path=/",
    "c=3; Expires=2026/October/21 07:28:00 GMT; Path=/",
  ] {
    jar.store_at(url, value, 0)
  }
  assert_eq(
    jar.cookie_header_at(url, expiry - 1),
    Some("a=1; b=2; c=3"),
  )
  assert_eq(jar.cookie_header_at(url, expiry), None)
}

test "cookie expiry dates ignore unknown tokens" {
  let jar = CookieJar::new()
  let url = cookie_test_url("http://example.com/")
  jar.store_at(
    url,
    "extra=1; Expires=Wed, 21 Oct 2026 07:28:00 junk; Path=/",
    0,
  )
  let after_2030 : UInt64 = 2000000000000L.to_uint64()
  assert_eq(jar.cookie_header_at(url, after_2030), None)
}

test "cookie expiry ignores weekday tokens anywhere in the date" {
  let jar = CookieJar::new()
  let url = cookie_test_url("http://example.com/")
  jar.store_at(
    url,
    "mid=1; Expires=09 Mon Jun 2021 10:00:00 GMT; Path=/",
    0,
  )
  let after_2030 : UInt64 = 2000000000000L.to_uint64()
  assert_eq(jar.cookie_header_at(url, after_2030), None)
}

test "cookie expiry accepts RFC date token suffixes" {
  let jar = CookieJar::new()
  let url = cookie_test_url("http://example.com/")
  let expiry : UInt64 = 1789975680000L.to_uint64()
  jar.store_at(
    url,
    "suffix=1; Expires=Wed, 21st Sept 2026 07:28:00GMT; Path=/",
    0,
  )
  assert_eq(jar.cookie_header_at(url, expiry - 1), Some("suffix=1"))
  assert_eq(jar.cookie_header_at(url, expiry), None)
}

test "pre-epoch expiry dates delete cookies" {
  let jar = CookieJar::new()
  let url = cookie_test_url("http://example.com/")
  jar.store_at(url, "old=1; Expires=Wed, 01 Jan 1969 00:00:00 GMT; Path=/", 0)
  assert_eq(jar.cookie_header_at(url, 0), None)
}

test "cookie values must use RFC 6265 cookie-octets" {
  let jar = CookieJar::new()
  let url = cookie_test_url("http://example.com/")
  for value in [
    "bad=space value",
    "bad=comma,value",
    "bad=quote\"value",
    "bad=back\\slash",
    "bad=caf\u{e9}",
  ] {
    jar.store_at(url, value, 1000)
  }
  assert_eq(jar.length(), 0)
  jar.store_at(url, "quoted=\"value\"", 1000)
  jar.store_at(url, "empty=", 1000)
  jar.store_at(url, "equals=a=b", 1000)
  assert_eq(
    jar.cookie_header_at(url, 1000),
    Some("quoted=\"value\"; empty=; equals=a=b"),
  )
}

test "an empty Domain attribute leaves the cookie host-only" {
  let jar = CookieJar::new()
  let url = cookie_test_url("http://example.com/")
  jar.store_at(url, "sid=1; Domain=; Path=/", 1000)
  assert_eq(jar.cookie_header_at(url, 1000), Some("sid=1"))
  assert_eq(
    jar.cookie_header_at(cookie_test_url("http://sub.example.com/"), 1000),
    None,
  )
}

test "an empty Domain attribute does not discard an earlier valid Domain" {
  let jar = CookieJar::new()
  let url = cookie_test_url("http://example.com/")
  // RFC 6265 §5.2.3: an empty Domain attribute is ignored entirely. It must
  // not override the earlier valid Domain attribute in the same header.
  jar.store_at(url, "sid=1; Domain=example.com; Domain=; Path=/", 1000)
  assert_eq(
    jar.cookie_header_at(cookie_test_url("http://api.example.com/"), 1000),
    Some("sid=1"),
  )
  let jar = CookieJar::new()
  jar.store_at(url, "sid=1; Domain=example.com; Domain=.; Path=/", 1000)
  assert_eq(
    jar.cookie_header_at(cookie_test_url("http://api.example.com/"), 1000),
    Some("sid=1"),
  )
}

test "the last Domain attribute decides the cookie scope" {
  let jar = CookieJar::new()
  let url = cookie_test_url("http://example.com/")
  jar.store_at(
    url,
    "bad=1; Domain=bad.example; Domain=example.com; Path=/",
    1000,
  )
  assert_eq(jar.length(), 1)
  assert_eq(
    jar.cookie_header_at(cookie_test_url("http://api.example.com/"), 1000),
    Some("bad=1"),
  )
  let invalid_last = CookieJar::new()
  invalid_last.store_at(
    url,
    "drop=1; Domain=example.com; Domain=bad.example; Path=/",
    1000,
  )
  assert_eq(invalid_last.length(), 0)
}

test "the last Path attribute decides the cookie path" {
  let jar = CookieJar::new()
  let url = cookie_test_url("http://example.com/a/b")
  jar.store_at(url, "p=1; Path=/other; Path=invalid", 1000)
  assert_eq(jar.cookie_header_at(url, 1000), Some("p=1"))
  jar.store_at(url, "q=1; Path=/other; Path=/a", 1000)
  assert_eq(
    jar.cookie_header_at(cookie_test_url("http://example.com/a/c"), 1000),
    Some("p=1; q=1"),
  )
}

test "a single-label Domain attribute cannot target a public suffix" {
  let jar = CookieJar::new()
  jar.store_at(
    cookie_test_url("http://example.com/"),
    "leak=1; Domain=com; Path=/",
    1000,
  )
  jar.store_at(
    cookie_test_url("http://localhost/"),
    "local=1; Domain=localhost; Path=/",
    1000,
  )
  assert_eq(
    jar.cookie_header_at(cookie_test_url("http://other.com/"), 1000),
    None,
  )
  assert_eq(
    jar.cookie_header_at(cookie_test_url("http://localhost/"), 1000),
    Some("local=1"),
  )
  // A single-label Domain identical to the request host is still a public
  // suffix, so the cookie must remain host-only and not leak to subdomains.
  assert_eq(
    jar.cookie_header_at(cookie_test_url("http://sub.localhost/"), 1000),
    None,
  )
}

test "a trailing-dot Domain attribute invalidates the cookie" {
  let jar = CookieJar::new()
  let url = cookie_test_url("http://www.example.com./")
  jar.store_at(url, "dot=1; Domain=example.com.; Path=/", 1000)
  assert_eq(jar.length(), 0)
  assert_eq(jar.cookie_header_at(url, 1000), None)
}

test "cookie hosts ignore a trailing root dot" {
  let jar = CookieJar::new()
  jar.store_at(
    cookie_test_url("http://Example.COM./"),
    "root=1; Path=/",
    1000,
  )
  assert_eq(
    jar.cookie_header_at(cookie_test_url("http://example.com/"), 1000),
    Some("root=1"),
  )
  assert_eq(
    jar.cookie_header_at(cookie_test_url("http://example.com./"), 1000),
    Some("root=1"),
  )
  let ip = cookie_test_url("http://127.0.0.1./")
  jar.store_at(ip, "leak=1; Domain=0.0.1; Path=/", 1000)
  assert_eq(jar.length(), 1)
  jar.store_at(ip, "ip=1; Domain=127.0.0.1; Path=/", 1000)
  assert_eq(jar.length(), 2)
  assert_eq(
    jar.cookie_header_at(cookie_test_url("http://127.0.0.1/"), 1000),
    Some("ip=1"),
  )
  assert_eq(
    jar.cookie_header_at(cookie_test_url("http://sub.127.0.0.1/"), 1000),
    None,
  )
}

test "an IPv4 Domain attribute cannot match a suffix" {
  let jar = CookieJar::new()
  let origin = cookie_test_url("http://127.0.0.1/")
  jar.store_at(origin, "leak=1; Domain=0.0.1; Path=/", 1000)
  assert_eq(jar.cookie_header_at(origin, 1000), None)
  assert_eq(jar.length(), 0)
  jar.store_at(origin, "same=1; Domain=127.0.0.1; Path=/", 1000)
  assert_eq(jar.cookie_header_at(origin, 1000), Some("same=1"))
}

test "impossible expiry dates are ignored" {
  let jar = CookieJar::new()
  let url = cookie_test_url("http://example.com/")
  let after_2030 : UInt64 = 2000000000000L.to_uint64()
  jar.store_at(url, "bad=1; Expires=Wed, 31 Feb 2030 00:00:00 GMT; Path=/", 0)
  jar.store_at(url, "also=1; Expires=Thu, 29 Feb 2023 00:00:00 GMT; Path=/", 0)
  assert_eq(jar.cookie_header_at(url, after_2030), Some("bad=1; also=1"))
  jar.store_at(url, "leap=1; Expires=Thu, 29 Feb 2024 00:00:00 GMT; Path=/", 0)
  assert_eq(jar.cookie_header_at(url, after_2030), Some("bad=1; also=1"))
}

test "expiry dates ignore extra tokens" {
  let jar = CookieJar::new()
  let url = cookie_test_url("http://example.com/")
  let after_2030 : UInt64 = 2000000000000L.to_uint64()
  jar.store_at(
    url,
    "extra=1; Expires=Wed, 21 Oct 2026 07:28:00 GMT extra; Path=/",
    0,
  )
  assert_eq(jar.cookie_header_at(url, after_2030), None)
}

///|
fn cookie_snapshot_names(jar : CookieJar) -> Array[String] {
  let names : Array[String] = []
  for cookie in jar.cookies() {
    names.push(cookie.name)
  }
  names
}

///|
test "cookie snapshots keep creation order and are stable" {
  let jar = CookieJar::new()
  let origin = cookie_test_url("http://example.com/")
  jar.store_at(origin, "a=1; Path=/", 1000)
  jar.store_at(origin, "b=2; Path=/", 1000)
  jar.store_at(origin, "c=3; Path=/", 1000)
  assert_eq(cookie_snapshot_names(jar), ["a", "b", "c"])
  let _ = jar.cookie_header_at(origin, 1000)
  assert_eq(cookie_snapshot_names(jar), ["a", "b", "c"])
  jar.store_at(origin, "a=4; Path=/", 1000)
  assert_eq(cookie_snapshot_names(jar), ["a", "b", "c"])
}

///|
test "cookie expiry accepts full month names" {
  let jar = CookieJar::new()
  let url = cookie_test_url("http://example.com/")
  jar.store_at(url, "long=1; Expires=Wed, 21 October 2030 07:28:00 GMT; Path=/", 0)
  jar.store_at(url, "rfc850=1; Expires=Wednesday, 21-October-30 07:28:00 GMT; Path=/", 0)
  assert_eq(jar.cookie_header_at(url, 0), Some("long=1; rfc850=1"))
  let year_2100 : UInt64 = 4102444800000L.to_uint64()
  assert_eq(jar.cookie_header_at(url, year_2100), None)
}

///|
test "cookie jar treats IP Domain attributes as host-only" {
  let jar = CookieJar::new()
  jar.store_at(
    cookie_test_url("http://127.0.0.1/"),
    "ip=1; Domain=127.0.0.1; Path=/",
    1000,
  )
  jar.store_at(
    cookie_test_url("http://[::1]/"),
    "v6=1; Domain=::1; Path=/",
    1000,
  )
  assert_eq(jar.length(), 2)
  assert_eq(
    jar.cookie_header_at(cookie_test_url("http://127.0.0.1/"), 1000),
    Some("ip=1"),
  )
  assert_eq(
    jar.cookie_header_at(cookie_test_url("http://sub.127.0.0.1/"), 1000),
    None,
  )
  assert_eq(
    jar.cookie_header_at(cookie_test_url("http://[::1]/"), 1000),
    Some("v6=1"),
  )
}

test "DNS hosts that look like IPvFuture use domain matching" {
  let jar = CookieJar::new()
  jar.store_at(
    cookie_test_url("http://v1.example/"),
    "d=1; Domain=v1.example; Path=/",
    1000,
  )
  assert_eq(
    jar.cookie_header_at(cookie_test_url("http://sub.v1.example/"), 1000),
    Some("d=1"),
  )
}

///|
test "bracketed IPvFuture hosts cannot use domain cookies" {
  let jar = CookieJar::new()
  let literal = cookie_test_url("http://[v1.foo]/")
  jar.store_at(literal, "a=1; Domain=v1.foo; Path=/", 1000)
  assert_eq(
    jar.cookie_header_at(cookie_test_url("http://sub.v1.foo/"), 1000),
    None,
  )
  assert_eq(jar.cookie_header_at(literal, 1000), Some("a=1"))

  // A DNS cookie for the same-looking text must not leak to the literal host.
  jar.store_at(
    cookie_test_url("http://v1.foo/"),
    "b=1; Domain=v1.foo; Path=/",
    1000,
  )
  assert_eq(jar.cookie_header_at(literal, 1000), Some("a=1"))
  assert_eq(
    jar.cookie_header_at(cookie_test_url("http://sub.v1.foo/"), 1000),
    Some("b=1"),
  )
}

///|
test "host-only cookies do not leak between DNS names and bracketed literals" {
  let dns = cookie_test_url("http://v1.foo/")
  let literal = cookie_test_url("http://[v1.foo]/")
  let jar = CookieJar::new()
  jar.store_at(dns, "a=1; Path=/", 1000)
  assert_eq(jar.cookie_header_at(dns, 1000), Some("a=1"))
  assert_eq(jar.cookie_header_at(literal, 1000), None)

  let jar = CookieJar::new()
  jar.store_at(literal, "b=1; Path=/", 1000)
  assert_eq(jar.cookie_header_at(literal, 1000), Some("b=1"))
  assert_eq(jar.cookie_header_at(dns, 1000), None)

  // The two authorities also keep distinct host-only cookies with the same
  // name instead of overwriting each other.
  let jar = CookieJar::new()
  jar.store_at(dns, "c=dns; Path=/", 1000)
  jar.store_at(literal, "c=literal; Path=/", 1000)
  assert_eq(jar.length(), 2)
  assert_eq(jar.cookie_header_at(dns, 1000), Some("c=dns"))
  assert_eq(jar.cookie_header_at(literal, 1000), Some("c=literal"))
}

///|
test "cookie domain suffixes never match IP address hosts" {  let jar = CookieJar::new()
  jar.store_at(
    cookie_test_url("http://0.0.1/"),
    "leak=1; Domain=0.0.1; Path=/",
    1000,
  )
  assert_eq(
    jar.cookie_header_at(cookie_test_url("http://0.0.1/"), 1000),
    Some("leak=1"),
  )
  assert_eq(
    jar.cookie_header_at(cookie_test_url("http://127.0.0.1/"), 1000),
    None,
  )
  assert_eq(
    jar.cookie_header_at(cookie_test_url("http://[::1]/"), 1000),
    None,
  )
}

///|
test "cookie expiry accepts RFC month suffixes" {
  let jar = CookieJar::new()
  let url = cookie_test_url("http://example.com/")
  let after_2030 : UInt64 = 2000000000000L.to_uint64()
  jar.store_at(
    url,
    "junk=1; Expires=Wed, 21 Octopus 2030 07:28:00 GMT; Path=/",
    0,
  )
  assert_eq(jar.cookie_header_at(url, after_2030), None)
}

///|
test "cookie jar enforces __Secure- prefix" {
  let jar = CookieJar::new()
  let plain = cookie_test_url("http://example.com/")
  let secure = cookie_test_url("https://example.com/")
  jar.store_at(plain, "__Secure-id=1; Path=/", 1000)
  assert_eq(jar.length(), 0)
  // Prefix matching is case-insensitive.
  jar.store_at(plain, "__SECURE-id=3; Path=/", 1000)
  assert_eq(jar.length(), 0)
  jar.store_at(secure, "__SECURE-id=4; Path=/", 1000)
  assert_eq(jar.length(), 0)
  jar.store_at(secure, "__Secure-id=2; Secure; Path=/", 1000)
  assert_eq(
    jar.cookie_header_at(secure, 1000),
    Some("__Secure-id=2"),
  )
  assert_eq(jar.cookie_header_at(plain, 1000), None)
}

///|
test "cookie jar enforces __Host- prefix" {
  let jar = CookieJar::new()
  let secure = cookie_test_url("https://example.com/account")
  jar.store_at(secure, "__Host-id=1; Secure; Path=/", 1000)
  assert_eq(jar.length(), 1)
  assert_eq(
    jar.cookie_header_at(cookie_test_url("https://example.com/x"), 1000),
    Some("__Host-id=1"),
  )
  // A Domain attribute makes the cookie domain-scoped.
  jar.store_at(
    secure,
    "__Host-id=2; Secure; Path=/; Domain=example.com",
    1000,
  )
  assert_eq(jar.length(), 1)
  // A path other than "/" is not allowed.
  jar.store_at(secure, "__Host-id=3; Secure; Path=/account", 1000)
  assert_eq(jar.length(), 1)
  // Missing Secure is not allowed even over HTTPS.
  jar.store_at(secure, "__Host-id=4; Path=/", 1000)
  assert_eq(jar.length(), 1)
  // Missing Path is not allowed even when the default path is "/".
  jar.store_at(secure, "__Host-id=5; Secure", 1000)
  assert_eq(jar.length(), 1)
  // An invalid Path attribute falls back to the default path. Here the
  // request URL is nested, so the default path is not "/" and is rejected.
  let nested = cookie_test_url("https://example.com/account/profile")
  jar.store_at(nested, "__Host-id=6; Secure; Path=account", 1000)
  assert_eq(jar.length(), 1)
  assert_eq(
    jar.cookie_header_at(cookie_test_url("https://example.com/x"), 1000),
    Some("__Host-id=1"),
  )
  // Prefix matching is case-insensitive.
  jar.store_at(secure, "__host-id=5; Path=/", 1000)
  assert_eq(jar.length(), 1)
  jar.store_at(secure, "__HOST-id=6; Secure; Domain=example.com; Path=/", 1000)
  assert_eq(jar.length(), 1)
  // A Domain attribute is forbidden even when the host is an IP literal and
  // the attribute would otherwise leave the cookie host-only.
  let ip = cookie_test_url("https://127.0.0.1/")
  jar.store_at(ip, "__Host-ip=1; Secure; Path=/", 1000)
  assert_eq(jar.cookie_header_at(ip, 1000), Some("__Host-ip=1"))
  jar.store_at(ip, "__Host-ip=2; Secure; Domain=127.0.0.1; Path=/", 1000)
  assert_eq(jar.cookie_header_at(ip, 1000), Some("__Host-ip=1"))
}

///|
test "cookie jar accessors expose the live jar" {
  let client = UnifiedClient::new().with_cookies()
  let url = cookie_test_url("http://example.com/")
  client.cookie_jar().store(url, "sid=live; Path=/")
  assert_eq(client.cookie_jar().length(), 1)
  assert_eq(client.cookie_jar().cookie_header(url), Some("sid=live"))
}

test "host-only and domain cookies with the same name coexist" {
  let jar = CookieJar::new()
  let url = cookie_test_url("http://example.com/")
  jar.store_at(url, "a=host; Path=/", 1000)
  jar.store_at(url, "a=domain; Domain=example.com; Path=/", 1000)
  assert_eq(jar.length(), 2)
  assert_eq(
    jar.cookie_header_at(url, 1000),
    Some("a=host; a=domain"),
  )
  assert_eq(
    jar.cookie_header_at(cookie_test_url("http://sub.example.com/"), 1000),
    Some("a=domain"),
  )
  jar.store_at(url, "a=host2; Path=/", 1000)
  assert_eq(
    jar.cookie_header_at(url, 1000),
    Some("a=host2; a=domain"),
  )
}

///|
test "__Host- cookies require an explicit root Path value" {
  let jar = CookieJar::new()
  let root = cookie_test_url("https://example.com/")
  // A non-root Path attribute resolves to the default path "/" on this URL,
  // but it still is not the required explicit Path=/ for the prefix.
  jar.store_at(root, "__Host-invalid=1; Secure; Path=account", 1000)
  assert_eq(jar.length(), 0)
  jar.store_at(root, "__Host-invalid=2; Secure; Path=", 1000)
  assert_eq(jar.length(), 0)
  jar.store_at(root, "__Host-invalid=3; Secure; Path=/account", 1000)
  assert_eq(jar.length(), 0)
  // The last Path attribute decides, so a later valid root path is accepted.
  jar.store_at(root, "__Host-valid=1; Secure; Path=account; Path=/", 1000)
  assert_eq(jar.cookie_header_at(root, 1000), Some("__Host-valid=1"))
}

///|
test "secure cookies cannot be shadowed by a longer path" {
  let jar = CookieJar::new()
  let secure = cookie_test_url("https://example.com/")
  let plain = cookie_test_url("http://example.com/")
  jar.store_at(secure, "sid=secret; Secure; Path=/login", 1000)
  // /login/en path-matches the existing secure cookie's /login scope, so the
  // non-secure cookie would be sent ahead of it and must be ignored.
  jar.store_at(plain, "sid=evil; Path=/login/en", 1000)
  assert_eq(jar.length(), 1)
  assert_eq(
    jar.cookie_header_at(cookie_test_url("https://example.com/login/en"), 1000),
    Some("sid=secret"),
  )
  // A path that does not path-match the secure cookie is still allowed.
  jar.store_at(plain, "sid=ok; Path=/other", 1000)
  assert_eq(jar.length(), 2)
}

///|
test "secure cookies cannot be shadowed from a parent domain" {
  let jar = CookieJar::new()
  let secure = cookie_test_url("https://sub.example.com/")
  let plain = cookie_test_url("http://example.com/")
  // The existing host-only cookie for sub.example.com domain-matches the
  // candidate's example.com scope, so the non-secure cookie must be ignored.
  jar.store_at(secure, "sid=secret; Secure; Path=/", 1000)
  jar.store_at(plain, "sid=evil; Domain=example.com; Path=/", 1000)
  assert_eq(jar.length(), 1)
  assert_eq(
    jar.cookie_header_at(cookie_test_url("https://sub.example.com/"), 1000),
    Some("sid=secret"),
  )
}

///|
test "an empty Domain attribute does not break __Host- cookies" {
  let jar = CookieJar::new()
  let secure = cookie_test_url("https://example.com/")
  jar.store_at(secure, "__Host-x=1; Secure; Path=/; Domain=", 1000)
  assert_eq(jar.cookie_header_at(secure, 1000), Some("__Host-x=1"))
}

///|
test "a Domain attribute longer than 1024 octets is ignored" {
  let jar = CookieJar::new()
  let url = cookie_test_url("https://example.com/")
  let long_domain = "a".repeat(1025)
  jar.store_at(url, "sid=1; Secure; Path=/; Domain=" + long_domain, 1000)
  // The long attribute is ignored, leaving a host-only cookie.
  assert_eq(jar.length(), 1)
  assert_eq(jar.cookie_header_at(url, 1000), Some("sid=1"))
  assert_eq(
    jar.cookie_header_at(cookie_test_url("https://sub.example.com/"), 1000),
    None,
  )

  // An earlier valid Domain attribute is still used when a later one is long.
  jar.store_at(url, "tok=1; Domain=example.com; Domain=" + long_domain, 1000)
  assert_eq(
    jar.cookie_header_at(cookie_test_url("https://sub.example.com/"), 1000),
    Some("tok=1"),
  )
}

///|
test "Path attributes longer than 1024 octets are ignored" {
  let jar = CookieJar::new()
  let url = cookie_test_url("http://example.com/a/b")
  let long_path = "/" + "a".repeat(1024)
  // A long Path attribute is ignored, so the earlier valid Path stays in
  // effect rather than becoming the oversized value.
  jar.store_at(url, "p=1; Path=/other; Path=" + long_path, 1000)
  assert_eq(
    jar.cookie_header_at(cookie_test_url("http://example.com/other/x"), 1000),
    Some("p=1"),
  )
  // With no accepted Path attribute the default-path applies.
  jar.store_at(url, "q=1; Path=" + long_path, 1000)
  assert_eq(
    jar.cookie_header_at(cookie_test_url("http://example.com/a/c"), 1000),
    Some("q=1"),
  )
}

///|
test "attribute values longer than 1024 octets are ignored" {
  let jar = CookieJar::new()
  let url = cookie_test_url("https://example.com/")
  let long_value = "9".repeat(1025)
  // A long Max-Age is ignored, leaving the Expires attribute in effect.
  jar.store_at(
    url,
    "a=1; Expires=Wed, 21 Oct 2026 07:28:00 GMT; Max-Age=" + long_value + "; Path=/",
    0,
  )
  let expiry : UInt64 = 1792567680000L.to_uint64()
  assert_eq(
    jar.cookie_header_at(cookie_test_url("https://example.com/x"), expiry - 1),
    Some("a=1"),
  )
  assert_eq(
    jar.cookie_header_at(cookie_test_url("https://example.com/x"), expiry),
    None,
  )
  // A long Secure value is ignored, so the cookie is not marked Secure.
  jar.store_at(url, "s=1; Secure=" + long_value + "; Path=/", 0)
  assert_eq(
    jar.cookie_header_at(cookie_test_url("http://example.com/"), 0),
    Some("s=1"),
  )
}

///|
test "SameSite=None cookies require the Secure attribute" {
  let jar = CookieJar::new()
  let plain = cookie_test_url("http://example.com/")
  let secure_url = cookie_test_url("https://example.com/")
  jar.store_at(plain, "a=1; SameSite=None; Path=/", 1000)
  jar.store_at(secure_url, "b=1; SameSite=None; Path=/", 1000)
  assert_eq(jar.length(), 0)
  jar.store_at(secure_url, "c=1; SameSite=None; Secure; Path=/", 1000)
  assert_eq(jar.length(), 1)
  assert_eq(jar.cookie_header_at(secure_url, 1000), Some("c=1"))
  // A later unrecognized SameSite value resolves to Default and wins.
  jar.store_at(secure_url, "d=1; SameSite=None; SameSite=unknown; Path=/", 1000)
  assert_eq(jar.cookie_header_at(secure_url, 1000), Some("c=1; d=1"))
}

///|
test "replacing a connector cookie jar does not mutate shared jars" {
  let source = Connector::new(TcpDialer::new(), MockTlsProvider::new("test"))
  let url = cookie_test_url("http://example.com/")
  source.cookie_jar().store(url, "a=1; Path=/")
  let derived = source.with_cookie_jar(CookieJar::new())
  assert_eq(source.cookie_jar().cookie_header(url), Some("a=1"))
  assert_eq(derived.cookie_jar().cookie_header(url), None)
  assert_true(derived.cookies_enabled())
}
