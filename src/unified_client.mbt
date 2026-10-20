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
} derive(Eq, Debug)

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
  ClientOptions::{ ..self, timeout_ms: if timeout_ms < 0 { 0 } else { timeout_ms } }
}

pub fn ClientOptions::with_follow_redirects(self : ClientOptions, follow_redirects : Bool) -> ClientOptions {
  ClientOptions::{ ..self, follow_redirects }
}

pub fn ClientOptions::with_max_redirects(self : ClientOptions, max_redirects : Int) -> ClientOptions {
  ClientOptions::{ ..self, max_redirects: if max_redirects < 0 { 0 } else { max_redirects } }
}

#cfg(target="native")
fn default_client_dialer(timeout_ms : Int) -> NativeTcpDialer {
  NativeTcpDialer::with_timeout(timeout_ms)
}

#cfg(not(target="native"))
fn default_client_dialer(timeout_ms : Int) -> TcpDialer {
  TcpDialer::with_timeout(timeout_ms)
}

#cfg(target="native")
fn default_client_tls_provider() -> OpenSslTlsProvider {
  OpenSslTlsProvider::new()
}

#cfg(not(target="native"))
fn default_client_tls_provider() -> MockTlsProvider {
  MockTlsProvider::new("default")
}

/// Create a new UnifiedClient with default options
pub fn UnifiedClient::new() -> UnifiedClient {
  let options = ClientOptions::new()
  let dialer = default_client_dialer(options.timeout_ms)
  let tls_provider = default_client_tls_provider()
  let connector = Connector::new(dialer, tls_provider).with_timeout(options.timeout_ms)

  UnifiedClient::{
    connector,
    options,
    redirect_count: 0,
  }
}

/// Create a new UnifiedClient with custom options
pub fn UnifiedClient::with_options(options : ClientOptions) -> UnifiedClient {
  let dialer = default_client_dialer(options.timeout_ms)
  let tls_provider = default_client_tls_provider()
  let connector = Connector::new(dialer, tls_provider).with_timeout(options.timeout_ms)

  UnifiedClient::{
    connector,
    options,
    redirect_count: 0,
  }
}

/// Build a client with an explicit dialer and TLS provider.
pub fn UnifiedClient::with_transport(
  dialer : &Dialer,
  tls_provider : &TlsProvider,
  options : ClientOptions,
) -> UnifiedClient {
  UnifiedClient::{
    connector: Connector::new(dialer, tls_provider).with_timeout(options.timeout_ms),
    options,
    redirect_count: 0,
  }
}

/// Close every pooled connection owned by this client.
pub fn UnifiedClient::close_all(self : UnifiedClient) -> Result[Unit, HttpError] {
  self.connector.close_all()
}

/// Replace the TLS configuration used for HTTPS connections.
pub fn UnifiedClient::with_tls_config(
  self : UnifiedClient,
  config : TlsConfig,
) -> UnifiedClient {
  let _ = self.connector.close_all()
  let connector = Connector::new(
    self.connector.dialer,
    self.connector.tls_provider,
  ).with_timeout(self.connector.timeout_ms).with_tls_config(config)
  UnifiedClient::{
    connector,
    options: self.options,
    redirect_count: 0,
  }
}

pub impl HttpClient for UnifiedClient with fn request(self : UnifiedClient, req : Request) -> Result[Response, HttpError] {
  self.redirect_count = 0
  self.do_request(req)
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
  let path = target[0:path_end].to_owned()
  let suffix = target[path_end:].to_owned()
  let trailing = path.has_suffix("/") || path.has_suffix("/.") ||
    path.has_suffix("/..") || path == "." || path == ".."
  let segments = path.split("/").collect()
  let total = segments.length()
  let normalized : Array[String] = []
  let mut index = 0
  for segment in segments {
    let is_first = index == 0
    let is_last = index == total - 1
    index = index + 1
    match segment {
      "." => ()
      ".." => if normalized.length() > 0 {
        normalized.unsafe_pop_back()
      }
      "" => if !is_first && !is_last {
        normalized.push("")
      }
      _ => normalized.push(segment.to_owned())
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

fn resolve_redirect_url(base : Url, location : String) -> Result[Url, HttpError] {
  let location = location.trim().to_owned()
  let lower = location.to_lower()
  let full = if lower.has_prefix("http://") || lower.has_prefix("https://") {
    location
  } else if location.has_prefix("//") {
    base.scheme + ":" + location
  } else if location.has_prefix("#") {
    base.origin() + base.request_target() + location
  } else if location.has_prefix("/") {
    base.origin() + normalize_path_and_suffix(location)
  } else if location.has_prefix("?") {
    let path = if base.path.length() == 0 {
      "/"
    } else if base.path.has_prefix("/") {
      base.path
    } else {
      "/" + base.path
    }
    base.origin() + path + location
  } else if location.length() == 0 {
    base.to_string()
  } else {
    let directory = match base.path.rev_find("/") {
      Some(index) => base.path[0:index + 1].to_owned()
      None => "/"
    }
    base.origin() + normalize_path_and_suffix(directory + location)
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
    let buf = Buffer(size_hint=4096)
    match response.body.read(buf) {
      Ok(0) => return Ok(())
      Ok(count) => {
        if count < 0 {
          return Err(NetworkError(ReadError("invalid read count")))
        }
        if buf.length() == 0 {
          return Err(NetworkError(ReadError("stream returned no data")))
        }
      }
      Err(err) => return Err(NetworkError(err))
    }
  }
  Ok(())
}

fn request_can_be_retried(method : HttpMethod) -> Bool {
  match method {
    GET => true
    HEAD => true
    PUT => true
    DELETE => true
    OPTIONS => true
    _ => false
  }
}

/// Internal request implementation with redirect handling
fn UnifiedClient::do_request(self : UnifiedClient, req : Request) -> Result[Response, HttpError] {
  self.do_request_once(req, true)
}

fn UnifiedClient::do_request_once(
  self : UnifiedClient,
  req : Request,
  allow_retry : Bool,
) -> Result[Response, HttpError] {
  // Connect to the server
  let (stream, lease) = match self.connector.checkout(req.url) {
    Ok(stream) => stream
    Err(err) => return Err(err)
  }

  // Set timeout, falling back to the client default when the request uses it.
  let timeout_ms = if req.timeout_explicit {
    req.timeout_ms
  } else {
    self.options.timeout_ms
  }
  match stream.set_timeout(timeout_ms) {
    Ok(_) => ()
    Err(err) => {
      let _ = self.connector.close(req.url)
      if allow_retry && lease.reused && request_can_be_retried(req.method) {
        return self.do_request_once(req, false)
      }
      return Err(NetworkError(err))
    }
  }

  // Create codec
  let codec = H1Codec::new_with_completion(
    stream,
    fn(reusable) { lease.release(reusable) },
  )

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
      if allow_retry && lease.reused && request_can_be_retried(request.method) &&
        err is NetworkError(_) {
        return self.do_request_once(req, false)
      }
      return Err(err)
    }
  }

  // Decode response
  let response = match codec.decode_response(head=request.method == HEAD) {
    Ok(response) => response
    Err(err) => {
      let _ = self.connector.close(request.url)
      if allow_retry && lease.reused && request_can_be_retried(request.method) {
        return self.do_request_once(req, false)
      }
      return Err(err)
    }
  }

  // Handle redirects if enabled
  if self.options.follow_redirects && is_redirect(response.status) {
    let location = response.get_header("Location")

    if location is None {
      return Ok(response) // No location header, can't redirect
    }
    if location.unwrap().trim().length() == 0 {
      return Ok(response)
    }

    // Parse redirect URL
    let parsed_url = match resolve_redirect_url(request.url, location.unwrap()) {
      Ok(url) => url
      Err(_) => return Ok(response) // Invalid redirect URL
    }

    if self.redirect_count >= self.options.max_redirects {
      let _ = self.connector.close(request.url)
      return Err(RedirectLimitExceeded)
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
      next_headers = next_headers
        .remove("Content-Length")
        .remove("Transfer-Encoding")
        .remove("Content-Type")
        .remove("Content-Encoding")
        .remove("Content-Language")
        .remove("Content-Location")
        .remove("Expect")
        .remove("Trailer")
    }
    if parsed_url.scheme.to_lower() != request.url.scheme.to_lower() ||
      parsed_url.host.to_lower() != request.url.host.to_lower() ||
      parsed_url.port != request.url.port {
      next_headers = next_headers
        .remove("Authorization")
        .remove("Proxy-Authorization")
        .remove("Cookie")
    }

    // Create new request for redirect
    let redirect_req = Request::{
      method: next_method,
      url: parsed_url,
      headers: next_headers,
      body: if keep_body { request.body } else { None },
      timeout_ms: request.timeout_ms,
      timeout_explicit: request.timeout_explicit,
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

/// Send a form-encoded POST request.
pub fn UnifiedClient::post_form(
  self : UnifiedClient,
  url : String,
  fields : Array[(String, String)],
) -> Result[Response, HttpError] {
  let parsed_url = match Url::parse(url) {
    Ok(url) => url
    Err(err) => return Err(err)
  }
  self.request(Request::new(POST, parsed_url).with_form(fields))
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

/// Convenience method for HEAD requests
pub fn UnifiedClient::head(self : UnifiedClient, url : String) -> Result[Response, HttpError] {
  let parsed_url = match Url::parse(url) {
    Ok(url) => url
    Err(err) => return Err(err)
  }
  let req = Request::new(HEAD, parsed_url).with_timeout(self.options.timeout_ms)
  self.redirect_count = 0
  self.do_request(req)
}

/// Convenience method for OPTIONS requests
pub fn UnifiedClient::options(self : UnifiedClient, url : String) -> Result[Response, HttpError] {
  let parsed_url = match Url::parse(url) {
    Ok(url) => url
    Err(err) => return Err(err)
  }
  let req = Request::new(OPTIONS, parsed_url).with_timeout(self.options.timeout_ms)
  self.redirect_count = 0
  self.do_request(req)
}

/// Convenience method for PATCH requests
pub fn UnifiedClient::patch(self : UnifiedClient, url : String, body : Bytes) -> Result[Response, HttpError] {
  let parsed_url = match Url::parse(url) {
    Ok(url) => url
    Err(err) => return Err(err)
  }
  let req = Request::new(PATCH, parsed_url).with_body(body).with_timeout(self.options.timeout_ms)
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
