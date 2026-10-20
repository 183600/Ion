/// Command-line entry point for the Feather HTTP/HTTPS client.
fn print_usage() -> Unit {
  println("Usage: feather <url>             send a GET request")
  println("       feather post <url> [body]  send a POST request")
  println("       FEATHER_URL=<url> feather  send a GET request to FEATHER_URL")
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

fn run_get(url : String) -> Unit {
  let client = UnifiedClient::new()
  match client.get(url) {
    Ok(response) => print_response(response)
    Err(err) => report(err)
  }
  let _ = client.close_all()
}

fn run_post(url : String, body : String) -> Unit {
  let client = UnifiedClient::new()
  match client.post(url, @utf8.encode(body)) {
    Ok(response) => print_response(response)
    Err(err) => report(err)
  }
  let _ = client.close_all()
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

fn main {
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
    return
  }
  if method == "post" {
    run_post(url, body)
  } else {
    run_get(url)
  }
}
