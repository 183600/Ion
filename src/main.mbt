#cfg(target="native")
extern "C" fn os_exit(code : Int) -> Unit = "exit"

#cfg(target="js")
extern "js" fn os_exit(code : Int) -> Unit =
  #| function(code) { process.exit(code) }

#cfg(target="wasm")
fn os_exit(code : Int) -> Unit = "wasi_snapshot_preview1" "proc_exit"

#cfg(target="wasm-gc")
fn os_exit(code : Int) -> Unit = "__moonbit_sys_unstable" "exit"

/// The runtime argument list reduced to one executable prefix entry. Native
/// and WASI hosts report a single executable entry, while Node reports both
/// the Node binary and the script path; dropping the Node binary keeps the
/// parser's fixed one-entry skip pointed at the first user argument.
#cfg(target="js")
fn cli_command_args() -> Array[String] {
  let args = @env.args()
  let result : Array[String] = []
  let mut index = 1
  while index < args.length() {
    result.push(args[index])
    index = index + 1
  }
  result
}

#cfg(not(target="js"))
fn cli_command_args() -> Array[String] {
  @env.args()
}

/// Command-line entry point for the Feather HTTP/HTTPS client.
fn print_usage() -> Unit {
  println("Usage: feather <url>                          send a GET request")
  println("       feather <method> <url> [body]          send a request with the given method")
  println("       FEATHER_URL=<url> feather              send a GET request to FEATHER_URL")
  println("       FEATHER_PROXY=<url> feather            route through an HTTP(S) or SOCKS5 proxy")
  println("       FEATHER_NO_PROXY=<list> feather        comma-separated hosts to reach directly")
  println("       HTTPS_PROXY/http_proxy/NO_PROXY        standard proxy variables used when FEATHER_PROXY is unset")
  println("       FEATHER_CA=<pem file> feather          trust an extra CA certificate bundle")
  println("       FEATHER_CLIENT_CERT=<pem file>         client certificate for mTLS")
  println("       FEATHER_CLIENT_KEY=<pem file>          client private key for mTLS")
  println("       FEATHER_INSECURE=1 feather             DISABLE TLS verification (unsafe)")
  println("       FEATHER_KEYLOG=1 feather               print TLS key material (debug)")
  println("       FEATHER_H2C=1 feather                  use HTTP/2 prior knowledge for http://")
  println("Methods: get, post, put, delete, head, options, patch, trace, connect,")
  println("         or any valid extension token such as PROPFIND")
}

/// Prints each TLS key-log line so the captured secrets can be inspected (or
/// piped into a tool such as Wireshark's SSLKEYLOGFILE).
struct PrintKeyLogSink {}

pub impl KeyLogSink for PrintKeyLogSink with fn log(
  self : PrintKeyLogSink,
  environment : String,
  keylog : Bytes,
) -> Unit {
  let _ = self
  let _ = environment
  println(@utf8.decode_lossy(keylog))
}

/// Read a whole file as bytes, returning None when it cannot be read.
#cfg(target="native")
fn read_file(path : String) -> Bytes? {
  let initial_capacity = 4 * 1024 * 1024
  let max_capacity = 64 * 1024 * 1024
  // ENOSPC is 28 on both Linux and macOS. Grow the buffer instead of
  // rejecting a valid CA bundle or client key solely because it is large.
  let enospc = -28
  let mut capacity = initial_capacity
  while true {
    let output = Bytes::new(capacity)
    let length = feather_read_file(@utf8.encode(path), output, capacity)
    if length >= 0 {
      return Some(output.exact_view(start=0, end=length).to_owned())
    }
    if length != enospc || capacity >= max_capacity {
      return None
    }
    let doubled = capacity * 2
    capacity = if doubled > max_capacity { max_capacity } else { doubled }
  }
  None
}

#cfg(not(target="native"))
fn read_file(path : String) -> Bytes? {
  let _ = path
  None
}

/// Read a non-empty path from the environment.
fn env_path(name : String) -> String? {
  match @env.get_env_var(name) {
    Some(value) => if value.length() > 0 { Some(value) } else { None }
    None => None
  }
}

/// Build the TLS configuration from the FEATHER_CA / FEATHER_INSECURE /
/// FEATHER_KEYLOG / FEATHER_CLIENT_CERT / FEATHER_CLIENT_KEY environment
/// variables, if any is set. Client-certificate problems are hard errors:
/// a half-configured mTLS pair would otherwise fail later as an opaque
/// handshake failure against a server that requires client certificates.
fn env_tls_config() -> Result[TlsConfig?, HttpError] {
  let insecure = match @env.get_env_var("FEATHER_INSECURE") {
    Some(value) => value == "1" || value.to_lower() == "true"
    None => false
  }
  let ca_path = env_path("FEATHER_CA")
  let key_log = match @env.get_env_var("FEATHER_KEYLOG") {
    Some(value) => value == "1" || value.to_lower() == "true"
    None => false
  }
  let cert_path = env_path("FEATHER_CLIENT_CERT")
  let key_path = env_path("FEATHER_CLIENT_KEY")
  match (cert_path, key_path) {
    (Some(_), None) =>
      return Err(TlsError(InvalidConfig("FEATHER_CLIENT_KEY is required when FEATHER_CLIENT_CERT is set")))
    (None, Some(_)) =>
      return Err(TlsError(InvalidConfig("FEATHER_CLIENT_CERT is required when FEATHER_CLIENT_KEY is set")))
    (None, None) => ()
    (Some(_), Some(_)) => ()
  }
  if !insecure && ca_path is None && !key_log && cert_path is None {
    return Ok(None)
  }
  // The CLI client enables HTTP/2 by default. An environment-derived TLS
  // configuration must still advertise it, otherwise FEATHER_CA or
  // FEATHER_INSECURE would silently downgrade every request to HTTP/1.1.
  let mut config = TlsConfig::new("")
    .with_alpn(@list.List(["h2", "http/1.1"]))
  if insecure {
    eprintln("WARNING: TLS certificate verification is disabled!")
    config = config.with_verify_mode(SkipVerification)
  }
  match ca_path {
    Some(path) => match read_file(path) {
      Some(pem) => config = config.with_root_store(RootStore::new().add_certificate(pem))
      None => return Err(TlsError(InvalidConfig("could not read CA bundle: " + path)))
    }
    None => ()
  }
  if key_log {
    config = config.with_key_log(PrintKeyLogSink::{})
  }
  match (cert_path, key_path) {
    (Some(cert), Some(key)) =>
      match (read_file(cert), read_file(key)) {
        (Some(cert_pem), Some(key_pem)) =>
          config = config.with_client_auth(ClientCert::new(cert_pem, key_pem))
        (None, _) => return Err(TlsError(InvalidConfig("could not read client certificate: " + cert)))
        (_, None) => return Err(TlsError(InvalidConfig("could not read client private key: " + key)))
      }
    (_, _) => ()
  }
  Ok(Some(config))
}

fn report(err : HttpError) -> Unit {
  eprintln("error: " + @debug.to_string(err))
}

fn print_response(response : Response, tunnel? : Bool) -> Bool {
  println(response.version + " " + response.status.to_string())
  for header in response.headers.iter() {
    println(header.name + ": " + header.value)
  }
  println("")
  // A switched protocol (101) or a successful CONNECT is an interactive byte
  // stream, not a response body. Reading it as text would block until the peer
  // closes the tunnel, so print the response head and discard the stream.
  if tunnel.unwrap_or(false) || response.status == 101 {
    response.close()
    return true
  }
  match response.text() {
    Ok(body) => {
      println(body)
      true
    }
    Err(err) => {
      report(err)
      false
    }
  }
}

/// Split a `NO_PROXY`-style comma-separated list into individual patterns.
fn split_proxy_bypass(value : String) -> Array[String] {
  let patterns : Array[String] = []
  for part in value.split(",") {
    let pattern = part.trim()
    if pattern.length() > 0 {
      patterns.push(pattern.to_owned())
    }
  }
  patterns
}

/// The CLI's proxy exclusion list. An explicit FEATHER_NO_PROXY value wins,
/// but an empty/whitespace-only value means it was not set, so the standard
/// NO_PROXY variable still applies. This matches how an empty proxy variable
/// is treated as unset elsewhere in the CLI.
fn cli_proxy_bypass() -> Array[String] {
  match @env.get_env_var("FEATHER_NO_PROXY") {
    Some(value) => {
      let patterns = split_proxy_bypass(value)
      if patterns.length() > 0 {
        patterns
      } else {
        Proxy::no_proxy_from_env()
      }
    }
    None => Proxy::no_proxy_from_env()
  }
}

fn run_request(verb : HttpMethod, url : String, body : String) -> Bool {
  let mut client = UnifiedClient::new()
  match env_tls_config() {
    Ok(Some(config)) => client = client.with_tls_config(config)
    Ok(None) => ()
    Err(err) => {
      report(err)
      return false
    }
  }
  let h2c = match @env.get_env_var("FEATHER_H2C") {
    Some(value) => value == "1" || value.to_lower() == "true"
    None => false
  }
  if h2c {
    client = client.with_http2_prior_knowledge(true)
  }
  let explicit_proxy = match @env.get_env_var("FEATHER_PROXY") {
    Some(value) => if value.length() > 0 {
      Some(value)
    } else {
      None
    }
    None => None
  }
  match explicit_proxy {
    Some(value) => {
      match client.with_proxy_url(value) {
        Ok(updated) => client = updated
        Err(err) => {
          report(err)
          let _ = client.close_all()
          return false
        }
      }
      let bypass = cli_proxy_bypass()
      if bypass.length() > 0 {
        client = client.with_proxy_bypass(bypass)
      }
    }
    None =>
      match Url::parse(url) {
        Ok(parsed) =>
          match Proxy::from_env(parsed) {
            Ok(Some(proxy)) => {
              client = client.with_proxy(proxy)
              let bypass = cli_proxy_bypass()
              if bypass.length() > 0 {
                client = client.with_proxy_bypass(bypass)
              }
            }
            Ok(None) => ()
            Err(err) => {
              report(err)
              let _ = client.close_all()
              return false
            }
          }
        Err(_) => ()
      }
  }
  let succeeded = if verb == GET && body.length() == 0 {
    match client.get(url) {
      Ok(response) => print_response(response)
      Err(err) => {
        report(err)
        false
      }
    }
  } else {
    match Request::from_url(verb, url) {
      Ok(request) => {
        let request = if body.length() > 0 {
          request.with_body(@utf8.encode(body))
        } else {
          request
        }
        match client.request(request) {
          Ok(response) =>
            print_response(
              response,
              tunnel=verb == CONNECT && response.is_success(),
            )
          Err(err) => {
            report(err)
            false
          }
        }
      }
      Err(err) => {
        report(err)
        false
      }
    }
  }
  let _ = client.close_all()
  succeeded
}

fn parse_cli_request(args : Array[String]) -> (String, String, String) {
  // The runtime argument list includes the executable name as its first entry.
  let index = if args.length() > 0 { 1 } else { 0 }
  let mut method_text = ""
  let mut url = ""
  let mut body = ""
  if index < args.length() {
    // Whitespace around a URL or method is a common shell/ environment
    // accident and is never meaningful in either value.
    let first = args[index].trim().to_owned()
    let lower = first.to_lower()
    if lower.has_prefix("http://") || lower.has_prefix("https://") {
      url = first
    } else {
      // Standard methods are case-insensitive and normalized to lower case for
      // the CLI's convenience. Extension methods are case-sensitive tokens, so
      // preserve their original spelling for `HttpMethod::custom`.
      method_text = match HttpMethod::parse(lower) {
        Ok(_) => lower
        Err(_) => first
      }
      if index + 1 < args.length() {
        url = args[index + 1].trim().to_owned()
        if index + 2 < args.length() {
          body = args[index + 2]
        }
      }
    }
  }
  (method_text, url, body)
}

fn wants_help(args : Array[String]) -> Bool {
  let index = if args.length() > 0 { 1 } else { 0 }
  if index >= args.length() {
    return false
  }
  let first = args[index].trim().to_lower()
  first == "-h" || first == "--help" || first == "help"
}

fn main {
  let command_args = cli_command_args()
  if wants_help(command_args) {
    print_usage()
    return
  }
  let (method_text, parsed_url, body) = parse_cli_request(command_args)
  let mut url = parsed_url
  if url.length() == 0 {
    match @env.get_env_var("FEATHER_URL") {
      Some(value) => url = value.trim().to_owned()
      None => ()
    }
  }
  if url.length() == 0 {
    print_usage()
    os_exit(1)
    return
  }
  let verb = if method_text.length() == 0 {
    GET
  } else {
    match HttpMethod::custom(method_text) {
      Ok(verb) => verb
      Err(_) => {
        eprintln("error: unsupported method '" + method_text + "'")
        os_exit(1)
        return
      }
    }
  }
  if !run_request(verb, url, body) {
    os_exit(1)
  }
}
