test "TlsConfig creation" {
  let config = TlsConfig::new("example.com")
  assert_eq(config.server_name, "example.com")
  assert_eq(config.alpn, @list.List(["http/1.1"]))
  assert_eq(config.verify, Strict)
  assert_eq(config.min_version, Tls1_2)
}

test "TlsConfig with custom ALPN" {
  let config = TlsConfig::new("example.com")
  let custom_config = config.with_alpn(@list.List(["h2", "http/1.1"]))
  assert_eq(custom_config.alpn, @list.List(["h2", "http/1.1"]))
}

test "TlsConfig with verify mode" {
  let config = TlsConfig::new("example.com")
  let insecure_config = config.with_verify_mode(SkipVerification)
  assert_eq(insecure_config.verify, SkipVerification)
}

test "RootStore operations" {
  let store = RootStore::new()
  assert_eq(store.certificates.length(), 0)
  
  let cert = @utf8.encode("mock certificate")
  let new_store = store.add_certificate(cert)
  assert_eq(new_store.certificates.length(), 1)
}

test "ClientCert creation" {
  let cert = @utf8.encode("certificate")
  let key = @utf8.encode("private key")
  let client_cert = ClientCert::{ certificate: cert, private_key: key }
  
  assert_eq(client_cert.certificate, cert)
  assert_eq(client_cert.private_key, key)
}
///|
test "TLS validation rejects oversized ALPN protocol names" {
  let long_protocol = "a".repeat(256)
  let config = TlsConfig::new("example.com").with_alpn(@list.List([long_protocol]))
  assert_true(config.validate() is Err(InvalidConfig(_)))
}
