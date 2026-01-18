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
  self.do_request(req)
}

/// Internal request implementation with redirect handling
fn do_request(self : UnifiedClient, req : Request) -> Result[Response, HttpError] {
  // Check redirect limit
  if self.redirect_count > self.options.max_redirects {
    return Err(RedirectLimitExceeded)
  }
  
  // Connect to the server
  let stream_result = self.connector.connect(req.url)
  
  if stream_result.is_err() {
    return stream_result.unwrap_err()
  }
  
  let stream = stream_result.unwrap()
  
  // Set timeout
  stream.set_timeout(req.timeout_ms)
  
  // Create codec
  let codec = H1Codec::new(stream)
  
  // Add User-Agent header if not present
  let mut request = req
  if request.get_header("User-Agent").is_none() {
    request = request.with_header("User-Agent", self.options.user_agent)
  }
  
  // Encode and send request
  let encode_result = codec.encode_request(request)
  
  if encode_result.is_err() {
    return encode_result.unwrap_err()
  }
  
  // Decode response
  let response_result = codec.decode_response()
  
  if response_result.is_err() {
    return response_result.unwrap_err()
  }
  
  let response = response_result.unwrap()
  
  // Handle redirects if enabled
  if self.options.follow_redirects && is_redirect(response.status) {
    self.redirect_count += 1
    
    let location = response.get_header("Location")
    
    if location.is_none() {
      return Ok(response) // No location header, can't redirect
    }
    
    let location_url = location.unwrap()
    let redirect_url = if location_url.starts_with("http") {
      location_url
    } else {
      // Relative URL, construct full URL
      req.url.scheme + "://" + req.url.host + ":" + req.url.port.to_string() + location_url
    }
    
    // Parse redirect URL
    let parsed_url = Url::parse(redirect_url)
    
    if parsed_url.is_err() {
      return Ok(response) // Invalid redirect URL
    }
    
    // Create new request for redirect
    let redirect_req = Request::new(GET, parsed_url.unwrap())
      .with_header("User-Agent", self.options.user_agent)
      .with_timeout(self.options.timeout_ms)
    
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
  let parsed_url = Url::parse(url)?
  let req = Request::new(GET, parsed_url)
  self.do_request(req)
}

/// Convenience method for POST requests
pub fn UnifiedClient::post(self : UnifiedClient, url : String, body : Bytes) -> Result[Response, HttpError] {
  let parsed_url = Url::parse(url)?
  let req = Request::new(POST, parsed_url).with_body(body)
  self.do_request(req)
}

/// Convenience method for PUT requests
pub fn UnifiedClient::put(self : UnifiedClient, url : String, body : Bytes) -> Result[Response, HttpError] {
  let parsed_url = Url::parse(url)?
  let req = Request::new(PUT, parsed_url).with_body(body)
  self.do_request(req)
}

/// Convenience method for DELETE requests
pub fn UnifiedClient::delete(self : UnifiedClient, url : String) -> Result[Response, HttpError] {
  let parsed_url = Url::parse(url)?
  let req = Request::new(DELETE, parsed_url)
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
