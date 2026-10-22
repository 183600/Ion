///|
fn bypass_cidr_test_connector(patterns : Array[String]) -> Connector {
  let stream = regression_mock_stream("", 0, 0)
  Connector::new(RegressionMockDialer::{ stream, count: 0 }, MockTlsProvider::new("test"))
    .with_proxy(Proxy::new("http://proxy.example:3128").unwrap())
    .with_proxy_bypass(patterns)
}

///|
test "malformed CIDR bypass entries do not fall back to the base host" {
  let connector = bypass_cidr_test_connector([
    "10.0.0.0/33",
    "10.0.0.0/not",
    "10.0.0.0/",
    "192.168.0.0/24/8",
    "010.0.0.0/8",
    "999.999.999.999/8",
    "[2001:db8::]/129",
    "2001:db8::/not",
  ])
  for url in [
    "http://10.0.0.0/",
    "http://192.168.0.0/",
    "http://010.0.0.0/",
    "http://999.999.999.999/",
    "http://[2001:db8::]/",
  ] {
    assert_true(connector.proxy_for_url(Url::parse(url).unwrap()) is Some(_))
  }

  let valid = bypass_cidr_test_connector(["10.0.0.0/8"])
  assert_true(valid.proxy_for_url(Url::parse("http://10.0.0.0/").unwrap()) is None)
}
