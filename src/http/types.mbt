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
}

/// HTTP method
pub enum HttpMethod {
  GET
  POST
  PUT
  DELETE
  HEAD
  OPTIONS
  PATCH
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
}

pub fn Header::new(name : String, value : String) -> Header {
  Header::{ name, value }
}

/// HTTP headers collection
pub struct Headers {
  headers : List[Header]
}

pub fn Headers::new() -> Headers {
  Headers::{ headers: List::[] }
}

pub fn Headers::add(self : Headers, name : String, value : String) -> Headers {
  Headers::{ headers: Cons(Header::new(name, value), self.headers) }
}

pub fn Headers::get(self : Headers, name : String) -> Option[String] {
  self.headers.find(fn(h) { h.name == name }).map(fn(h) { h.value })
}

pub fn Headers::remove(self : Headers, name : String) -> Headers {
  Headers::{ headers: self.headers.filter(fn(h) { h.name != name }) }
}

pub fn Headers::iter(self : Headers) -> Iter[Header] {
  self.headers.iter()
}

/// URL structure
pub struct Url {
  scheme : String
  host : String
  port : Int
  path : String
  query : String
  fragment : String
}

pub fn Url::new(scheme : String, host : String, port : Int) -> Url {
  Url::{ scheme, host, port, path: "/", query: "", fragment: "" }
}

pub fn Url::parse(url_str : String) -> Result[Url, HttpError] {
  // Simple URL parser - in real implementation would be more robust
  if url_str.length() == 0 {
    return Err(InvalidUrl("Empty URL"))
  }
  
  let parts = url_str.split("://")
  if parts.length() < 2 {
    return Err(InvalidUrl("Invalid URL format"))
  }
  
  let scheme = parts[0]
  let rest = parts[1]
  
  if scheme != "http" && scheme != "https" {
    return Err(InvalidUrl("Only http and https schemes supported"))
  }
  
  let host_part = rest
  let path_idx = host_part.index_of("/")
  let host_and_port = if path_idx.is_some() {
    host_part.substring(0, path_idx.unwrap())
  } else {
    host_part
  }
  
  let port_idx = host_and_port.index_of(":")
  let (host, port) = if port_idx.is_some() {
    let host_str = host_and_port.substring(0, port_idx.unwrap())
    let port_str = host_and_port.substring(port_idx.unwrap() + 1, host_and_port.length())
    let port_num = port_str.parse_int()
    if port_num.is_err() {
      return Err(InvalidUrl("Invalid port number"))
    }
    (host_str, port_num.unwrap())
  } else {
    let default_port = if scheme == "https" { 443 } else { 80 }
    (host_and_port, default_port)
  }
  
  let path = if path_idx.is_some() {
    let path_str = host_part.substring(path_idx.unwrap(), host_part.length())
    let query_idx = path_str.index_of("?")
    if query_idx.is_some() {
      path_str.substring(0, query_idx.unwrap())
    } else {
      path_str
    }
  } else {
    "/"
  }
  
  Ok(Url::{ scheme, host, port, path, query: "", fragment: "" })
}

pub fn Url::to_string(self : Url) -> String {
  let scheme = self.scheme
  let host_port = if (self.scheme == "https" && self.port != 443) || (self.scheme == "http" && self.port != 80) {
    self.host + ":" + self.port.to_string()
  } else {
    self.host
  }
  let base = scheme + "://" + host_port + self.path
  if self.query.length() > 0 {
    base + "?" + self.query
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
}

pub fn Request::new(method : HttpMethod, url : Url) -> Request {
  Request::{
    method,
    url,
    headers: Headers::new(),
    body: None,
    timeout_ms: 30000,
  }
}

pub fn Request::with_header(self : Request, name : String, value : String) -> Request {
  Request::{ ..self, headers: self.headers.add(name, value) }
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
  status : Int
  headers : Headers
  body : Stream // Stream for reading response body
}

pub fn Response::new(status : Int, headers : Headers, body : Stream) -> Response {
  Response::{ status, headers, body }
}

pub fn Response::get_header(self : Response, name : String) -> Option[String] {
  self.headers.get(name)
}

/// HTTP Client interface
pub trait HttpClient {
  fn request(self : HttpClient, req : Request) -> Result[Response, HttpError]
}

/// Convenience functions for common HTTP methods
pub fn HttpClient::get(self : HttpClient, url : String) -> Result[Response, HttpError] {
  let parsed_url = Url::parse(url)?
  let req = Request::new(GET, parsed_url)
  self.request(req)
}

pub fn HttpClient::post(self : HttpClient, url : String, body : Bytes) -> Result[Response, HttpError] {
  let parsed_url = Url::parse(url)?
  let req = Request::new(POST, parsed_url).with_body(body)
  self.request(req)
}

pub fn HttpClient::put(self : HttpClient, url : String, body : Bytes) -> Result[Response, HttpError] {
  let parsed_url = Url::parse(url)?
  let req = Request::new(PUT, parsed_url).with_body(body)
  self.request(req)
}

pub fn HttpClient::delete(self : HttpClient, url : String) -> Result[Response, HttpError] {
  let parsed_url = Url::parse(url)?
  let req = Request::new(DELETE, parsed_url)
  self.request(req)
}
