test "shared TLS configuration keeps HTTP/2 ALPN enabled" {
  let stream = regression_mock_stream("", 0, 0)
  let provider = ConfigCapturingTlsProvider::{ last_config: None }
  let connector = Connector::new(
    RegressionMockDialer::{ stream, count: 0 },
    provider,
  )
    .with_http2(true)
    .with_tls_config(TlsConfig::new("base.example"))
  let _ = connector.connect(Url::parse("https://secure.example/").unwrap()).unwrap()
  let captured = provider.last_config.unwrap()
  assert_eq(captured.server_name, "secure.example")
  assert_eq(captured.alpn.to_array(), ["h2", "http/1.1"])
}

test "a custom ALPN list is preserved on a shared TLS configuration" {
  let stream = regression_mock_stream("", 0, 0)
  let provider = ConfigCapturingTlsProvider::{ last_config: None }
  let alpn = @list.List(["http/1.1", "h2"])
  let connector = Connector::new(
    RegressionMockDialer::{ stream, count: 0 },
    provider,
  )
    .with_http2(true)
    .with_tls_config(TlsConfig::new("base.example").with_alpn(alpn))
  let _ = connector.connect(Url::parse("https://secure.example/").unwrap()).unwrap()
  assert_eq(provider.last_config.unwrap().alpn, alpn)
}

test "disabling HTTP/2 keeps the shared TLS configuration on HTTP/1.1" {
  let stream = regression_mock_stream("", 0, 0)
  let provider = ConfigCapturingTlsProvider::{ last_config: None }
  let connector = Connector::new(
    RegressionMockDialer::{ stream, count: 0 },
    provider,
  )
    .with_http2(false)
    .with_tls_config(TlsConfig::new("base.example"))
  let _ = connector.connect(Url::parse("https://secure.example/").unwrap()).unwrap()
  assert_eq(provider.last_config.unwrap().alpn.to_array(), ["http/1.1"])
}
