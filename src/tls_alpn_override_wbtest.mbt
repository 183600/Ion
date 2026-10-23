test "an explicit HTTP/1.1 ALPN list is not upgraded to h2" {
  let stream = regression_mock_stream("", 0, 0)
  let provider = ConfigCapturingTlsProvider::{ last_config: None }
  let connector = Connector::new(
    RegressionMockDialer::{ stream, count: 0 },
    provider,
  )
    .with_http2(true)
    .with_tls_config(
      TlsConfig::new("base.example").with_alpn(@list.List(["http/1.1"])),
    )
  let _ = connector.connect(Url::parse("https://secure.example/").unwrap()).unwrap()
  assert_eq(provider.last_config.unwrap().alpn.to_array(), ["http/1.1"])
}

test "disabling HTTP/2 removes h2 from a custom shared ALPN list" {
  let stream = regression_mock_stream("", 0, 0)
  let provider = ConfigCapturingTlsProvider::{ last_config: None }
  let connector = Connector::new(
    RegressionMockDialer::{ stream, count: 0 },
    provider,
  )
    .with_http2(false)
    .with_tls_config(
      TlsConfig::new("base.example").with_alpn(
        @list.List(["h2", "http/1.1"]),
      ),
    )
  let _ = connector.connect(Url::parse("https://secure.example/").unwrap()).unwrap()
  assert_eq(provider.last_config.unwrap().alpn.to_array(), ["http/1.1"])
}
