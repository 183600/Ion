///|
fn cache_test_request(url : String) -> Request {
  Request::from_url(GET, url).unwrap()
}

///|
fn cache_test_response(status : Int, headers : Headers, body : String) -> Response {
  let stream = regression_mock_stream(body, 0, 0)
  Response::new(status, headers, stream)
}

///|
test "cache control parses combined directives" {
  let control = CacheControl::parse(
    "max-age=60, no-store, private, must-revalidate, max-stale",
  )
  assert_true(control.no_store)
  assert_true(control.private_cache)
  assert_true(control.must_revalidate)
  assert_eq(control.max_age, Some(60))
  assert_eq(control.max_stale, Some(-1))
  let quoted = CacheControl::parse("max-age=\"120\", public, immutable")
  assert_eq(quoted.max_age, Some(120))
  assert_true(quoted.public_cache)
  assert_true(quoted.immutable)
}

///|
test "fresh cache entries are served with an updated age" {
  let cache = HttpCache::new()
  let request = cache_test_request("http://example.com/data")
  let date = cookie_parse_date("Sun, 01 Nov 2026 00:00:00 GMT").unwrap()
  let headers = Headers::new()
    .add("Cache-Control", "max-age=60")
    .add("Date", "Sun, 01 Nov 2026 00:00:00 GMT")
  let response = cache_test_response(200, headers, "hello")
  assert_eq(cache.store(request, response, date).unwrap().status, 200)
  let hit = match cache.lookup(request, date + 10000UL) {
    CacheLookup::Hit(hit) => hit
    CacheLookup::Miss => fail("expected a cache hit")
  }
  assert_true(hit.fresh)
  assert_eq(hit.response.get_header("Age"), Some("10"))
  assert_eq(hit.response.get_header("Content-Length"), Some("5"))
  assert_eq(@utf8.decode_lossy(hit.response.read_body().unwrap()[:]), "hello")
  let stale = match cache.lookup(request, date + 61000UL) {
    CacheLookup::Hit(hit) => hit
    CacheLookup::Miss => fail("expected a stale cache entry")
  }
  assert_false(stale.fresh)
}

///|
test "cache entries honor vary headers" {
  let cache = HttpCache::new()
  let request = cache_test_request("http://example.com/vary").with_header(
    "Accept-Language",
    "en",
  )
  let headers = Headers::new()
    .add("Cache-Control", "max-age=60")
    .add("Vary", "Accept-Language")
  let response = cache_test_response(200, headers, "english")
  let now = cookie_parse_date("Sun, 01 Nov 2026 00:00:00 GMT").unwrap()
  let _ = cache.store(request, response, now).unwrap()
  let other = request.with_header("Accept-Language", "fr")
  assert_true(cache.lookup(other, now + 1000UL) is CacheLookup::Miss)
  assert_true(cache.lookup(request, now + 1000UL) is CacheLookup::Hit(_))
}

///|
test "vary star and no-store responses are not cached" {
  let cache = HttpCache::new()
  let request = cache_test_request("http://example.com/private")
  let now = cookie_parse_date("Sun, 01 Nov 2026 00:00:00 GMT").unwrap()
  let vary = cache_test_response(
    200,
    Headers::new().add("Cache-Control", "max-age=60").add("Vary", "*"),
    "x",
  )
  let _ = cache.store(request, vary, now).unwrap()
  assert_eq(cache.length(), 0)
  let no_store = cache_test_response(
    200,
    Headers::new().add("Cache-Control", "no-store, max-age=60"),
    "x",
  )
  let _ = cache.store(request, no_store, now).unwrap()
  assert_eq(cache.length(), 0)
}

///|
test "304 responses refresh stored entries" {
  let cache = HttpCache::new()
  let request = cache_test_request("http://example.com/etag")
  let now = cookie_parse_date("Sun, 01 Nov 2026 00:00:00 GMT").unwrap()
  let initial = cache_test_response(
    200,
    Headers::new()
      .add("Cache-Control", "max-age=0")
      .add("ETag", "\"v1\"")
      .add("Date", "Sun, 01 Nov 2026 00:00:00 GMT"),
    "cached",
  )
  let _ = cache.store(request, initial, now).unwrap()
  let hit = match cache.lookup(request, now + 1000UL) {
    CacheLookup::Hit(hit) => hit
    CacheLookup::Miss => fail("expected a stale cache entry")
  }
  assert_false(hit.fresh)
  assert_eq(hit.etag, Some("\"v1\""))
  let not_modified = cache_test_response(
    304,
    Headers::new()
      .add("Cache-Control", "max-age=60")
      .add("ETag", "\"v1\"")
      .add("Date", "Sun, 01 Nov 2026 00:00:01 GMT"),
    "",
  )
  let refreshed = cache
    .revalidate(request, not_modified, now + 2000UL)
    .unwrap()
  assert_eq(refreshed.status, 200)
  assert_eq(@utf8.decode_lossy(refreshed.read_body().unwrap()[:]), "cached")
  let fresh = match cache.lookup(request, now + 3000UL) {
    CacheLookup::Hit(hit) => hit
    CacheLookup::Miss => fail("expected a refreshed cache entry")
  }
  assert_true(fresh.fresh)
}

///|
test "cached clients avoid repeat requests and revalidate stale entries" {
  let first = regression_mock_stream(
    "HTTP/1.1 200 OK\r\nCache-Control: max-age=60\r\nContent-Length: 5\r\n\r\nhello",
    0,
    0,
  )
  let dialer = RegressionMockDialer::{ stream: first, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let client = UnifiedClient::{ connector, options: ClientOptions::new(), redirect_count: 0 }
  let cached = CachedClient::new(client)
  let first_response = cached.get("http://example.com/cached").unwrap()
  assert_eq(@utf8.decode_lossy(first_response.read_body().unwrap()[:]), "hello")
  assert_eq(dialer.count, 1)
  let second_response = cached.get("http://example.com/cached").unwrap()
  assert_eq(@utf8.decode_lossy(second_response.read_body().unwrap()[:]), "hello")
  assert_eq(dialer.count, 1)
}

///|
test "cached clients send validators for stale entries" {
  let first = regression_mock_stream(
    "HTTP/1.1 200 OK\r\nCache-Control: max-age=0\r\nETag: \"v1\"\r\nConnection: close\r\nContent-Length: 5\r\n\r\nhello",
    0,
    0,
  )
  let second = regression_mock_stream(
    "HTTP/1.1 304 Not Modified\r\nCache-Control: max-age=60\r\nETag: \"v1\"\r\n\r\n",
    0,
    0,
  )
  let dialer = RegressionQueueDialer::{ streams: [first, second], index: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let client = UnifiedClient::{ connector, options: ClientOptions::new(), redirect_count: 0 }
  let cached = CachedClient::new(client)
  let first_response = cached.get("http://example.com/revalidate").unwrap()
  assert_eq(@utf8.decode_lossy(first_response.read_body().unwrap()[:]), "hello")
  let second_response = cached.get("http://example.com/revalidate").unwrap()
  assert_eq(second_response.status, 200)
  assert_eq(@utf8.decode_lossy(second_response.read_body().unwrap()[:]), "hello")
  assert_eq(dialer.index, 2)
}

///|
fn cache_test_response_bytes(status : Int, headers : Headers, body : Bytes) -> Response {
  let stream = RegressionMockStream::{
    input: body,
    offset: 0,
    output: @buffer.new(size_hint=64),
    max_read: 0,
    max_write: 0,
    is_open: true,
    last_timeout: 0,
  }
  Response::new(status, headers, stream)
}

///|
test "cached responses preserve content encoding and decoding mode" {
  let cache = HttpCache::new()
  let request = cache_test_request("http://example.com/gzip")
  let encoded = auto_decompress_gzip_hello()
  let headers = Headers::new()
    .add("Cache-Control", "max-age=60")
    .add("Content-Encoding", "gzip")
  let raw = cache_test_response_bytes(200, headers, encoded)
  let returned = cache.store(request, raw, @env.now()).unwrap()
  assert_eq(returned.read_body().unwrap(), encoded)
  let hit = match cache.lookup(request, @env.now()) {
    CacheLookup::Hit(hit) => hit
    CacheLookup::Miss => fail("expected a cache hit")
  }
  assert_eq(hit.response.read_body().unwrap(), encoded)
}

///|
test "cached decoding mode still decodes buffered bodies" {
  let cache = HttpCache::new()
  let request = cache_test_request("http://example.com/gzip-decoded")
  let headers = Headers::new()
    .add("Cache-Control", "max-age=60")
    .add("Content-Encoding", "gzip")
  let raw = cache_test_response_bytes(200, headers, auto_decompress_gzip_hello())
    .with_auto_decompress(true)
  let returned = cache.store(request, raw, @env.now()).unwrap()
  assert_eq(@utf8.decode_lossy(returned.read_body().unwrap()[:]), "hello")
  let hit = match cache.lookup(request, @env.now()) {
    CacheLookup::Hit(hit) => hit
    CacheLookup::Miss => fail("expected a cache hit")
  }
  assert_eq(@utf8.decode_lossy(hit.response.read_body().unwrap()[:]), "hello")
}

///|
test "unsafe methods invalidate cached entries" {
  let first = regression_mock_stream(
    "HTTP/1.1 200 OK\r\nCache-Control: max-age=60\r\nConnection: close\r\nContent-Length: 3\r\n\r\nold",
    0,
    0,
  )
  let post = regression_mock_stream(
    "HTTP/1.1 201 Created\r\nConnection: close\r\nContent-Length: 0\r\n\r\n",
    0,
    0,
  )
  let third = regression_mock_stream(
    "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 3\r\n\r\nnew",
    0,
    0,
  )
  let dialer = RegressionQueueDialer::{ streams: [first, post, third], index: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let client = UnifiedClient::{ connector, options: ClientOptions::new(), redirect_count: 0 }
  let cached = CachedClient::new(client)
  let seeded = cached.get("http://example.com/resource").unwrap()
  assert_eq(@utf8.decode_lossy(seeded.read_body().unwrap()[:]), "old")
  let created = cached.post("http://example.com/resource", b"update").unwrap()
  assert_eq(created.status, 201)
  let refreshed = cached.get("http://example.com/resource").unwrap()
  assert_eq(@utf8.decode_lossy(refreshed.read_body().unwrap()[:]), "new")
  assert_eq(dialer.index, 3)
}

///|
test "stored cache entries drop hop-by-hop headers" {
  let cache = HttpCache::new()
  let request = cache_test_request("http://example.com/headers")
  let now = cookie_parse_date("Sun, 01 Nov 2026 00:00:00 GMT").unwrap()
  let headers = Headers::new()
    .add("Cache-Control", "max-age=60")
    .add("Connection", "X-Private")
    .add("X-Private", "secret")
    .add("Keep-Alive", "timeout=5")
    .add("X-Public", "kept")
  let _ = cache
    .store(request, cache_test_response(200, headers, "body"), now)
    .unwrap()
  let hit = match cache.lookup(request, now + 1000UL) {
    CacheLookup::Hit(hit) => hit
    CacheLookup::Miss => fail("expected a cache hit")
  }
  assert_true(hit.response.get_header("X-Private") is None)
  assert_true(hit.response.get_header("Connection") is None)
  assert_true(hit.response.get_header("Keep-Alive") is None)
  assert_eq(hit.response.get_header("X-Public"), Some("kept"))
}
