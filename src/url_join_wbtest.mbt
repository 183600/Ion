test "Url::join resolves RFC 3986 relative references" {
  let base = Url::parse("http://a/b/c/d;p?q").unwrap()
  let cases : Array[(String, String)] = [
    ("g", "http://a/b/c/g"),
    ("./g", "http://a/b/c/g"),
    ("g/", "http://a/b/c/g/"),
    ("/g", "http://a/g"),
    ("//g", "http://g/"),
    ("?y", "http://a/b/c/d;p?y"),
    ("g?y", "http://a/b/c/g?y"),
    ("#s", "http://a/b/c/d;p?q#s"),
    ("g#s", "http://a/b/c/g#s"),
    ("g?y#s", "http://a/b/c/g?y#s"),
    (";x", "http://a/b/c/;x"),
    ("g;x", "http://a/b/c/g;x"),
    ("g;x?y#s", "http://a/b/c/g;x?y#s"),
    ("", "http://a/b/c/d;p?q"),
    (".", "http://a/b/c/"),
    ("./", "http://a/b/c/"),
    ("..", "http://a/b/"),
    ("../", "http://a/b/"),
    ("../g", "http://a/b/g"),
    ("../..", "http://a/"),
    ("../../", "http://a/"),
    ("../../g", "http://a/g"),
    ("../../../g", "http://a/g"),
    ("../../../../g", "http://a/g"),
    ("./../g", "http://a/b/g"),
    ("./g/.", "http://a/b/c/g/"),
    ("g/./h", "http://a/b/c/g/h"),
    ("g/../h", "http://a/b/c/h"),
    ("g;x=1/./y", "http://a/b/c/g;x=1/y"),
    ("g;x=1/../y", "http://a/b/c/y"),
    ("g?y/./x", "http://a/b/c/g?y/./x"),
    ("g?y/../x", "http://a/b/c/g?y/../x"),
    ("g#s/./x", "http://a/b/c/g#s/./x"),
    ("g#s/../x", "http://a/b/c/g#s/../x"),
  ]
  for entry in cases {
    let (reference, expected) = entry
    assert_eq(base.join(reference).unwrap().to_string(), expected)
  }
}

test "Url::join with an empty reference does not inherit the base fragment" {
  let base = Url::parse("http://a/b/c/d;p?q#frag").unwrap()
  assert_eq(base.join("").unwrap().to_string(), "http://a/b/c/d;p?q")
}

test "Url::join keeps absolute and scheme-relative references" {
  let base = Url::parse("https://example.com/dir/page?q=1").unwrap()
  assert_eq(
    base.join("HTTP://Other.Example/x").unwrap().to_string(),
    "http://Other.Example/x",
  )
  assert_eq(
    base.join("//cdn.example/lib.js").unwrap().to_string(),
    "https://cdn.example/lib.js",
  )
  assert_eq(
    base.join("/root/../next").unwrap().to_string(),
    "https://example.com/next",
  )
}

test "Url::join rejects unsupported schemes and malformed references" {
  let base = Url::parse("http://example.com/a").unwrap()
  for reference in [
    "ftp://example.com/x",
    "mailto:user@example.com",
    "http://exa mple.com/",
    "//exa mple.com/",
    "/a\\b",
  ] {
    assert_true(base.join(reference) is Err(_))
  }
}

test "Url::join keeps an asterisk-form base intact for fragment-only references" {
  let base = Url::parse("http://example.com").unwrap().with_path("*")
  let joined = base.join("#s").unwrap()
  assert_eq(joined.host, "example.com")
  assert_eq(joined.path, "*")
  assert_eq(joined.fragment, "s")
  assert_eq(joined.to_string(), "http://example.com/*#s")
}

test "Url::join keeps an asterisk-form base intact for empty and query-only references" {
  let base = Url::parse("http://example.com").unwrap().with_path("*")
  let empty = base.join("").unwrap()
  assert_eq(empty.path, "*")
  assert_eq(empty.to_string(), "http://example.com/*")
  let query = base.join("?y=2").unwrap()
  assert_eq(query.path, "*")
  assert_eq(query.query, "y=2")
  assert_eq(query.to_string(), "http://example.com/*?y=2")
  // A reference that supplies a new path still replaces the asterisk form.
  let path = base.join("next").unwrap()
  assert_eq(path.path, "/next")
}

test "redirect resolution keeps an asterisk-form base for fragment and query targets" {
  let base = Url::parse("http://example.com").unwrap().with_path("*")
  let fragment = resolve_redirect_url(base, "#s").unwrap()
  assert_eq(fragment.path, "*")
  assert_eq(fragment.fragment, "s")
  let query = resolve_redirect_url(base, "?y=2").unwrap()
  assert_eq(query.path, "*")
  assert_eq(query.query, "y=2")
  let next = resolve_redirect_url(base, "next").unwrap()
  assert_eq(next.path, "/next")
}

test "Url::join keeps dot segments in the base path for empty-path references" {
  let base = Url::parse("http://example.com/a/../b").unwrap()
  assert_eq(base.to_string(), "http://example.com/a/../b")
  for entry in [
    ("", "http://example.com/a/../b"),
    ("#s", "http://example.com/a/../b#s"),
    ("?y=2", "http://example.com/a/../b?y=2"),
  ] {
    let (reference, expected) = entry
    assert_eq(base.join(reference).unwrap().to_string(), expected)
  }
  // A reference that supplies a path is still normalized after merging.
  assert_eq(base.join("next").unwrap().to_string(), "http://example.com/next")
}

test "redirect resolution keeps dot segments for empty-path references" {
  let base = Url::parse("http://example.com/a/../b").unwrap()
  for entry in [
    ("", "http://example.com/a/../b"),
    ("#s", "http://example.com/a/../b#s"),
    ("?y=2", "http://example.com/a/../b?y=2"),
  ] {
    let (location, expected) = entry
    assert_eq(resolve_redirect_url(base, location).unwrap().to_string(), expected)
  }
  assert_eq(
    resolve_redirect_url(base, "next").unwrap().to_string(),
    "http://example.com/next",
  )
}
