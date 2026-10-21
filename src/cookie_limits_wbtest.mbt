test "cookie jar evicts the oldest cookies beyond the per-domain limit" {
  let jar = CookieJar::new()
  let url = Url::parse("http://a.example/").unwrap()
  let mut index = 0
  while index < 55 {
    jar.store_at(
      url,
      "c" + index.to_string() + "=1; Path=/",
      (1000 + index).to_uint64(),
    )
    index = index + 1
  }
  assert_eq(jar.length(), 50)
  let header = jar.cookie_header_at(url, 10000UL).unwrap()
  assert_false(header.contains("c0="))
  assert_false(header.contains("c4="))
  assert_true(header.contains("c5="))
  assert_true(header.contains("c54="))
}

test "cookie jar evicts the oldest cookies beyond the global limit" {
  let jar = CookieJar::new()
  let mut index = 0
  while index < 3005 {
    let url = Url::new("http", "d" + index.to_string() + ".example", 80)
    jar.store_at(url, "token=1; Path=/", (1000 + index).to_uint64())
    index = index + 1
  }
  assert_eq(jar.length(), 3000)
  let first = Url::new("http", "d0.example", 80)
  let last = Url::new("http", "d3004.example", 80)
  assert_true(jar.cookie_header_at(first, 10000UL) is None)
  assert_true(jar.cookie_header_at(last, 10000UL) is Some(_))
}

test "cookie jar limits do not evict a replaced cookie" {
  let jar = CookieJar::new()
  let url = Url::parse("http://a.example/").unwrap()
  let mut index = 0
  while index < 50 {
    jar.store_at(
      url,
      "c" + index.to_string() + "=1; Path=/",
      (1000 + index).to_uint64(),
    )
    index = index + 1
  }
  jar.store_at(url, "c0=2; Path=/", 5000UL)
  assert_eq(jar.length(), 50)
  let header = jar.cookie_header_at(url, 10000UL).unwrap()
  assert_true(header.contains("c0=2"))
  assert_true(header.contains("c49=1"))
}
