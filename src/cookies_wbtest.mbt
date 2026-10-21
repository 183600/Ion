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

test "single-digit expiry years are normalized" {
  let jar = CookieJar::new()
  let url = cookie_test_url("http://example.com/")
  jar.store_at(url, "y=1; Expires=Wed, 01 Jan 5 00:00:00 GMT; Path=/", 0)
  let expires_at : UInt64 = 1104537600000L.to_uint64()
  assert_eq(jar.cookie_header_at(url, expires_at - 1), Some("y=1"))
  assert_eq(jar.cookie_header_at(url, expires_at), None)
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

test "an empty Domain attribute invalidates the cookie" {
  let jar = CookieJar::new()
  let url = cookie_test_url("http://example.com/")
  jar.store_at(url, "sid=1; Domain=; Path=/", 1000)
  assert_eq(jar.cookie_header_at(url, 1000), None)
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

test "expiry dates with extra tokens are ignored" {
  let jar = CookieJar::new()
  let url = cookie_test_url("http://example.com/")
  let after_2030 : UInt64 = 2000000000000L.to_uint64()
  jar.store_at(
    url,
    "extra=1; Expires=Wed, 21 Oct 2026 07:28:00 GMT extra; Path=/",
    0,
  )
  assert_eq(jar.cookie_header_at(url, after_2030), Some("extra=1"))
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

///|
test "cookie domain suffixes never match IP address hosts" {
  let jar = CookieJar::new()
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
