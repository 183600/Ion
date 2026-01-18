/// TLS error types
pub enum TlsError {
  HandshakeFailed(String)
  CertificateValidationFailed(String)
  ProtocolError(String)
  InvalidConfig(String)
  IoError(String)
  ConnectionClosed
}

/// TLS version
pub enum TlsVersion {
  Tls1_2
  Tls1_3
}

/// Certificate verification mode
pub enum VerifyMode {
  Strict
  SkipVerification // Only for testing, should have scary name
}

/// Root certificate store
pub struct RootStore {
  certificates : List[Bytes]
}

pub fn RootStore::new() -> RootStore {
  RootStore::{ certificates: List::[] }
}

pub fn RootStore::add_certificate(self : RootStore, cert : Bytes) -> RootStore {
  RootStore::{ certificates: Cons(cert, self.certificates) }
}

/// Client certificate for mTLS
pub struct ClientCert {
  certificate : Bytes
  private_key : Bytes
}

/// Key log sink for debugging
pub trait KeyLogSink {
  fn log(self : KeyLogSink, label : String, secret : Bytes) -> Unit
}

/// TLS configuration
pub struct TlsConfig {
  server_name : String
  alpn : List[String]
  root_store : RootStore
  client_auth : Option[ClientCert]
  verify : VerifyMode
  min_version : TlsVersion
  key_log : Option[KeyLogSink]
}

pub fn TlsConfig::new(server_name : String) -> TlsConfig {
  TlsConfig::{
    server_name,
    alpn: List::["http/1.1"],
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

pub fn TlsConfig::with_key_log(self : TlsConfig, key_log : KeyLogSink) -> TlsConfig {
  TlsConfig::{ ..self, key_log: Some(key_log) }
}
