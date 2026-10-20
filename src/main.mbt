#cfg(target="native")
extern "C" fn os_exit(code : Int) -> Unit = "exit"

#cfg(not(target="native"))
fn os_exit(code : Int) -> Unit {
  let _ = code
}

/// Command-line entry point for the Feather HTTP/HTTPS client.
fn print_usage() -> Unit {
  println("Usage: feather <url>                    send a GET request")
  println("       feather <method> <url> [body]    send a request with the given method")
  println("       FEATHER_URL=<url> feather         send a GET request to FEATHER_URL")
  println("       FEATHER_PROXY=<url> feather     route requests through an HTTP proxy")
  println("       FEATHER_CA=<pem file> feather   trust an extra CA certificate bundle")
  println("       FEATHER_INSECURE=1 feather      DISABLE TLS verification (unsafe)")
  println("Methods: get, post, put, delete, head, options, patch")
}

/// Read a whole file as bytes, returning None when it cannot be read.
#cfg(target="native")
fn read_file(path : String) -> Bytes? {
  let capacity = 4 * 1024 * 1024
  let output = Bytes::new(capacity)
  let length = feather_read_file(@utf8.encode(path), output, capacity)
  if length < 0 {
    return None
  }
  Some(output.exact_view(start=0, end=length).to_owned())
}

#cfg(not(target="native"))
fn read_file(path : String) -> Bytes? {
  let _ = path
  None
}

/// Build the TLS configuration from the FEATHER_CA / FEATHER_INSECURE
/// environment variables, if either is set.
fn env_tls_config() -> TlsConfig? {
  let insecure = match @env.get_env_var("FEATHER_INSECURE") {
    Some(value) => value == "1" || value.to_lower() == "true"
    None => false
  }
  let ca_path = match @env.get_env_var("FEATHER_CA") {
    Some(value) => if value.length() > 0 { Some(value) } else { None }
    None => None
  }
  if !insecure && ca_path is None {
    return None
  }
  let mut config = TlsConfig::new("")
  if insecure {
    println("WARNING: TLS certificate verification is disabled!")
    config = config.with_verify_mode(SkipVerification)
  }
  match ca_path {
    Some(path) => match read_file(path) {
      Some(pem) => config = config.with_root_store(RootStore::new().add_certificate(pem))
      None => println("warning: could not read CA bundle: " + path)
    }
    None => ()
  }
  Some(config)
}

fn report(err : HttpError) -> Unit {
  println("error: " + @debug.to_string(err))
}

fn print_response(response : Response) -> Unit {
  println(response.version + " " + response.status.to_string())
  for header in response.headers.iter() {
    println(header.name + ": " + header.value)
  }
  println("")
  match response.text() {
    Ok(body) => println(body)
    Err(err) => report(err)
  }
}

fn run_request(method : HttpMethod, url : String, body : String) -> Bool {
  let mut client = UnifiedClient::new()
  match env_tls_config() {
    Some(config) => client = client.with_tls_config(config)
    None => ()
  }
  match @env.get_env_var("FEATHER_PROXY") {
    Some(value) => if value.length() > 0 {
      match client.with_proxy_url(value) {
        Ok(updated) => client = updated
        Err(err) => {
          report(err)
          let _ = client.close_all()
          return false
        }
      }
    }
    None => ()
  }
  let succeeded = if method == GET && body.length() == 0 {
    match client.get(url) {
      Ok(response) => {
        print_response(response)
        true
      }
      Err(err) => {
        report(err)
        false
      }
    }
  } else {
    match Url::parse(url) {
      Ok(parsed_url) => {
        let mut request = Request::new(method, parsed_url)
        if body.length() > 0 {
          request = request.with_body(@utf8.encode(body))
        }
        match client.request(request) {
          Ok(response) => {
            print_response(response)
            true
          }
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
  let mut method = ""
  let mut url = ""
  let mut body = ""
  if index < args.length() {
    let first = args[index]
    let lower = first.to_lower()
    if lower.has_prefix("http://") || lower.has_prefix("https://") {
      url = first
    } else if index + 1 < args.length() {
      method = first.to_lower()
      url = args[index + 1]
      if index + 2 < args.length() {
        body = args[index + 2]
      }
    }
  }
  (method, url, body)
}

fn wants_help(args : Array[String]) -> Bool {
  let index = if args.length() > 0 { 1 } else { 0 }
  if index >= args.length() {
    return false
  }
  let first = args[index].to_lower()
  first == "-h" || first == "--help" || first == "help"
}

fn main {
  if wants_help(@env.args()) {
    print_usage()
    return
  }
  let (method, parsed_url, body) = parse_cli_request(@env.args())
  let mut url = parsed_url
  if url.length() == 0 {
    match @env.get_env_var("FEATHER_URL") {
      Some(value) => url = value
      None => ()
    }
  }
  if url.length() == 0 {
    print_usage()
    os_exit(1)
    return
  }
  let verb = if method.length() == 0 {
    GET
  } else {
    match HttpMethod::parse(method) {
      Ok(verb) => verb
      Err(_) => {
        println("error: unsupported method '" + method + "'")
        os_exit(1)
        return
      }
    }
  }
  if !run_request(verb, url, body) {
    os_exit(1)
  }
}
