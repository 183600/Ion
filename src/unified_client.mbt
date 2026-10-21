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
  max_response_body_bytes : Int
} derive(Eq, Debug)

pub fn ClientOptions::new() -> ClientOptions {
  ClientOptions::{
    user_agent: "Feather/0.1.0",
    timeout_ms: 30000,
    follow_redirects: true,
    max_redirects: 10,
    max_response_body_bytes: DEFAULT_MAX_BODY_BYTES,
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

/// Cap the number of body bytes read from a single response. A value below 1 is
/// clamped to 0, which rejects any non-empty body.
pub fn ClientOptions::with_max_response_body_bytes(
  self : ClientOptions,
  max_response_body_bytes : Int,
) -> ClientOptions {
  ClientOptions::{
    ..self,
    max_response_body_bytes: if max_response_body_bytes < 0 { 0 } else { max_response_body_bytes },
  }
}

#cfg(target="native")
fn default_client_dialer(timeout_ms : Int) -> NativeTcpDialer {
  NativeTcpDialer::with_timeout(timeout_ms)
}

#cfg(not(target="native"))
fn default_client_dialer(timeout_ms : Int) -> UnavailableTcpDialer {
  UnavailableTcpDialer::with_timeout(timeout_ms)
}

#cfg(target="native")
fn default_client_tls_provider() -> OpenSslTlsProvider {
  OpenSslTlsProvider::new()
}

#cfg(not(target="native"))
fn default_client_tls_provider() -> UnavailableTlsProvider {
  UnavailableTlsProvider::new()
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

/// Cap the number of simultaneously open connections per host. A value below 1
/// means unlimited (the default).
pub fn UnifiedClient::with_max_connections_per_host(
  self : UnifiedClient,
  max_connections : Int,
) -> UnifiedClient {
  let _ = self.connector.with_max_connections_per_host(max_connections)
  UnifiedClient::{
    connector: self.connector,
    options: self.options,
    redirect_count: 0,
  }
}

/// Discard pooled connections idle for longer than `idle_timeout_ms`. A value
/// below 1 disables idle eviction.
pub fn UnifiedClient::with_idle_timeout(
  self : UnifiedClient,
  idle_timeout_ms : Int,
) -> UnifiedClient {
  let _ = self.connector.with_idle_timeout(idle_timeout_ms)
  UnifiedClient::{
    connector: self.connector,
    options: self.options,
    redirect_count: 0,
  }
}

/// Cap the number of idle (keep-alive) connections retained per host.
pub fn UnifiedClient::with_max_idle_per_host(
  self : UnifiedClient,
  max_idle : Int,
) -> UnifiedClient {
  let _ = self.connector.with_max_idle_per_host(max_idle)
  UnifiedClient::{
    connector: self.connector,
    options: self.options,
    redirect_count: 0,
  }
}

/// Enable the built-in cookie jar. Cookies set by responses are stored and
/// replayed on later requests that match their domain, path and security
/// attributes.
pub fn UnifiedClient::with_cookies(self : UnifiedClient) -> UnifiedClient {
  let _ = self.connector.with_cookies(true)
  UnifiedClient::{
    connector: self.connector,
    options: self.options,
    redirect_count: 0,
  }
}

/// Replace the cookie jar and enable cookie handling.
pub fn UnifiedClient::with_cookie_jar(
  self : UnifiedClient,
  jar : CookieJar,
) -> UnifiedClient {
  let _ = self.connector.with_cookie_jar(jar)
  UnifiedClient::{
    connector: self.connector,
    options: self.options,
    redirect_count: 0,
  }
}

/// The client's cookie jar.
pub fn UnifiedClient::cookie_jar(self : UnifiedClient) -> CookieJar {
  self.connector.cookie_jar()
}

/// Replace the TLS configuration used for HTTPS connections.
pub fn UnifiedClient::with_tls_config(
  self : UnifiedClient,
  config : TlsConfig,
) -> UnifiedClient {
  UnifiedClient::{
    connector: self.connector.with_tls_config(config),
    options: self.options,
    redirect_count: 0,
  }
}

/// Route HTTP requests through a forward proxy and tunnel HTTPS requests with
/// `CONNECT`. Existing pooled connections are closed because they were made
/// directly.
pub fn UnifiedClient::with_proxy(self : UnifiedClient, proxy : Proxy) -> UnifiedClient {
  UnifiedClient::{
    connector: self.connector.with_proxy(proxy),
    options: self.options,
    redirect_count: 0,
  }
}

/// Route HTTP requests through the proxy described by `url`
/// (`http://[user:password@]host[:port]`).
pub fn UnifiedClient::with_proxy_url(
  self : UnifiedClient,
  url : String,
) -> Result[UnifiedClient, HttpError] {
  let proxy = match Proxy::new(url) {
    Ok(proxy) => proxy
    Err(err) => return Err(err)
  }
  Ok(self.with_proxy(proxy))
}

pub impl HttpClient for UnifiedClient with fn request(self : UnifiedClient, req : Request) -> Result[Response, HttpError] {
  self.redirect_count = 0
  self.do_request(req)
}

extend UnifiedClient with HttpClient::{request}

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
  let result = if normalized.length() == 0 {
    "/"
  } else if trailing {
    "/" + joined + "/"
  } else {
    "/" + joined
  }
  result + suffix
}

// RFC 3986 §3.1: scheme = ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ) ":".
fn has_uri_scheme(location : String) -> Bool {
  match location.get_char(0) {
    Some(ch) =>
      if !((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')) {
        return false
      }
    None => return false
  }
  let mut index = 1
  while true {
    match location.get_char(index) {
      Some(ch) => {
        if ch == ':' {
          return true
        }
        let valid = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
          (ch >= '0' && ch <= '9') || ch == '+' || ch == '-' || ch == '.'
        if !valid {
          return false
        }
      }
      None => return false
    }
    index = index + 1
  }
  false
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
  } else if has_uri_scheme(location) {
    // A reference that carries a scheme is an absolute URI and replaces the
    // base entirely (RFC 3986 §5.2.2). Url::parse rejects non-http(s)
    // schemes, so a redirect to e.g. "ftp://host/x" fails cleanly instead of
    // being misresolved as a path on the original origin.
    location
  } else {
    let directory = match base.path.rev_find("/") {
      Some(index) => base.path[0:index + 1].to_owned()
      None => "/"
    }
    base.origin() + normalize_path_and_suffix(directory + location)
  }
  let parsed = match Url::parse(full) {
    Ok(url) => url
    Err(err) => return Err(err)
  }
  Ok(parsed.with_path(normalize_path_and_suffix(parsed.path)))
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
    300 | 307 | 308 => (method, true)
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
      Err(err) => return Err(http_error_from_net(err))
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
    Err(err) => return Err(normalize_http_error(err))
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
      lease.release(false)
      if allow_retry && lease.reused && request_can_be_retried(req.method) {
        return self.do_request_once(req, false)
      }
      return Err(http_error_from_net(err))
    }
  }

  // Create codec
  let codec = H1Codec::new_with_limit_and_completion(
    stream,
    self.options.max_response_body_bytes,
    fn(reusable) { lease.release(reusable) },
  )

  // Add User-Agent header if not present
  let mut request = req
  let explicit_cookie = request.get_header("Cookie")
  if explicit_cookie is None {
    match self.connector.cookie_header(request.url) {
      Some(value) => request = request.with_header("Cookie", value)
      None => ()
    }
  }
  if request.get_header("User-Agent") is None {
    request = request.with_header("User-Agent", self.options.user_agent)
  }

  // Advertise the compression schemes we can decode. The body is decoded
  // transparently by Response::read_body_decoded / text.
  if request.get_header("Accept-Encoding") is None {
    request = request.with_header("Accept-Encoding", "gzip, deflate")
  }

  // When a proxy is configured, plain HTTP is sent in absolute-form and the
  // proxy credentials are attached. HTTPS tunnels authenticate during CONNECT,
  // so caller-supplied proxy credentials must not be forwarded to the origin.
  let absolute_form = self.connector.uses_absolute_form(request.url)
  if absolute_form {
    if request.get_header("Proxy-Authorization") is None {
      match self.connector.proxy_authorization() {
        Some(value) => request = request.with_header("Proxy-Authorization", value)
        None => ()
      }
    }
  } else {
    request = request.without_header("Proxy-Authorization")
  }

  // Encode and send request
  match codec.encode_request(request, absolute_form~) {
    Ok(_) => ()
    Err(err) => {
      lease.release(false)
      if allow_retry && lease.reused && request_can_be_retried(request.method) &&
        err is NetworkError(_) {
        return self.do_request_once(req, false)
      }
      return Err(normalize_http_error(err))
    }
  }

  // Decode response
  let response = match codec.decode_response(head=request.method == HEAD) {
    Ok(response) => response
    Err(err) => {
      lease.release(false)
      if allow_retry && lease.reused && request_can_be_retried(request.method) {
        return self.do_request_once(req, false)
      }
      return Err(normalize_http_error(err))
    }
  }

  // Persist cookies before following a redirect so the next hop sees them.
  self.connector.store_cookies(request.url, response.headers)

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
      let _ = response.body.close()
      return Err(RedirectLimitExceeded)
    }

    // Drain the redirect response body so the connection can be reused.
    match drain_response(response) {
      Ok(_) => ()
      Err(_) => {
        let _ = response.body.close()
      }
    }

    self.redirect_count += 1

    let (next_method, keep_body) = redirect_method(response.status, request.method)
    let mut next_headers = request.headers.remove("Host")
    // With the jar enabled, let the next hop rebuild `Cookie` for its own
    // origin instead of replaying a header that may have been for this one.
    if self.connector.cookies_enabled() && explicit_cookie is None {
      next_headers = next_headers.remove("Cookie")
    }
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
  status == 300 || status == 301 || status == 302 || status == 303 ||
  status == 307 || status == 308
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

/// Send a multipart/form-data POST request.
pub fn UnifiedClient::post_multipart(
  self : UnifiedClient,
  url : String,
  fields : Array[(String, String)],
  files : Array[MultipartFile],
) -> Result[Response, HttpError] {
  let parsed_url = match Url::parse(url) {
    Ok(url) => url
    Err(err) => return Err(err)
  }
  self.request(Request::new(POST, parsed_url).with_multipart(fields, files))
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

struct BufferedStream {
  data : Bytes
  mut offset : Int
  mut is_open : Bool
}

fn BufferedStream::new(data : Bytes) -> BufferedStream {
  BufferedStream::{ data, offset: 0, is_open: true }
}

pub impl Stream for BufferedStream with fn read(self : BufferedStream, buf : Buffer) -> Result[Int, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  let remaining = self.data.length() - self.offset
  if remaining <= 0 {
    return Ok(0)
  }
  let take = if remaining < 8192 { remaining } else { 8192 }
  buf.write_bytes(self.data.exact_view(start=self.offset, end=self.offset + take))
  self.offset = self.offset + take
  Ok(take)
}

pub impl Stream for BufferedStream with fn write(self : BufferedStream, buf : Buffer) -> Result[Int, NetError] {
  let _ = buf
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Err(NetError::WriteError("buffered response is read-only"))
}

pub impl Stream for BufferedStream with fn flush(self : BufferedStream) -> Result[Unit, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Ok(())
}

pub impl Stream for BufferedStream with fn close(self : BufferedStream) -> Result[Unit, NetError] {
  self.is_open = false
  Ok(())
}

pub impl Stream for BufferedStream with fn set_timeout(self : BufferedStream, timeout_ms : Int) -> Result[Unit, NetError] {
  let _ = timeout_ms
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Ok(())
}

pub impl Stream for BufferedStream with fn peer_addr(self : BufferedStream) -> Result[String, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Err(NetError::IoError("buffered response has no peer"))
}

pub impl Stream for BufferedStream with fn local_addr(self : BufferedStream) -> Result[String, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Err(NetError::IoError("buffered response has no local address"))
}

fn buffer_one_shot_response(
  client : UnifiedClient,
  result : Result[Response, HttpError],
) -> Result[Response, HttpError] {
  let response = match result {
    Ok(response) => response
    Err(err) => {
      let _ = client.close_all()
      return Err(err)
    }
  }
  let body = match response.read_body() {
    Ok(body) => body
    Err(err) => {
      let _ = client.close_all()
      return Err(err)
    }
  }
  let _ = client.close_all()
  let buffered = BufferedStream::new(body)
  let stream : &Stream = buffered
  Ok(
    Response::new_with_version(
      response.version,
      response.status,
      response.headers,
      stream,
    )
      .with_trailers(response.trailers)
      .with_max_body_bytes(response.max_body_bytes),
  )
}

/// Send a GET request with a one-shot default client, choosing HTTP or HTTPS
/// automatically from the URL scheme.
pub fn get(url : String) -> Result[Response, HttpError] {
  let client = default_client()
  buffer_one_shot_response(client, client.get(url))
}

/// Send a POST request with a one-shot default client, choosing HTTP or HTTPS
/// automatically from the URL scheme.
pub fn post(url : String, body : Bytes) -> Result[Response, HttpError] {
  let client = default_client()
  buffer_one_shot_response(client, client.post(url, body))
}
