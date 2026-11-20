/// TLS error types
pub enum TlsError {
  HandshakeFailed(String)
  CertificateVerificationFailed(String)
  InvalidCertificate(String)
  ProtocolError(String)
  UnknownError(String)
}

/// TLS version enumeration
pub enum TlsVersion {
  TLS1_2
  TLS1_3
}

/// Certificate verification mode
pub enum VerifyMode {
  Strict
  /// Warning: Only use for testing, not production!
  Insecure
}

/// TLS configuration for client connections
pub struct TlsConfig {
  server_name : String
  alpn : Array[String]
  verify_mode : VerifyMode
  min_version : TlsVersion
  max_version : TlsVersion
  // Placeholder for root certificates
  root_certs : Array[Bytes]
  // Placeholder for client certificates (mTLS)
  client_cert : Option[(Bytes, Bytes)]
  // Placeholder for key log (debugging)
  key_log : Option[String]
}

fn TlsConfig::new(server_name : String) -> TlsConfig {
  {
    server_name,
    alpn: ["http/1.1"],  // Default to HTTP/1.1
    verify_mode: Strict,
    min_version: TLS1_2,
    max_version: TLS1_3,
    root_certs: [],
    client_cert: None,
    key_log: None
  }
}

fn TlsConfig::with_alpn(self : TlsConfig, protocols : Array[String]) -> TlsConfig {
  { ..self, alpn: protocols }
}

fn TlsConfig::with_min_version(self : TlsConfig, version : TlsVersion) -> TlsConfig {
  { ..self, min_version: version }
}

fn TlsConfig::with_verify_mode(self : TlsConfig, mode : VerifyMode) -> TlsConfig {
  { ..self, verify_mode: mode }
}

/// Root certificate store
pub struct RootStore {
  certs : Array[Bytes]
}

fn RootStore::new() -> RootStore {
  { certs: [] }
}

fn RootStore::from_system() -> RootStore {
  // Placeholder - would load system root certificates
  { certs: [] }
}

fn RootStore::add_cert(self : RootStore, cert : Bytes) -> RootStore {
  { certs: self.certs.push(cert) }
}

/// Client certificate for mutual TLS (mTLS)
pub struct ClientCert {
  cert : Bytes
  key : Bytes
}

fn ClientCert::new(cert : Bytes, key : Bytes) -> ClientCert {
  { cert, key }
}

/// Key log sink for debugging TLS connections
pub trait KeyLogSink {
  fn log(self : KeyLogSink, label : String, client_random : Bytes, secret : Bytes) -> Unit
}

/// File-based key log sink (for Wireshark debugging)
pub struct FileKeyLogSink {
  path : String
  mut file : Option[File]  // Would be actual file handle in real implementation
}

fn FileKeyLogSink::new(path : String) -> FileKeyLogSink {
  { path, file: None }
}

impl KeyLogSink for FileKeyLogSink {
  fn log(self : FileKeyLogSink, label : String, client_random : Bytes, secret : Bytes) -> Unit {
    // Placeholder - would write to file in format:
    // CLIENT_RANDOM <client_random> <secret>
    println("KeyLog: \{label} \{client_random.length()} bytes")
  }
}

/// Certificate type for validation
pub struct Certificate {
  data : Bytes
  subject : String
  issuer : String
  not_before : Int64
  not_after : Int64
}

fn Certificate::parse(data : Bytes) -> Result[Certificate, String] {
  // Placeholder - would parse DER/PEM certificate
  Ok({
    data,
    subject: "placeholder.subject",
    issuer: "placeholder.issuer",
    not_before: 0L,
    not_after: 0L
  })
}
