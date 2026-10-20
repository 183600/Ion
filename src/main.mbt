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
  println("Methods: get, post, put, delete, head, options, patch")
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
  let client = UnifiedClient::new()
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
