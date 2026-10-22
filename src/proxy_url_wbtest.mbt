///|
test "with_proxy_url accepts a bare host and port" {
  let client = default_client()
  let proxied = client.with_proxy_url(" proxy.example:3128 ").unwrap()
  match proxied.connector.proxy {
    Some(proxy) => {
      assert_eq(proxy.authority(), "proxy.example:3128")
      assert_false(proxy.is_secure())
    }
    None => fail("bare proxy URL did not configure a proxy")
  }
  let _ = client.close_all()
}

///|
test "with_proxy_url still rejects unsupported schemes" {
  let client = default_client()
  assert_true(client.with_proxy_url("ftp://proxy.example") is Err(_))
  assert_true(client.with_proxy_url("https://proxy.example:8443") is Ok(_))
}
