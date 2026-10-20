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
  println("HTTP " + response.version + " " + response.status.to_string())
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

fn main {
  let args = @env.args()
  let mut url = ""
  let mut method = ""
  let mut body = ""
  if args.length() > 0 && (args[0].has_prefix("http://") || args[0].has_prefix("https://")) {
    url = args[0]
  } else if args.length() > 1 {
    method = args[0].to_lower()
    url = args[1]
    if args.length() > 2 {
      body = args[2]
    }
  }
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
