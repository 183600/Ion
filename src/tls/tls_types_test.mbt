test "TlsConfig creation" {
  let config = TlsConfig::new("example.com")
  assert_eq!(config.server_name, "example.com")
  assert_eq!(config.alpn, List::["http/1.1"])
  assert_eq!(config.verify, Strict)
  assert_eq!(config.min_version, Tls1_2)
}

test "TlsConfig with custom ALPN" {
  let config = TlsConfig::new("example.com")
  let custom_config = config.with_alpn(List::["h2", "http/1.1"])
  assert_eq!(custom_config.alpn, List::["h2", "http/1.1"])
}

test "TlsConfig with verify mode" {
  let config = TlsConfig::new("example.com")
  let insecure_config = config.with_verify_mode(SkipVerification)
  assert_eq!(insecure_config.verify, SkipVerification)
}

test "RootStore operations" {
  let store = RootStore::new()
  assert_eq!(store.certificates.length(), 0)
  
  let cert = Bytes::from_string("mock certificate")
  let new_store = store.add_certificate(cert)
  assert_eq!(new_store.certificates.length(), 1)
}

test "ClientCert creation" {
  let cert = Bytes::from_string("certificate")
  let key = Bytes::from_string("private key")
  let client_cert = ClientCert::{ certificate: cert, private_key: key }
  
  assert_eq!(client_cert.certificate, cert)
  assert_eq!(client_cert.private_key, key)
}
