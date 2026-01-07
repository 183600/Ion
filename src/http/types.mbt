/// HTTP method enumeration
pub enum HttpMethod {
  GET
  POST
  PUT
  DELETE
  HEAD
  OPTIONS
  PATCH
}

fn HttpMethod::to_string(self : HttpMethod) -> String {
  match self {
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

fn Header::new(name : String, value : String) -> Header {
  { name, value }
}

/// HTTP headers collection
pub struct Headers {
  mut headers : Array[Header]
}

fn Headers::new() -> Headers {
  { headers: [] }
}

fn Headers::from_array(headers : Array[Header]) -> Headers {
  { headers }
}

fn Headers::add(self : Headers, name : String, value : String) -> Unit {
  self.headers.push(Header::new(name, value))
}

fn Headers::get(self : Headers, name : String) -> Option[String] {
  for h in self.headers {
    if h.name.to_lower() == name.to_lower() {
      return Some(h.value)
    }
  }
  None
}

fn Headers::contains(self : Headers, name : String) -> Bool {
  for h in self.headers {
    if h.name.to_lower() == name.to_lower() {
      return true
    }
  }
  false
}

fn Headers::remove(self : Headers, name : String) -> Unit {
  let mut i = 0
  while i < self.headers.length() {
    if self.headers[i].name.to_lower() == name.to_lower() {
      self.headers.remove(i)
    } else {
      i = i + 1
    }
  }
}

fn Headers::to_array(self : Headers) -> Array[Header] {
  self.headers
}

/// URL structure
pub struct Url {
  scheme : String  // "http" or "https"
  host : String
  port : Option[Int]
  path : String
  query : Option[String>
  fragment : Option<String>
}

fn Url::new(scheme : String, host : String, path : String) -> Url {
  {
    scheme,
    host,
    port: None,
    path,
    query: None,
    fragment: None
  }
}

fn Url::parse(url : String) -> Result[Url, String] {
  // Simple URL parser - would be more robust in real implementation
  if url.length() == 0 {
    return Err("Empty URL")
  }
  
  // Check for scheme
  let scheme_end = url.index_of("://")
  if scheme_end.is_none() {
    return Err("Invalid URL: no scheme")
  }
  
  let scheme = url.substring(0, scheme_end.unwrap())
  if scheme != "http" && scheme != "https" {
    return Err("Unsupported scheme: " + scheme)
  }
  
  // Extract host and path
  let rest_start = scheme_end.unwrap() + 3
  let path_start = url.index_of_from("/", rest_start)
  
  let host_and_port : String
  let path : String
  
  if path_start.is_some() {
    host_and_port = url.substring(rest_start, path_start.unwrap())
    path = url.substring(path_start.unwrap(), url.length())
  } else {
    host_and_port = url.substring(rest_start, url.length())
    path = "/"
  }
  
  // Parse host and port
  let port_colon = host_and_port.index_of(":")
  let host : String
  let port : Option[Int]
  
  if port_colon.is_some() {
    host = host_and_port.substring(0, port_colon.unwrap())
    let port_str = host_and_port.substring(port_colon.unwrap() + 1, host_and_port.length())
    match port_str.parse_int() {
      Ok(p) => port = Some(p)
      Err(_) => return Err("Invalid port: " + port_str)
    }
  } else {
    host = host_and_port
    port = None
  }
  
  Ok({
    scheme,
    host,
    port,
    path,
    query: None,
    fragment: None
  })
}

fn Url::to_string(self : Url) -> String {
  let port_part = match self.port {
    Some(p) => ":" + p.to_string()
    None => ""
  }
  self.scheme + "://" + self.host + port_part + self.path
}

fn Url::default_port(self : Url) -> Int {
  match self.scheme {
    "https" => 443
    "http" => 80
    _ => 80
  }
}

fn Url::actual_port(self : Url) -> Int {
  match self.port {
    Some(p) => p
    None => self.default_port()
  }
}

/// HTTP request
pub struct Request {
  method : HttpMethod
  url : Url
  headers : Headers
  body : Option[Bytes]
  // For connection reuse
  mut stream : Option[Stream]
}

fn Request::new(method : HttpMethod, url : Url) -> Request {
  {
    method,
    url,
    headers: Headers::new(),
    body: None,
    stream: None
  }
}

fn Request::get(url : String) -> Result[Request, String] {
  match Url::parse(url) {
    Ok(parsed_url) => Ok(Request::new(GET, parsed_url))
    Err(e) => Err(e)
  }
}

fn Request::post(url : String, body : Bytes) -> Result[Request, String] {
  match Url::parse(url) {
    Ok(parsed_url) => {
      let req = Request::new(POST, parsed_url)
      req.headers.add("Content-Length", body.length().to_string())
      { ..req, body: Some(body) }
    }
    Err(e) => Err(e)
  }
}

fn Request::set_header(self : Request, name : String, value : String) -> Request {
  self.headers.add(name, value)
  self
}

fn Request::set_body(self : Request, body : Bytes) -> Request {
  self.headers.add("Content-Length", body.length().to_string())
  { ..self, body: Some(body) }
}

/// HTTP response
pub struct Response {
  status : Int
  status_text : String
  headers : Headers
  body : Option[Bytes]
  mut body_stream : Option[Stream]
}

fn Response::new(status : Int) -> Response {
  {
    status,
    status_text: "",
    headers: Headers::new(),
    body: None,
    body_stream: None
  }
}

fn Response::is_success(self : Response) -> Bool {
  self.status >= 200 && self.status < 300
}

fn Response::is_redirect(self : Response) -> Bool {
  self.status >= 300 && self.status < 400
}

fn Response::get_header(self : Response, name : String) -> Option[String] {
  self.headers.get(name)
}

/// HTTP error types
pub enum HttpError {
  NetworkError(NetError)
  TlsError(TlsError)
  InvalidResponse(String)
  Timeout
  RedirectLimitExceeded
  UnknownError(String)
}

/// Body reader for streaming responses
pub trait BodyReader {
  fn read(self : BodyReader, buf : Buffer) -> Result[Int, HttpError]
  fn close(self : BodyReader) -> Result[Unit, HttpError]
}

/// Streaming body reader implementation
struct StreamBodyReader {
  stream : Stream
  mut closed : Bool
}

fn StreamBodyReader::new(stream : Stream) -> StreamBodyReader {
  { stream, closed: false }
}

impl BodyReader for StreamBodyReader {
  fn read(self : StreamBodyReader, buf : Buffer) -> Result[Int, HttpError] {
    if self.closed {
      return Ok(0) // EOF
    }
    match self.stream.read(buf) {
      Ok(n) => Ok(n)
      Err(e) => Err(NetworkError(e))
    }
  }
  
  fn close(self : StreamBodyReader) -> Result[Unit, HttpError] {
    self.closed = true
    match self.stream.close() {
      Ok(_) => Ok(())
      Err(e) => Err(NetworkError(e))
    }
  }
}
