test "NO_PROXY <local> matches single-label hosts only" {
  let stream = regression_mock_stream("", 0, 0)
  let connector = bypass_test_connector(RegressionMockDialer::{ stream, count: 0 }, [
    "<local>",
  ])
  assert_true(connector.proxy_for_url(Url::parse("http://localhost/").unwrap()) is None)
  assert_true(connector.proxy_for_url(Url::parse("http://printer/").unwrap()) is None)
  assert_true(
    connector.proxy_for_url(Url::parse("http://example.com/").unwrap()) is Some(_),
  )
  assert_true(
    connector.proxy_for_url(Url::parse("http://api.localhost/").unwrap()) is Some(_),
  )
  assert_true(
    connector.proxy_for_url(Url::parse("http://127.0.0.1/").unwrap()) is Some(_),
  )
  assert_true(
    connector.proxy_for_url(Url::parse("http://[::1]/").unwrap()) is Some(_),
  )
}

test "NO_PROXY host with a wildcard port matches every port" {
  let stream = regression_mock_stream("", 0, 0)
  let connector = bypass_test_connector(RegressionMockDialer::{ stream, count: 0 }, [
    "example.net:*",
    "[::1]:*",
  ])
  assert_true(
    connector.proxy_for_url(Url::parse("http://example.net/").unwrap()) is None,
  )
  assert_true(
    connector.proxy_for_url(Url::parse("http://example.net:8080/").unwrap()) is None,
  )
  assert_true(
    connector.proxy_for_url(Url::parse("http://example.org:8080/").unwrap()) is Some(_),
  )
  assert_true(connector.proxy_for_url(Url::parse("http://[::1]:80/").unwrap()) is None)
  assert_true(
    connector.proxy_for_url(Url::parse("http://[::1]:8080/").unwrap()) is None,
  )
}
