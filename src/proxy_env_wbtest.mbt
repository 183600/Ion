fn proxy_test_lookup(entries : Array[(String, String)]) -> (String) -> String? {
  fn(key) {
    for entry in entries {
      if entry.0 == key {
        return Some(entry.1)
      }
    }
    None
  }
}

fn proxy_test_url(raw : String) -> Url {
  Url::parse(raw).unwrap()
}

test "environment proxy prefers HTTPS_PROXY for HTTPS URLs" {
  let lookup = proxy_test_lookup([
    ("HTTPS_PROXY", "http://secure-proxy.example:8443"),
    ("ALL_PROXY", "http://fallback.example:9000"),
  ])
  let proxy = proxy_from_env_lookup(proxy_test_url("https://example.com/"), lookup).unwrap().unwrap()
  assert_eq(proxy.authority(), "secure-proxy.example:8443")
  assert_false(proxy.is_secure())
}

test "environment proxy accepts schemeless HTTPS_PROXY values" {
  let lookup = proxy_test_lookup([
    ("https_proxy", "proxy.example:3128"),
  ])
  let proxy = proxy_from_env_lookup(proxy_test_url("https://example.com/"), lookup).unwrap().unwrap()
  assert_eq(proxy.authority(), "proxy.example:3128")
  assert_false(proxy.is_secure())
}

test "environment proxy supports HTTPS proxy URLs" {
  let lookup = proxy_test_lookup([
    ("HTTPS_PROXY", "https://proxy.example:443"),
  ])
  let proxy = proxy_from_env_lookup(proxy_test_url("https://example.com/"), lookup).unwrap().unwrap()
  assert_true(proxy.is_secure())
}

test "environment proxy prefers lowercase http_proxy" {
  let lookup = proxy_test_lookup([
    ("http_proxy", "http://lower.example:8080"),
    ("HTTP_PROXY", "http://upper.example:8080"),
  ])
  let proxy = proxy_from_env_lookup(proxy_test_url("http://example.com/"), lookup).unwrap().unwrap()
  assert_eq(proxy.authority(), "lower.example:8080")
}

test "environment proxy ignores uppercase HTTP_PROXY in CGI environments" {
  let lookup = proxy_test_lookup([
    ("HTTP_PROXY", "http://upper.example:8080"),
    ("REQUEST_METHOD", "GET"),
  ])
  assert_true(proxy_from_env_lookup(proxy_test_url("http://example.com/"), lookup).unwrap() is None)
}

test "environment proxy falls back to ALL_PROXY" {
  let lookup = proxy_test_lookup([
    ("all_proxy", "http://fallback.example:9000"),
  ])
  let proxy = proxy_from_env_lookup(proxy_test_url("http://example.com/"), lookup).unwrap().unwrap()
  assert_eq(proxy.authority(), "fallback.example:9000")
}

test "environment proxy ignores empty values and reports malformed ones" {
  let empty = proxy_test_lookup([
    ("https_proxy", "   "),
    ("ALL_PROXY", ""),
  ])
  assert_true(proxy_from_env_lookup(proxy_test_url("https://example.com/"), empty).unwrap() is None)
  let malformed = proxy_test_lookup([
    ("https_proxy", "http://proxy.example:not-a-port"),
  ])
  assert_true(proxy_from_env_lookup(proxy_test_url("https://example.com/"), malformed) is Err(_))
}

test "environment proxy ALL_PROXY accepts SOCKS5 URLs" {
  let lookup = proxy_test_lookup([
    ("ALL_PROXY", "socks5://proxy.example:1080"),
  ])
  let proxy = proxy_from_env_lookup(proxy_test_url("http://example.com/"), lookup).unwrap().unwrap()
  assert_true(proxy.is_socks5())
  assert_false(proxy.is_socks5h())
  assert_eq(proxy.authority(), "proxy.example:1080")
}

test "environment proxy ALL_PROXY accepts SOCKS5H credentials" {
  let lookup = proxy_test_lookup([
    ("all_proxy", "socks5h://user:pass@proxy.example:1081"),
  ])
  let proxy = proxy_from_env_lookup(proxy_test_url("https://example.com/"), lookup).unwrap().unwrap()
  assert_true(proxy.is_socks5h())
  assert_eq(proxy.authority(), "proxy.example:1081")
  let (username, password) = proxy.socks_credentials().unwrap()
  assert_eq(@utf8.decode_lossy(username[:]), "user")
  assert_eq(@utf8.decode_lossy(password[:]), "pass")
}

test "environment scheme-specific proxy variables reject SOCKS5 URLs" {
  let secure = proxy_test_lookup([
    ("HTTPS_PROXY", "socks5://proxy.example:1080"),
  ])
  assert_true(proxy_from_env_lookup(proxy_test_url("https://example.com/"), secure) is Err(_))
  let plain = proxy_test_lookup([
    ("http_proxy", "socks5h://proxy.example:1080"),
  ])
  assert_true(proxy_from_env_lookup(proxy_test_url("http://example.com/"), plain) is Err(_))
}

test "environment NO_PROXY list is trimmed" {
  let lookup = proxy_test_lookup([
    ("NO_PROXY", " example.com, .internal.example ,*, "),
  ])
  assert_eq(proxy_no_proxy_lookup(lookup), ["example.com", ".internal.example", "*"])
}
