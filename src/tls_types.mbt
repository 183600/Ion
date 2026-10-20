/// TLS error types
pub enum TlsError {
  HandshakeFailed(String)
  CertificateValidationFailed(String)
  ProtocolError(String)
  InvalidConfig(String)
  IoError(String)
  ConnectionClosed
} derive(Eq, Debug)

/// TLS version
pub enum TlsVersion {
  Tls1_2
  Tls1_3
} derive(Eq, Debug)

/// Certificate verification mode
pub enum VerifyMode {
  Strict
  SkipVerification // Only for testing, should have scary name
} derive(Eq, Debug)

/// Root certificate store
pub struct RootStore {
  certificates : List[Bytes]
} derive(Eq, Debug)

pub fn RootStore::new() -> RootStore {
  RootStore::{ certificates: @list.List([]) }
}

pub fn RootStore::add_certificate(self : RootStore, cert : Bytes) -> RootStore {
  RootStore::{ certificates: self.certificates.prepend(cert) }
}

/// Client certificate for mTLS
pub struct ClientCert {
  certificate : Bytes
  private_key : Bytes
} derive(Eq, Debug)

pub fn ClientCert::new(certificate : Bytes, private_key : Bytes) -> ClientCert {
  ClientCert::{ certificate, private_key }
}

/// Key log sink for debugging
pub trait KeyLogSink {
  fn log(Self, String, Bytes) -> Unit
}

/// TLS configuration
pub struct TlsConfig {
  server_name : String
  alpn : List[String]
  root_store : RootStore
  client_auth : Option[ClientCert]
  verify : VerifyMode
  min_version : TlsVersion
  key_log : Option[&KeyLogSink]
}

pub fn TlsConfig::new(server_name : String) -> TlsConfig {
  TlsConfig::{
    server_name,
    alpn: @list.List(["http/1.1"]),
    root_store: RootStore::new(),
    client_auth: None,
    verify: Strict,
    min_version: Tls1_2,
    key_log: None,
  }
}

pub fn TlsConfig::with_alpn(self : TlsConfig, alpn : List[String]) -> TlsConfig {
  TlsConfig::{ ..self, alpn }
}

pub fn TlsConfig::with_root_store(self : TlsConfig, root_store : RootStore) -> TlsConfig {
  TlsConfig::{ ..self, root_store }
}

pub fn TlsConfig::with_client_auth(self : TlsConfig, client_auth : ClientCert) -> TlsConfig {
  TlsConfig::{ ..self, client_auth: Some(client_auth) }
}

pub fn TlsConfig::with_verify_mode(self : TlsConfig, verify : VerifyMode) -> TlsConfig {
  TlsConfig::{ ..self, verify }
}

pub fn TlsConfig::with_min_version(self : TlsConfig, min_version : TlsVersion) -> TlsConfig {
  TlsConfig::{ ..self, min_version }
}

pub fn TlsConfig::with_key_log(self : TlsConfig, key_log : &KeyLogSink) -> TlsConfig {
  TlsConfig::{ ..self, key_log: Some(key_log) }
}

fn valid_server_name(value : String) -> Bool {
  if value.length() == 0 {
    return false
  }
  for ch in value {
    if ch <= ' ' || ch == '\u{7f}' || ch == '/' || ch == '\\' || ch == '@' ||
      ch == ',' {
      return false
    }
  }
  true
}

fn valid_alpn_protocol(value : String) -> Bool {
  if value.length() == 0 {
    return false
  }
  for ch in value {
    if ch <= ' ' || ch == '\u{7f}' || ch == ',' {
      return false
    }
  }
  true
}

/// Check configuration before a provider starts a handshake.
pub fn TlsConfig::validate(self : TlsConfig) -> Result[Unit, TlsError] {
  if !valid_server_name(self.server_name) {
    return Err(InvalidConfig("Invalid TLS server name"))
  }
  for protocol in self.alpn {
    if !valid_alpn_protocol(protocol) {
      return Err(InvalidConfig("Invalid ALPN protocol"))
    }
  }
  match self.client_auth {
    Some(client) => {
      if client.certificate.length() == 0 {
        return Err(InvalidConfig("Client certificate is empty"))
      }
      if client.private_key.length() == 0 {
        return Err(InvalidConfig("Client private key is empty"))
      }
    }
    None => ()
  }
  Ok(())
}
