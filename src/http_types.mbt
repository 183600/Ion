/// HTTP error types
pub enum HttpError {
  NetworkError(NetError)
  TlsError(TlsError)
  InvalidUrl(String)
  InvalidMethod(String)
  InvalidHeader(String)
  Timeout
  ConnectionClosed
  ProtocolError(String)
  RedirectLimitExceeded
} derive(Eq, Debug)

/// HTTP method
pub enum HttpMethod {
  GET
  POST
  PUT
  DELETE
  HEAD
  OPTIONS
  PATCH
} derive(Eq, Debug)

pub fn HttpMethod::parse(value : String) -> Result[HttpMethod, HttpError] {
  match value.to_upper() {
    "GET" => Ok(GET)
    "POST" => Ok(POST)
    "PUT" => Ok(PUT)
    "DELETE" => Ok(DELETE)
    "HEAD" => Ok(HEAD)
    "OPTIONS" => Ok(OPTIONS)
    "PATCH" => Ok(PATCH)
    _ => Err(InvalidMethod(value))
  }
}

pub fn HttpMethod::to_string(method : HttpMethod) -> String {
  match method {
    GET => "GET"
    POST => "POST"
    PUT => "PUT"
    DELETE => "DELETE"
    HEAD => "HEAD"
    OPTIONS => "OPTIONS"
    PATCH => "PATCH"
  }
}

/// HTTP header
pub struct Header {
  name : String
  value : String
} derive(Eq, Debug)

pub fn Header::new(name : String, value : String) -> Header {
  Header::{ name, value }
}

/// HTTP headers collection
pub struct Headers {
  headers : List[Header]
} derive(Eq, Debug)

pub fn Headers::new() -> Headers {
  Headers::{ headers: @list.List([]) }
}

pub fn Headers::add(self : Headers, name : String, value : String) -> Headers {
  Headers::{ headers: self.headers.prepend(Header::new(name, value)) }
}

pub fn Headers::get(self : Headers, name : String) -> Option[String] {
  let lower_name = name.to_lower()
  self.headers.find(fn(h) { h.name.to_lower() == lower_name }).map(fn(h) { h.value })
}

/// All values for a header in insertion order.
pub fn Headers::get_all(self : Headers, name : String) -> List[String] {
  let lower_name = name.to_lower()
  let mut values = @list.List([])
  for header in self.headers.iter() {
    if header.name.to_lower() == lower_name {
      values = values.prepend(header.value)
    }
  }
  values
}

pub fn Headers::contains(self : Headers, name : String) -> Bool {
  self.get(name) is Some(_)
}

/// Replace every existing value for a header with a single value.
pub fn Headers::set(self : Headers, name : String, value : String) -> Headers {
  self.remove(name).add(name, value)
}

pub fn Headers::remove(self : Headers, name : String) -> Headers {
  let lower_name = name.to_lower()
  Headers::{ headers: self.headers.filter(fn(h) { h.name.to_lower() != lower_name }) }
}

pub fn Headers::iter(self : Headers) -> Iter[Header] {
  self.headers.iter()
}

pub fn Headers::length(self : Headers) -> Int {
  self.headers.length()
}

/// URL structure
pub struct Url {
  scheme : String
  host : String
  port : Int
  path : String
  query : String
  fragment : String
} derive(Eq, Debug)

pub fn Url::new(scheme : String, host : String, port : Int) -> Url {
  Url::{ scheme, host, port, path: "/", query: "", fragment: "" }
}

fn find_char(str : String, target : Char) -> Int? {
  let len = str.length()
  let mut i = 0
  while i < len {
    match str.get_char(i) {
      Some(ch) => {
        if ch == target {
          return Some(i)
        }
      }
      None => ()
    }
    i = i + 1
  }
  None
}

fn find_first_delimiter(str : String) -> Int? {
  let len = str.length()
  let mut i = 0
  while i < len {
    match str.get_char(i) {
      Some(ch) => {
        if ch == '/' || ch == '?' || ch == '#' {
          return Some(i)
        }
      }
      None => ()
    }
    i = i + 1
  }
  None
}

fn valid_url_host_chars(host : String) -> Bool {
  for ch in host {
    if ch <= ' ' || ch == '\u{7f}' || ch == '/' || ch == '?' || ch == '#' ||
      ch == '@' || ch == '[' || ch == ']' || ch == '\\' || ch == '"' ||
      ch == '<' || ch == '>' || ch == '^' || ch == '\u{60}' || ch == '{' ||
      ch == '|' || ch == '}' || ch == ',' {
      return false
    }
  }
  true
}

pub fn Url::parse(url_str : String) -> Result[Url, HttpError] {
  if url_str.length() == 0 {
    return Err(InvalidUrl("Empty URL"))
  }
  for ch in url_str {
    if ch <= ' ' || ch == '\u{7f}' {
      return Err(InvalidUrl("Invalid URL characters"))
    }
  }

  let scheme_end = match url_str.find("://") {
    Some(index) => index
    None => return Err(InvalidUrl("Invalid URL format"))
  }
  if scheme_end == 0 {
    return Err(InvalidUrl("Invalid URL format"))
  }

  let scheme = url_str[0:scheme_end].to_owned().to_lower()
  if scheme != "http" && scheme != "https" {
    return Err(InvalidUrl("Only http and https schemes supported"))
  }

  let rest = url_str[scheme_end + 3:].to_owned()
  if rest.length() == 0 {
    return Err(InvalidUrl("URL has no host"))
  }

  let authority_end = find_first_delimiter(rest)
  let authority = match authority_end {
    Some(index) => rest[0:index].to_owned()
    None => rest
  }
  let remainder = match authority_end {
    Some(index) => rest[index:].to_owned()
    None => ""
  }
  if authority.length() == 0 {
    return Err(InvalidUrl("URL has no host"))
  }

  // Ignore optional userinfo (user:password@host).
  let host_port = match find_char(authority, '@') {
    Some(index) => authority[index + 1:].to_owned()
    None => authority
  }
  if host_port.length() == 0 {
    return Err(InvalidUrl("URL has no host"))
  }

  let mut host = host_port
  let mut port_str : Option[String] = None
  let mut bracketed = false
  if host_port.has_prefix("[") {
    bracketed = true
    let close = match find_char(host_port, ']') {
      Some(index) => index
      None => return Err(InvalidUrl("Invalid IPv6 host"))
    }
    host = host_port[1:close].to_owned()
    let after = close + 1
    if after < host_port.length() {
      if host_port.get_char(after) == Some(':') {
        port_str = Some(host_port[after + 1:].to_owned())
      } else {
        return Err(InvalidUrl("Invalid host"))
      }
    }
  } else {
    match find_char(host_port, ':') {
      Some(index) => {
        host = host_port[0:index].to_owned()
        port_str = Some(host_port[index + 1:].to_owned())
      }
      None => ()
    }
  }

  if host.length() == 0 {
    return Err(InvalidUrl("URL has no host"))
  }
  if host.contains("@") || !valid_url_host_chars(host) {
    return Err(InvalidUrl("Invalid host"))
  }
  if !bracketed && (host.contains(":") || host.contains("[") || host.contains("]")) {
    return Err(InvalidUrl("Invalid host"))
  }

  let port = match port_str {
    Some(port_text) => {
      if !is_decimal_digits(port_text) {
        return Err(InvalidUrl("Invalid port number"))
      }
      let parsed = try {
        @string.parse_int(port_text[:])
      } catch {
        _ => return Err(InvalidUrl("Invalid port number"))
      }
      if parsed < 1 || parsed > 65535 {
        return Err(InvalidUrl("Invalid port number"))
      }
      parsed
    }
    None => {
      if scheme == "https" {
        443
      } else {
        80
      }
    }
  }

  let mut path = "/"
  let mut query = ""
  let mut fragment = ""
  if remainder.length() > 0 {
    let mut main = remainder
    match main.find("#") {
      Some(index) => {
        fragment = main[index + 1:].to_owned()
        main = main[0:index].to_owned()
      }
      None => ()
    }
    match main.find("?") {
      Some(index) => {
        query = main[index + 1:].to_owned()
        main = main[0:index].to_owned()
      }
      None => ()
    }
    if main.length() > 0 {
      path = main
    }
  }

  Ok(Url::{ scheme, host, port, path, query, fragment })
}

/// Host and optional non-default port, bracketing IPv6 literals.
pub fn Url::authority(self : Url) -> String {
  let scheme = self.scheme.to_lower()
  let host_text = if self.host.contains(":") && !(self.host.has_prefix("[") && self.host.has_suffix("]")) {
    "[" + self.host + "]"
  } else {
    self.host
  }
  let default_port = if scheme == "https" {
    443
  } else if scheme == "http" {
    80
  } else {
    -1
  }
  if self.port == default_port {
    host_text
  } else {
    host_text + ":" + self.port.to_string()
  }
}

/// Scheme, authority, path, and query without the fragment.
pub fn Url::origin(self : Url) -> String {
  self.scheme.to_lower() + "://" + self.authority()
}

/// Origin-form request target: an absolute path plus an optional query.
pub fn Url::is_secure(self : Url) -> Bool {
  self.scheme.to_lower() == "https"
}

pub fn Url::request_target(self : Url) -> String {
  let path = if self.path.length() == 0 {
    "/"
  } else if self.path.has_prefix("/") {
    self.path
  } else {
    "/" + self.path
  }
  if self.query.length() > 0 {
    path + "?" + self.query
  } else {
    path
  }
}

pub fn Url::with_path(self : Url, path : String) -> Url {
  Url::{ ..self, path }
}

pub fn Url::with_query(self : Url, query : String) -> Url {
  Url::{ ..self, query }
}

pub fn Url::with_fragment(self : Url, fragment : String) -> Url {
  Url::{ ..self, fragment }
}

pub fn Url::to_string(self : Url) -> String {
  let base = self.origin() + self.request_target()
  if self.fragment.length() > 0 {
    base + "#" + self.fragment
  } else {
    base
  }
}

/// HTTP Request
pub struct Request {
  method : HttpMethod
  url : Url
  headers : Headers
  body : Option[Bytes]
  timeout_ms : Int
} derive(Eq, Debug)

pub fn Request::new(method : HttpMethod, url : Url) -> Request {
  Request::{
    method,
    url,
    headers: Headers::new(),
    body: None,
    timeout_ms: 30000,
  }
}

pub fn Request::with_method(self : Request, verb : HttpMethod) -> Request {
  Request::{ ..self, method: verb }
}

pub fn Request::with_header(self : Request, name : String, value : String) -> Request {
  Request::{ ..self, headers: self.headers.add(name, value) }
}

pub fn Request::with_basic_auth(self : Request, username : String, password : String) -> Request {
  let encoded = @base64.encode(@utf8.encode(username + ":" + password))
  Request::{ ..self, headers: self.headers.set("Authorization", "Basic " + encoded) }
}

pub fn Request::with_body(self : Request, body : Bytes) -> Request {
  Request::{ ..self, body: Some(body) }
}

pub fn Request::with_timeout(self : Request, timeout_ms : Int) -> Request {
  Request::{ ..self, timeout_ms }
}

pub fn Request::get_header(self : Request, name : String) -> Option[String] {
  self.headers.get(name)
}

/// HTTP Response
pub struct Response {
  version : String
  status : Int
  headers : Headers
  body : &Stream // Stream for reading response body
}

pub fn Response::new(status : Int, headers : Headers, body : &Stream) -> Response {
  Response::{ version: "HTTP/1.1", status, headers, body }
}

pub fn Response::new_with_version(
  version : String,
  status : Int,
  headers : Headers,
  body : &Stream,
) -> Response {
  Response::{ version, status, headers, body }
}

const DEFAULT_MAX_RESPONSE_BODY_BYTES : Int = 67108864

/// Read the complete response body with an explicit size limit.
pub fn Response::read_body_with_limit(
  self : Response,
  max_bytes : Int,
) -> Result[Bytes, HttpError] {
  let limit = if max_bytes < 0 { 0 } else { max_bytes }
  let output = Buffer(size_hint=4096)
  while true {
    let chunk = Buffer(size_hint=4096)
    match self.body.read(chunk) {
      Ok(0) => break
      Ok(count) => {
        if count < 0 {
          return Err(NetworkError(ReadError("invalid read count")))
        }
        let bytes = chunk.to_bytes()
        if bytes.length() == 0 {
          return Err(NetworkError(ReadError("stream returned no data")))
        }
        if bytes.length() > limit - output.length() {
          return Err(NetworkError(ReadError("response body too large")))
        }
        output.write_bytes(bytes)
      }
      Err(err) => return Err(NetworkError(err))
    }
  }
  Ok(output.to_bytes())
}

/// Read the complete response body, enforcing the default size limit.
pub fn Response::read_body(self : Response) -> Result[Bytes, HttpError] {
  self.read_body_with_limit(DEFAULT_MAX_RESPONSE_BODY_BYTES)
}

/// Decode the complete response body as UTF-8 text.
pub fn Response::text(self : Response) -> Result[String, HttpError] {
  match self.read_body() {
    Ok(body) => Ok(@utf8.decode_lossy(body[:]))
    Err(err) => Err(err)
  }
}

pub fn Response::get_header(self : Response, name : String) -> Option[String] {
  self.headers.get(name)
}

pub fn Response::is_success(self : Response) -> Bool {
  self.status >= 200 && self.status < 300
}

pub fn Response::is_redirection(self : Response) -> Bool {
  self.status == 301 || self.status == 302 || self.status == 303 ||
  self.status == 307 || self.status == 308
}

pub fn Response::is_client_error(self : Response) -> Bool {
  self.status >= 400 && self.status < 500
}

pub fn Response::is_server_error(self : Response) -> Bool {
  self.status >= 500 && self.status < 600
}

/// HTTP Client interface
pub trait HttpClient {
  fn request(Self, Request) -> Result[Response, HttpError]
}

/// Convenience functions for common HTTP methods
pub fn &HttpClient::get(self : &HttpClient, url : String) -> Result[Response, HttpError] {
  let parsed_url = match Url::parse(url) {
    Ok(url) => url
    Err(err) => return Err(err)
  }
  let req = Request::new(GET, parsed_url)
  self.request(req)
}

pub fn &HttpClient::post(self : &HttpClient, url : String, body : Bytes) -> Result[Response, HttpError] {
  let parsed_url = match Url::parse(url) {
    Ok(url) => url
    Err(err) => return Err(err)
  }
  let req = Request::new(POST, parsed_url).with_body(body)
  self.request(req)
}

pub fn &HttpClient::put(self : &HttpClient, url : String, body : Bytes) -> Result[Response, HttpError] {
  let parsed_url = match Url::parse(url) {
    Ok(url) => url
    Err(err) => return Err(err)
  }
  let req = Request::new(PUT, parsed_url).with_body(body)
  self.request(req)
}

pub fn &HttpClient::delete(self : &HttpClient, url : String) -> Result[Response, HttpError] {
  let parsed_url = match Url::parse(url) {
    Ok(url) => url
    Err(err) => return Err(err)
  }
  let req = Request::new(DELETE, parsed_url)
  self.request(req)
}

pub fn &HttpClient::head(self : &HttpClient, url : String) -> Result[Response, HttpError] {
  let parsed_url = match Url::parse(url) {
    Ok(url) => url
    Err(err) => return Err(err)
  }
  self.request(Request::new(HEAD, parsed_url))
}

pub fn &HttpClient::options(self : &HttpClient, url : String) -> Result[Response, HttpError] {
  let parsed_url = match Url::parse(url) {
    Ok(url) => url
    Err(err) => return Err(err)
  }
  self.request(Request::new(OPTIONS, parsed_url))
}

pub fn &HttpClient::patch(self : &HttpClient, url : String, body : Bytes) -> Result[Response, HttpError] {
  let parsed_url = match Url::parse(url) {
    Ok(url) => url
    Err(err) => return Err(err)
  }
  self.request(Request::new(PATCH, parsed_url).with_body(body))
}
