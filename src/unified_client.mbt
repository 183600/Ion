/// Unified HTTP/HTTPS client
pub struct UnifiedClient {
  connector : Connector
  options : ClientOptions
  mut redirect_count : Int
}

/// Client options
pub struct ClientOptions {
  user_agent : String
  timeout_ms : Int
  follow_redirects : Bool
  max_redirects : Int
}

pub fn ClientOptions::new() -> ClientOptions {
  ClientOptions::{
    user_agent: "Feather/0.1.0",
    timeout_ms: 30000,
    follow_redirects: true,
    max_redirects: 10,
  }
}

pub fn ClientOptions::with_user_agent(self : ClientOptions, user_agent : String) -> ClientOptions {
  ClientOptions::{ ..self, user_agent }
}

pub fn ClientOptions::with_timeout(self : ClientOptions, timeout_ms : Int) -> ClientOptions {
  ClientOptions::{ ..self, timeout_ms }
}

pub fn ClientOptions::with_follow_redirects(self : ClientOptions, follow_redirects : Bool) -> ClientOptions {
  ClientOptions::{ ..self, follow_redirects }
}

pub fn ClientOptions::with_max_redirects(self : ClientOptions, max_redirects : Int) -> ClientOptions {
  ClientOptions::{ ..self, max_redirects }
}

/// Create a new UnifiedClient with default options
pub fn UnifiedClient::new() -> UnifiedClient {
  let dialer = TcpDialer::new()
  let tls_provider = MockTlsProvider::new("default")
  let connector = Connector::new(dialer, tls_provider)
  let options = ClientOptions::new()

  UnifiedClient::{
    connector,
    options,
    redirect_count: 0,
  }
}

/// Create a new UnifiedClient with custom options
pub fn UnifiedClient::with_options(options : ClientOptions) -> UnifiedClient {
  let dialer = TcpDialer::new()
  let tls_provider = MockTlsProvider::new("default")
  let connector = Connector::new(dialer, tls_provider)

  UnifiedClient::{
    connector,
    options,
    redirect_count: 0,
  }
}

pub impl HttpClient for UnifiedClient with fn request(self : UnifiedClient, req : Request) -> Result[Response, HttpError] {
  self.redirect_count = 0
  self.do_request(req)
}

fn url_authority(url : Url) -> String {
  let host = if url.host.contains(":") {
    "[" + url.host + "]"
  } else {
    url.host
  }
  if (url.scheme == "https" && url.port != 443) ||
    (url.scheme == "http" && url.port != 80) {
    host + ":" + url.port.to_string()
  } else {
    host
  }
}

fn normalize_path_and_suffix(target : String) -> String {
  let mut path_end = target.length()
  match target.find("?") {
    Some(index) => if index < path_end {
      path_end = index
    }
    None => ()
  }
  match target.find("#") {
    Some(index) => if index < path_end {
      path_end = index
    }
    None => ()
  }
  let path = target.substring(start=0, end=path_end)
  let suffix = target.substring(start=path_end)
  let trailing = path.has_suffix("/") || path.has_suffix("/.") ||
    path.has_suffix("/..") || path == "." || path == ".."
  let segments = path.split("/").collect()
  let normalized : Array[String] = []
  for segment in segments {
    match segment {
      "." | "" => ()
      ".." => if normalized.length() > 0 {
        normalized.unsafe_pop_back()
      }
      _ => normalized.push(segment.to_string())
    }
  }
  let joined = normalized.join("/")
  let result = if joined.length() == 0 {
    "/"
  } else if trailing {
    "/" + joined + "/"
  } else {
    "/" + joined
  }
  result + suffix
}

fn base_without_fragment(base : Url) -> String {
  let base_str = base.scheme + "://" + url_authority(base) + base.path
  if base.query.length() > 0 {
    base_str + "?" + base.query
  } else {
    base_str
  }
}

fn resolve_redirect_url(base : Url, location : String) -> Result[Url, HttpError] {
  let location = location.trim().to_string()
  let lower = location.to_lower()
  let full = if lower.has_prefix("http://") || lower.has_prefix("https://") {
    location
  } else if location.has_prefix("//") {
    base.scheme + ":" + location
  } else if location.has_prefix("#") {
    base_without_fragment(base) + location
  } else if location.has_prefix("/") {
    base.scheme + "://" + url_authority(base) +
    normalize_path_and_suffix(location)
  } else if location.has_prefix("?") {
    base.scheme + "://" + url_authority(base) + base.path + location
  } else if location.length() == 0 {
    base.to_string()
  } else {
    let directory = match base.path.rev_find("/") {
      Some(index) => base.path.substring(start=0, end=index + 1)
      None => "/"
    }
    base.scheme + "://" + url_authority(base) +
    normalize_path_and_suffix(directory + location)
  }
  Url::parse(full)
}

fn redirect_method(status : Int, method : HttpMethod) -> (HttpMethod, Bool) {
  // Returns the method for the next request and whether the body is kept.
  match status {
    303 =>
      if method == HEAD {
        (HEAD, false)
      } else {
        (GET, false)
      }
    301 | 302 =>
      if method == POST {
        (GET, false)
      } else {
        (method, true)
      }
    _ => (method, true)
  }
}

fn drain_response(response : Response) -> Result[Unit, HttpError] {
  while true {
    let buf = @buffer.new(size_hint=4096)
    match response.body.read(buf) {
      Ok(0) => return Ok(())
      Ok(_) => ()
      Err(err) => return Err(NetworkError(err))
    }
  }
  Ok(())
}

/// Internal request implementation with redirect handling
fn do_request(self : UnifiedClient, req : Request) -> Result[Response, HttpError] {
  // Check redirect limit
  if self.redirect_count > self.options.max_redirects {
    return Err(RedirectLimitExceeded)
  }

  // Connect to the server
  let stream = match self.connector.connect(req.url) {
    Ok(stream) => stream
    Err(err) => return Err(err)
  }

  // Set timeout
  match stream.set_timeout(req.timeout_ms) {
    Ok(_) => ()
    Err(err) => {
      let _ = self.connector.close(req.url)
      return Err(NetworkError(err))
    }
  }

  // Create codec
  let codec = H1Codec::new(stream)

  // Add User-Agent header if not present
  let mut request = req
  if request.get_header("User-Agent") is None {
    request = request.with_header("User-Agent", self.options.user_agent)
  }

  // Encode and send request
  match codec.encode_request(request) {
    Ok(_) => ()
    Err(err) => {
      let _ = self.connector.close(request.url)
      return Err(err)
    }
  }

  // Decode response
  let response = match codec.decode_response() {
    Ok(response) => response
    Err(err) => {
      let _ = self.connector.close(request.url)
      return Err(err)
    }
  }

  // Handle redirects if enabled
  if self.options.follow_redirects && is_redirect(response.status) {
    let location = response.get_header("Location")

    if location is None {
      return Ok(response) // No location header, can't redirect
    }

    // Parse redirect URL
    let parsed_url = match resolve_redirect_url(request.url, location.unwrap()) {
      Ok(url) => url
      Err(_) => return Ok(response) // Invalid redirect URL
    }

    // Drain the redirect response body so the connection can be reused.
    match drain_response(response) {
      Ok(_) => ()
      Err(_) => {
        let _ = self.connector.close(request.url)
      }
    }

    self.redirect_count += 1

    let (next_method, keep_body) = redirect_method(response.status, request.method)
    let mut next_headers = request.headers.remove("Host")
    if !keep_body {
      next_headers = next_headers.remove("Content-Length")
      next_headers = next_headers.remove("Transfer-Encoding")
    }
    if parsed_url.scheme != request.url.scheme ||
      parsed_url.host != request.url.host ||
      parsed_url.port != request.url.port {
      next_headers = next_headers.remove("Authorization")
    }

    // Create new request for redirect
    let redirect_req = Request::{
      method: next_method,
      url: parsed_url,
      headers: next_headers,
      body: if keep_body { request.body } else { None },
      timeout_ms: request.timeout_ms,
    }

    // Follow redirect
    return self.do_request(redirect_req)
  }

  Ok(response)
}

/// Check if status code indicates a redirect
fn is_redirect(status : Int) -> Bool {
  status == 301 || status == 302 || status == 303 || status == 307 || status == 308
}

/// Convenience method for GET requests
pub fn UnifiedClient::get(self : UnifiedClient, url : String) -> Result[Response, HttpError] {
  let parsed_url = match Url::parse(url) {
    Ok(url) => url
    Err(err) => return Err(err)
  }
  let req = Request::new(GET, parsed_url).with_timeout(self.options.timeout_ms)
  self.redirect_count = 0
  self.do_request(req)
}

/// Convenience method for POST requests
pub fn UnifiedClient::post(self : UnifiedClient, url : String, body : Bytes) -> Result[Response, HttpError] {
  let parsed_url = match Url::parse(url) {
    Ok(url) => url
    Err(err) => return Err(err)
  }
  let req = Request::new(POST, parsed_url).with_body(body).with_timeout(self.options.timeout_ms)
  self.redirect_count = 0
  self.do_request(req)
}

/// Convenience method for PUT requests
pub fn UnifiedClient::put(self : UnifiedClient, url : String, body : Bytes) -> Result[Response, HttpError] {
  let parsed_url = match Url::parse(url) {
    Ok(url) => url
    Err(err) => return Err(err)
  }
  let req = Request::new(PUT, parsed_url).with_body(body).with_timeout(self.options.timeout_ms)
  self.redirect_count = 0
  self.do_request(req)
}

/// Convenience method for DELETE requests
pub fn UnifiedClient::delete(self : UnifiedClient, url : String) -> Result[Response, HttpError] {
  let parsed_url = match Url::parse(url) {
    Ok(url) => url
    Err(err) => return Err(err)
  }
  let req = Request::new(DELETE, parsed_url).with_timeout(self.options.timeout_ms)
  self.redirect_count = 0
  self.do_request(req)
}

/// Close all connections
pub fn UnifiedClient::close(self : UnifiedClient) -> Result[Unit, HttpError] {
  self.connector.close_all()
}

/// Global default client for convenience
pub fn default_client() -> UnifiedClient {
  UnifiedClient::new()
}
