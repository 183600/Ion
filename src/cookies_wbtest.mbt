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
