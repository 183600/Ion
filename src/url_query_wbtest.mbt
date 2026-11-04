///|
test "query parameters decode plus signs and UTF-8 escapes" {
  let url = Url::parse(
    "http://example.com/search?a=1&b=hello+world&a=3&empty=&flag&enc=%E2%9C%93",
  ).unwrap()
  assert_eq(url.query_params(), [
    ("a", "1"),
    ("b", "hello world"),
    ("a", "3"),
    ("empty", ""),
    ("flag", ""),
    ("enc", "✓"),
  ])
}

///|
test "query parameter lookup preserves order" {
  let url = Url::parse("http://example.com/?a=1&b=2&a=3").unwrap()
  assert_eq(url.query_param("a"), Some("1"))
  assert_eq(url.query_param_all("a"), ["1", "3"])
  assert_eq(url.query_param("missing"), None)
  let flag = Url::parse("http://example.com/?flag").unwrap()
  assert_eq(flag.query_param("flag"), Some(""))
}

///|
test "with_query_params encodes components and keeps the fragment" {
  let url = Url::parse("http://example.com/path?old=1#frag").unwrap()
  let updated = url.with_query_params([("q", "a b"), ("sym", "&=+")])
  assert_eq(updated.query, "q=a+b&sym=%26%3D%2B")
  assert_eq(updated.path, "/path")
  assert_eq(updated.fragment, "frag")
  assert_eq(
    updated.to_string(),
    "http://example.com/path?q=a+b&sym=%26%3D%2B#frag",
  )
  assert_eq(updated.query_params(), [("q", "a b"), ("sym", "&=+")])
}

///|
test "with_query_param replaces duplicates and appends missing names" {
  let url = Url::parse("http://example.com/?a=1&b=2&a=3").unwrap()
  let updated = url.with_query_param("a", "x y")
  assert_eq(updated.query, "a=x+y&b=2")
  assert_eq(updated.to_string(), "http://example.com/?a=x+y&b=2")
  let appended = updated.with_query_param("c", "4")
  assert_eq(appended.query, "a=x+y&b=2&c=4")
  let fresh = Url::parse("http://example.com/").unwrap()
  assert_eq(fresh.with_query_param("flag", "").query, "flag=")
}

///|
test "without_query_param removes every duplicate" {
  let url = Url::parse("http://example.com/?a=1&b=%2F&a=3#f").unwrap()
  let updated = url.without_query_param("a")
  assert_eq(updated.query, "b=%2F")
  assert_eq(updated.fragment, "f")
  assert_eq(updated.to_string(), "http://example.com/?b=%2F#f")
  assert_eq(updated.without_query_param("missing").query, "b=%2F")
  assert_eq(
    Url::parse("http://example.com/?a=1").unwrap().without_query_param("a").query,
    "",
  )
}

///|
test "with_query_params with no parameters clears the query" {
  let url = Url::parse("http://example.com/p?x=1").unwrap()
  let cleared = url.with_query_params([])
  assert_eq(cleared.query, "")
  assert_eq(cleared.to_string(), "http://example.com/p")
}

///|
test "query helpers leave malformed escapes readable" {
  let url = Url::parse("http://example.com/")
    .unwrap()
    .with_query("bad=%zz&ok=%41")
  assert_eq(url.query_param("bad"), Some("%zz"))
  assert_eq(url.query_param("ok"), Some("A"))
}
