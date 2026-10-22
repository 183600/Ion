/// TLS error types
pub enum TlsError {
  HandshakeFailed(String)
  CertificateValidationFailed(String)
  ProtocolError(String)
  InvalidConfig(String)
  IoError(String)
  ConnectionClosed
  Timeout
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

pub fn TlsConfig::with_server_name(self : TlsConfig, server_name : String) -> TlsConfig {
  TlsConfig::{ ..self, server_name }
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

/// Validate one DNS label used as a TLS server name. Host names in
/// certificates and SNI use the LDH form; underscores are tolerated because
/// they are common in private deployments, but wildcards, percent escapes,
/// empty labels and leading/trailing hyphens are not valid here.
fn valid_dns_label(value : String) -> Bool {
  let bytes = @utf8.encode(value)
  if bytes.length() == 0 || bytes.length() > 63 {
    return false
  }
  if bytes[0] == b'-' || bytes[bytes.length() - 1] == b'-' {
    return false
  }
  for byte in bytes {
    if !((byte >= b'a' && byte <= b'z') ||
      (byte >= b'A' && byte <= b'Z') ||
      (byte >= b'0' && byte <= b'9') ||
      byte == b'-' ||
      byte == b'_') {
      return false
    }
  }
  true
}

fn valid_dns_server_name(value : String) -> Bool {
  // A single trailing dot denotes the DNS root and is allowed.
  let name = if value.length() > 1 && value.has_suffix(".") {
    value[0:value.length() - 1].to_owned()
  } else {
    value
  }
  if name.length() == 0 || @utf8.encode(name).length() > 253 {
    return false
  }
  for label in name.split(".") {
    if !valid_dns_label(label.to_owned()) {
      return false
    }
  }
  true
}

fn valid_server_name(value : String) -> Bool {
  if value.length() == 0 || @utf8.encode(value).length() > 255 {
    return false
  }
  if value.has_prefix("[") {
    if !value.has_suffix("]") {
      return false
    }
    return is_ip_literal(value[1:value.length() - 1].to_owned())
  }
  if value.contains(":") {
    return is_ipv6_literal_with_zone(value)
  }
  valid_dns_server_name(value)
}

fn valid_alpn_protocol(value : String) -> Bool {
  if value.length() == 0 {
    return false
  }
  for ch in value {
    if ch <= ' ' || ch == '\u{7f}' {
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
  let mut alpn_wire_bytes = 0
  for protocol in self.alpn {
    let length = @utf8.encode(protocol).length()
    if !valid_alpn_protocol(protocol) || length > 255 {
      return Err(InvalidConfig("Invalid ALPN protocol"))
    }
    alpn_wire_bytes = alpn_wire_bytes + 1 + length
  }
  if alpn_wire_bytes > 65535 {
    return Err(InvalidConfig("Invalid ALPN protocol list"))
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
