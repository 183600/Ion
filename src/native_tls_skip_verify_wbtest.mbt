#cfg(target="native")
test "native TLS ignores the root store when verification is disabled" {
  let roots = @utf8.encode("this is not a PEM certificate")
  let config = TlsConfig::new("example.com")
    .with_root_store(RootStore::new().add_certificate(roots))
    .with_verify_mode(SkipVerification)
  let provider = OpenSslTlsProvider::new()
  let ctx = provider.new_client(config).unwrap()
  let stream = regression_mock_stream("", 0, 0)
  match ctx.connect(stream) {
    Err(InvalidConfig(message)) =>
      fail("skip-verification handshake parsed the CA bundle: " + message)
    // The mock peer sends no TLS records, so the handshake itself closes.
    Err(ConnectionClosed) => ()
    Err(err) => fail("unexpected handshake error: " + @debug.to_string(err))
    Ok(_) => fail("handshake unexpectedly succeeded without peer records")
  }
}
