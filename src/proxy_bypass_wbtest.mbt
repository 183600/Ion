fn bypass_test_connector(
  dialer : &Dialer,
  patterns : Array[String],
) -> Connector {
  Connector::new(dialer, MockTlsProvider::new("test"))
    .with_proxy(Proxy::new("http://user:secret@proxy.example:3128").unwrap())
    .with_proxy_bypass(patterns)
}

///|
test "proxy bypass matches hosts, subdomains, and port restrictions" {
  let stream = regression_mock_stream("", 0, 0)
  let connector = bypass_test_connector(RegressionMockDialer::{ stream, count: 0 }, [
    "example.com", "example.net:8080", "*.wild.example", "  HTTP://Upper.Example  ",
  ])
  assert_true(connector.proxy_for_url(Url::parse("http://example.com/").unwrap()) is None)
  assert_true(connector.proxy_for_url(Url::parse("http://api.example.com/").unwrap()) is None)
  assert_true(connector.proxy_for_url(Url::parse("http://notexample.com/").unwrap()) is Some(_))
  assert_true(connector.proxy_for_url(Url::parse("http://example.net:8080/").unwrap()) is None)
  assert_true(connector.proxy_for_url(Url::parse("http://example.net:80/").unwrap()) is Some(_))
  assert_true(connector.proxy_for_url(Url::parse("http://a.wild.example/").unwrap()) is None)
  assert_true(connector.proxy_for_url(Url::parse("http://upper.example/").unwrap()) is None)
}

///|
test "proxy bypass supports IP literals and wildcard-all" {
  let stream = regression_mock_stream("", 0, 0)
  let connector = bypass_test_connector(RegressionMockDialer::{ stream, count: 0 }, [
    "127.0.0.1", "[::1]:8080", "*.example.com",
  ])
  assert_true(connector.proxy_for_url(Url::parse("http://127.0.0.1/").unwrap()) is None)
  assert_true(connector.proxy_for_url(Url::parse("http://127.0.0.1:8080/").unwrap()) is None)

  assert_true(connector.proxy_for_url(Url::parse("http://[::1]:8080/").unwrap()) is None)
  assert_true(connector.proxy_for_url(Url::parse("http://[::1]:80/").unwrap()) is Some(_))
  let all = bypass_test_connector(RegressionMockDialer::{ stream, count: 0 }, ["*"])
  assert_true(all.proxy_for_url(Url::parse("https://anything.example/").unwrap()) is None)
}

///|
test "proxy bypass matches IPv4 and IPv6 CIDR blocks" {
  let stream = regression_mock_stream("", 0, 0)
  let connector = bypass_test_connector(RegressionMockDialer::{ stream, count: 0 }, [
    "10.0.0.0/8", "192.168.1.0/24", "2001:db8::/32", "::1/128", "203.0.113.5/32",
  ])
  assert_true(connector.proxy_for_url(Url::parse("http://10.1.2.3/").unwrap()) is None)
  assert_true(connector.proxy_for_url(Url::parse("http://11.0.0.1/").unwrap()) is Some(_))
  assert_true(connector.proxy_for_url(Url::parse("http://192.168.1.99/").unwrap()) is None)
  assert_true(connector.proxy_for_url(Url::parse("http://192.168.2.1/").unwrap()) is Some(_))
  assert_true(
    connector.proxy_for_url(Url::parse("http://[2001:db8::1]/").unwrap()) is None,
  )
  assert_true(
    connector.proxy_for_url(Url::parse("http://[2001:db9::1]/").unwrap()) is Some(_),
  )
  assert_true(connector.proxy_for_url(Url::parse("http://[::1]/").unwrap()) is None)
  assert_true(connector.proxy_for_url(Url::parse("http://203.0.113.5/").unwrap()) is None)
  assert_true(connector.proxy_for_url(Url::parse("http://198.51.100.7/").unwrap()) is Some(_))

  let invalid = bypass_test_connector(RegressionMockDialer::{ stream, count: 0 }, [
    "10.0.0.0/33", "10.0.0.0/not", "[2001:db8::]/129",
  ])
  assert_true(invalid.proxy_for_url(Url::parse("http://10.0.0.1/").unwrap()) is Some(_))
  assert_true(
    invalid.proxy_for_url(Url::parse("http://[2001:db8::1]/").unwrap()) is Some(_),
  )
}

///|
test "malformed bypass entries never match" {
  let stream = regression_mock_stream("", 0, 0)
  let connector = bypass_test_connector(RegressionMockDialer::{ stream, count: 0 }, [
    "", " ", "example.com:", "example.com:notaport", "[::1", "foo*bar.example",
  ])
  assert_true(connector.proxy_for_url(Url::parse("http://example.com/").unwrap()) is Some(_))
  assert_true(connector.proxy_for_url(Url::parse("http://foo.example/").unwrap()) is Some(_))
}

///|
test "bypassed plain HTTP dials the origin and omits proxy headers" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
  let stream = regression_mock_stream(raw, 4096, 4096)
  let dialer = RegressionProxyDialer::{ stream, host: "", port: 0 }
  let connector = bypass_test_connector(dialer, ["example.com"])
  let client = UnifiedClient::{
    connector,
    options: ClientOptions::new().with_follow_redirects(false),
    redirect_count: 0,
  }
  let response = client.get("http://example.com/direct").unwrap()
  assert_eq(response.text().unwrap(), "ok")
  assert_eq(dialer.host, "example.com")
  assert_eq(dialer.port, 80)
  let wire = @utf8.decode(stream.output.to_bytes()[:])
  assert_true(wire.has_prefix("GET /direct HTTP/1.1\r\n"))
  assert_true(!wire.contains("Proxy-Authorization"))
}

///|
test "non-bypassed plain HTTP still uses the proxy" {
  let raw = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
  let stream = regression_mock_stream(raw, 4096, 4096)
  let dialer = RegressionProxyDialer::{ stream, host: "", port: 0 }
  let connector = bypass_test_connector(dialer, ["other.example"])
  let client = UnifiedClient::{
    connector,
    options: ClientOptions::new().with_follow_redirects(false),
    redirect_count: 0,
  }
  let _ = client.get("http://example.com/path").unwrap()
  assert_eq(dialer.host, "proxy.example")
  assert_eq(dialer.port, 3128)
  let wire = @utf8.decode(stream.output.to_bytes()[:])
  assert_true(wire.has_prefix("GET http://example.com/path HTTP/1.1\r\n"))
  assert_true(wire.contains("Proxy-Authorization: Basic "))
}

///|
test "bypassed HTTPS connects directly without a CONNECT tunnel" {
  let stream = regression_mock_stream("", 4096, 4096)
  let dialer = RegressionProxyDialer::{ stream, host: "", port: 0 }
  let connector = bypass_test_connector(dialer, ["example.com"])
  let url = Url::parse("https://example.com:8443/").unwrap()
  let _ = connector.connect(url).unwrap()
  assert_eq(dialer.host, "example.com")
  assert_eq(dialer.port, 8443)
  let wire = @utf8.decode(stream.output.to_bytes()[:])
  assert_true(!wire.contains("CONNECT "))
}

///|
test "proxy_authorization_for reflects the bypass decision" {
  let stream = regression_mock_stream("", 0, 0)
  let connector = bypass_test_connector(RegressionMockDialer::{ stream, count: 0 }, [
    "direct.example",
  ])
  assert_true(
    connector.proxy_authorization_for(Url::parse("http://direct.example/").unwrap()) is None,
  )
  assert_true(
    connector.proxy_authorization_for(Url::parse("http://proxied.example/").unwrap()) is Some(_),
  )
}

///|
test "with_proxy_bypass closes pooled connections from the old route" {
  let first_wire = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
  let second_wire = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
  let first = regression_mock_stream(first_wire, 4096, 4096)
  let second = regression_mock_stream(second_wire, 4096, 4096)
  let dialer = RegressionQueueDialer::{ streams: [first, second], index: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
    .with_proxy(Proxy::new("http://proxy.example:3128").unwrap())
  let url = Url::parse("http://example.com/").unwrap()
  let _ = connector.connect(url).unwrap()
  assert_true(first.is_open)
  let bypassed = connector.with_proxy_bypass(["example.com"])
  let _ = bypassed.connect(url).unwrap()
  assert_false(first.is_open)
  assert_eq(dialer.index, 2)
  let wire = @utf8.decode(second.output.to_bytes()[:])
  assert_true(!wire.contains("Proxy-Authorization"))
}

///|
test "single-label bypass entries do not match every subdomain" {
  let stream = regression_mock_stream("", 0, 0)
  let connector = bypass_test_connector(RegressionMockDialer::{ stream, count: 0 }, [
    "com", "localhost", ".0.0.1",
  ])
  assert_true(connector.proxy_for_url(Url::parse("http://example.com/").unwrap()) is Some(_))
  assert_true(connector.proxy_for_url(Url::parse("http://localhost/").unwrap()) is None)
  assert_true(
    connector.proxy_for_url(Url::parse("http://api.localhost/").unwrap()) is Some(_),
  )
  assert_true(
    connector.proxy_for_url(Url::parse("http://127.0.0.1/").unwrap()) is Some(_),
  )
}

///|
test "explicit wildcard entries match single-label subdomains" {
  let stream = regression_mock_stream("", 0, 0)
  let connector = bypass_test_connector(RegressionMockDialer::{ stream, count: 0 }, [
    "*.localhost", ".internal",
  ])
  assert_true(
    connector.proxy_for_url(Url::parse("http://api.localhost/").unwrap()) is None,
  )
  assert_true(
    connector.proxy_for_url(Url::parse("http://host.internal/").unwrap()) is None,
  )
  assert_true(
    connector.proxy_for_url(Url::parse("http://api.host.internal/").unwrap()) is None,
  )
  assert_true(connector.proxy_for_url(Url::parse("http://other.example/").unwrap()) is Some(_))
}
