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
  println("       feather [options] <url>                send a request with custom options")
  println("Options:")
  println("       -X, --request <method>                 override the request method")
  println("       -H, --header <name: value>             add a request header (repeatable)")
  println("       -d, --data <data>                      send a request body (defaults to POST)")
  println("       -I, --head                             send a HEAD request")
  println("       -L, --location                         follow redirects (default)")
  println("       --no-location                          do not follow redirects")
  println("       --max-redirects <n>                    limit followed redirects (default 10)")
  println("       --timeout <milliseconds>               bound the whole request")
  println("       --http1.1                              disable HTTP/2 negotiation")
  println("       --http2                                enable HTTP/2 negotiation (default)")
  println("       -k, --insecure                         DISABLE TLS verification (unsafe)")
  println("       --ca <pem file>                        trust an extra CA certificate bundle")
  println("       --client-cert <pem file>               client certificate for mTLS")
  println("       --client-key <pem file>                client private key for mTLS")
  println("       --keylog                               print TLS key material (debug)")
  println("       --no-keylog                            disable TLS key logging")
  println("       --                                     treat remaining arguments as positional")
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

/// Build the TLS configuration from command-line overrides and the
/// FEATHER_CA / FEATHER_INSECURE / FEATHER_KEYLOG / FEATHER_CLIENT_CERT /
/// FEATHER_CLIENT_KEY environment variables. Command-line values take
/// precedence. Client-certificate problems are hard errors: a half-configured
/// mTLS pair would otherwise fail later as an opaque handshake failure against
/// a server that requires client certificates.
fn env_tls_config(overrides : CliTlsOptions) -> Result[TlsConfig?, HttpError] {
  let insecure = match overrides.insecure {
    Some(value) => value
    None =>
      match @env.get_env_var("FEATHER_INSECURE") {
        Some(value) => value == "1" || value.to_lower() == "true"
        None => false
      }
  }
  let ca_path = match overrides.ca_path {
    Some(path) => Some(path)
    None => env_path("FEATHER_CA")
  }
  let key_log = match overrides.key_log {
    Some(value) => value
    None =>
      match @env.get_env_var("FEATHER_KEYLOG") {
        Some(value) => value == "1" || value.to_lower() == "true"
        None => false
      }
  }
  let cert_path = match overrides.client_cert {
    Some(path) => Some(path)
    None => env_path("FEATHER_CLIENT_CERT")
  }
  let key_path = match overrides.client_key {
    Some(path) => Some(path)
    None => env_path("FEATHER_CLIENT_KEY")
  }
  match (cert_path, key_path) {
    (Some(_), None) =>
      return Err(TlsError(InvalidConfig(
        "a client key (FEATHER_CLIENT_KEY or --client-key) is required when a client certificate is set",
      )))
    (None, Some(_)) =>
      return Err(TlsError(InvalidConfig(
        "a client certificate (FEATHER_CLIENT_CERT or --client-cert) is required when a client key is set",
      )))
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

struct CliTlsOptions {
  insecure : Bool?
  ca_path : String?
  client_cert : String?
  client_key : String?
  key_log : Bool?
}

struct CliRequest {
  method_text : String
  url : String
  body : String
  has_body : Bool
  headers : Array[(String, String)]
  follow_redirects : Bool
  max_redirects : Int
  timeout_ms : Int
  http2 : Bool
  tls : CliTlsOptions
  help : Bool
}

fn cli_normalize_method(value : String) -> String {
  let text = value.trim().to_owned()
  let lower = text.to_lower()
  match HttpMethod::parse(lower) {
    Ok(_) => lower
    Err(_) => text
  }
}

fn cli_split_option(arg : String) -> (String, String?) {
  match arg.find("=") {
    Some(index) => (arg[0:index].to_owned(), Some(arg[index + 1:].to_owned()))
    None => (arg, None)
  }
}

fn cli_option_value(
  args : Array[String],
  index : Int,
  name : String,
  inline : String?,
) -> Result[(String, Int), String] {
  match inline {
    Some(value) => Ok((value, index + 1))
    None =>
      if index + 1 < args.length() {
        Ok((args[index + 1], index + 2))
      } else {
        Err("option '" + name + "' requires a value")
      }
  }
}

fn cli_parse_header(value : String) -> Result[(String, String), String] {
  match value.find(":") {
    Some(index) => {
      let name = value[0:index].trim().to_owned()
      let header_value = value[index + 1:].trim().to_owned()
      if name.length() == 0 {
        Err("header name cannot be empty")
      } else {
        Ok((name, header_value))
      }
    }
    None => Err("header must use the 'Name: value' form")
  }
}

fn cli_parse_nonnegative(value : String, name : String) -> Result[Int, String] {
  let text = value.trim().to_owned()
  if !is_decimal_digits(text) {
    return Err("option '" + name + "' expects a non-negative integer")
  }
  let parsed = try {
    @string.parse_int(text[:])
  } catch {
    _ => return Err("option '" + name + "' expects a non-negative integer")
  }
  if parsed < 0 {
    Err("option '" + name + "' expects a non-negative integer")
  } else {
    Ok(parsed)
  }
}

fn parse_cli_args(args : Array[String]) -> Result[CliRequest, String] {
  // The runtime argument list includes the executable name as its first entry.
  let index = if args.length() > 0 { 1 } else { 0 }
  let mut method_text = ""
  let mut url = ""
  let mut body = ""
  let mut has_body = false
  let headers : Array[(String, String)] = []
  let mut follow_redirects = true
  let mut max_redirects = 10
  let mut timeout_ms = -1
  let mut http2 = true
  let mut tls = CliTlsOptions::{
    insecure: None,
    ca_path: None,
    client_cert: None,
    client_key: None,
    key_log: None,
  }
  let mut help = false
  let mut options_done = false
  let mut position = index
  while position < args.length() {
    let arg = args[position]
    let text = arg.trim().to_owned()
    if !options_done && text == "--" {
      options_done = true
      position = position + 1
      continue
    }
    if !options_done && text.length() > 1 && text.get_char(0) == Some('-') {
      let (name, inline) = cli_split_option(text)
      if name == "-h" || name == "--help" {
        help = true
        position = position + 1
        continue
      } else if name == "-X" || name == "--request" {
        let (value, next) = match cli_option_value(args, position, name, inline) {
          Ok(value) => value
          Err(err) => return Err(err)
        }
        let normalized_method = cli_normalize_method(value)
        if normalized_method.length() == 0 {
          return Err("option '" + name + "' requires a non-empty method")
        }
        method_text = normalized_method
        position = next
        continue
      } else if name == "-H" || name == "--header" {
        let (value, next) = match cli_option_value(args, position, name, inline) {
          Ok(value) => value
          Err(err) => return Err(err)
        }
        match cli_parse_header(value) {
          Ok(header) => headers.push(header)
          Err(err) => return Err(err)
        }
        position = next
        continue
      } else if name == "-d" || name == "--data" || name == "--data-raw" {
        let (value, next) = match cli_option_value(args, position, name, inline) {
          Ok(value) => value
          Err(err) => return Err(err)
        }
        body = value
        has_body = true
        if method_text.length() == 0 {
          method_text = "post"
        }
        position = next
        continue
      } else if name == "-I" || name == "--head" {
        method_text = "head"
        position = position + 1
        continue
      } else if name == "-L" || name == "--location" {
        follow_redirects = true
        position = position + 1
        continue
      } else if name == "--no-location" || name == "--no-follow" {
        follow_redirects = false
        position = position + 1
        continue
      } else if name == "--max-redirects" {
        let (value, next) = match cli_option_value(args, position, name, inline) {
          Ok(value) => value
          Err(err) => return Err(err)
        }
        max_redirects = match cli_parse_nonnegative(value, name) {
          Ok(count) => count
          Err(err) => return Err(err)
        }
        position = next
        continue
      } else if name == "--timeout" {
        let (value, next) = match cli_option_value(args, position, name, inline) {
          Ok(value) => value
          Err(err) => return Err(err)
        }
        timeout_ms = match cli_parse_nonnegative(value, name) {
          Ok(count) => count
          Err(err) => return Err(err)
        }
        position = next
        continue
      } else if name == "-k" || name == "--insecure" {
        tls = CliTlsOptions::{ ..tls, insecure: Some(true) }
        position = position + 1
        continue
      } else if name == "--ca" {
        let (value, next) = match cli_option_value(args, position, name, inline) {
          Ok(value) => value
          Err(err) => return Err(err)
        }
        if value.length() == 0 {
          return Err("option '" + name + "' requires a non-empty path")
        }
        tls = CliTlsOptions::{ ..tls, ca_path: Some(value) }
        position = next
        continue
      } else if name == "--client-cert" {
        let (value, next) = match cli_option_value(args, position, name, inline) {
          Ok(value) => value
          Err(err) => return Err(err)
        }
        if value.length() == 0 {
          return Err("option '" + name + "' requires a non-empty path")
        }
        tls = CliTlsOptions::{ ..tls, client_cert: Some(value) }
        position = next
        continue
      } else if name == "--client-key" {
        let (value, next) = match cli_option_value(args, position, name, inline) {
          Ok(value) => value
          Err(err) => return Err(err)
        }
        if value.length() == 0 {
          return Err("option '" + name + "' requires a non-empty path")
        }
        tls = CliTlsOptions::{ ..tls, client_key: Some(value) }
        position = next
        continue
      } else if name == "--keylog" {
        tls = CliTlsOptions::{ ..tls, key_log: Some(true) }
        position = position + 1
        continue
      } else if name == "--no-keylog" {
        tls = CliTlsOptions::{ ..tls, key_log: Some(false) }
        position = position + 1
        continue
      } else if name == "--http1.1" || name == "--http1" {
        http2 = false
        position = position + 1
        continue
      } else if name == "--http2" {
        http2 = true
        position = position + 1
        continue
      } else {
        return Err("unknown option '" + name + "'")
      }
    }
    if url.length() == 0 {
      let lower = text.to_lower()
      let looks_like_url = lower.has_prefix("http://") ||
        lower.has_prefix("https://")
      if !looks_like_url && method_text.length() == 0 {
        method_text = cli_normalize_method(text)
      } else {
        url = text
      }
    } else if !has_body {
      // Request bodies are data, not configuration, and must be preserved
      // exactly.
      body = arg
      has_body = true
    } else {
      return Err("unexpected argument '" + text + "'")
    }
    position = position + 1
  }
  Ok(CliRequest::{
    method_text,
    url,
    body,
    has_body,
    headers,
    follow_redirects,
    max_redirects,
    timeout_ms,
    http2,
    tls,
    help,
  })
}

fn run_request(verb : HttpMethod, request : CliRequest) -> Bool {
  let mut client = UnifiedClient::new()
  match env_tls_config(request.tls) {
    Ok(Some(config)) => client = client.with_tls_config(config)
    Ok(None) => ()
    Err(err) => {
      report(err)
      return false
    }
  }
  if request.http2 {
    let h2c = match @env.get_env_var("FEATHER_H2C") {
      Some(value) => value == "1" || value.to_lower() == "true"
      None => false
    }
    if h2c {
      client = client.with_http2_prior_knowledge(true)
    }
  } else {
    client = client.with_http2(false)
  }
  client = client
    .with_follow_redirects(request.follow_redirects)
    .with_max_redirects(request.max_redirects)
  if request.timeout_ms >= 0 {
    client = client.with_timeout(request.timeout_ms)
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
      match Url::parse(request.url) {
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
  let succeeded = if verb == GET && !request.has_body && request.headers.length() == 0 {
    match client.get(request.url) {
      Ok(response) => print_response(response)
      Err(err) => {
        report(err)
        false
      }
    }
  } else {
    match Request::from_url(verb, request.url) {
      Ok(prepared) => {
        let mut prepared = prepared
        for (name, value) in request.headers {
          prepared = prepared.with_header(name, value)
        }
        if request.has_body {
          prepared = prepared.with_body(@utf8.encode(request.body))
        }
        match client.request(prepared) {
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
  let mut request = match parse_cli_args(command_args) {
    Ok(request) => request
    Err(err) => {
      eprintln("error: " + err)
      os_exit(1)
      return
    }
  }
  if request.help {
    print_usage()
    return
  }
  if request.url.length() == 0 {
    match @env.get_env_var("FEATHER_URL") {
      Some(value) => request = CliRequest::{ ..request, url: value.trim().to_owned() }
      None => ()
    }
  }
  if request.url.length() == 0 {
    print_usage()
    os_exit(1)
    return
  }
  let verb = if request.method_text.length() == 0 {
    GET
  } else {
    match HttpMethod::custom(request.method_text) {
      Ok(verb) => verb
      Err(_) => {
        eprintln("error: unsupported method '" + request.method_text + "'")
        os_exit(1)
        return
      }
    }
  }
  if !run_request(verb, request) {
    os_exit(1)
  }
}
