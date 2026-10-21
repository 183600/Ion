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

/// Promote low-level network failures onto the dedicated HTTP error variants.
/// Callers can then match `Timeout` / `ConnectionClosed` without having to
/// unwrap the nested `NetError`.
fn http_error_from_net(err : NetError) -> HttpError {
  match err {
    Timeout => Timeout
    Closed => ConnectionClosed
    _ => NetworkError(err)
  }
}

/// Normalize an existing `HttpError` that may wrap a timeout or a closed
/// connection, leaving every other variant untouched.
fn normalize_http_error(err : HttpError) -> HttpError {
  match err {
    NetworkError(net) => http_error_from_net(net)
    TlsError(tls) =>
      match tls {
        Timeout => Timeout
        ConnectionClosed => ConnectionClosed
        _ => err
      }
    _ => err
  }
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

/// Iterate the headers in insertion order, matching `get_all`.
pub fn Headers::iter(self : Headers) -> Iter[Header] {
  // `add` prepends, so the stored list is reverse insertion order; flip it
  // back so callers see the same order as `get_all`.
  let mut ordered = @list.List([])
  for header in self.headers.iter() {
    ordered = ordered.prepend(header)
  }
  ordered.iter()
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

fn valid_encoded_url_chars(value : String) -> Bool {
  let mut index = 0
  while index < value.length() {
    let ch = match value.get_char(index) {
      Some(ch) => ch
      None => return false
    }
    if ch <= ' ' || ch == '\u{7f}' || ch == '\\' || ch == '"' || ch == '<' ||
      ch == '>' || ch == '^' || ch == '\u{60}' || ch == '{' || ch == '|' ||
      ch == '}' {
      return false
    }
    if ch == '%' {
      if index + 2 >= value.length() {
        return false
      }
      let high = match value.get_char(index + 1) {
        Some(ch) => ch
        None => return false
      }
      let low = match value.get_char(index + 2) {
        Some(ch) => ch
        None => return false
      }
      if !is_hex_char(high) || !is_hex_char(low) {
        return false
      }
      index = index + 3
      continue
    }
    index = index + 1
  }
  true
}

fn valid_userinfo_chars(value : String) -> Bool {
  let mut index = 0
  while index < value.length() {
    let ch = match value.get_char(index) {
      Some(ch) => ch
      None => return false
    }
    if ch == '%' {
      if index + 2 >= value.length() {
        return false
      }
      let high = match value.get_char(index + 1) {
        Some(ch) => ch
        None => return false
      }
      let low = match value.get_char(index + 2) {
        Some(ch) => ch
        None => return false
      }
      if !is_hex_char(high) || !is_hex_char(low) {
        return false
      }
      index = index + 3
      continue
    }
    if !is_unreserved_char(ch) && !is_sub_delim_char(ch) && ch != ':' {
      return false
    }
    index = index + 1
  }
  true
}

fn valid_url_host_chars(host : String) -> Bool {
  let mut index = 0
  while index < host.length() {
    let ch = match host.get_char(index) {
      Some(ch) => ch
      None => return false
    }
    if ch <= ' ' || ch == '\u{7f}' || ch == '/' || ch == '?' || ch == '#' ||
      ch == '@' || ch == '[' || ch == ']' || ch == '\\' || ch == '"' ||
      ch == '<' || ch == '>' || ch == '^' || ch == '\u{60}' || ch == '{' ||
      ch == '|' || ch == '}' || ch == ',' {
      return false
    }
    if ch == '%' {
      if index + 2 >= host.length() {
        return false
      }
      let high = match host.get_char(index + 1) {
        Some(ch) => ch
        None => return false
      }
      let low = match host.get_char(index + 2) {
        Some(ch) => ch
        None => return false
      }
      if !is_hex_char(high) || !is_hex_char(low) {
        return false
      }
      index = index + 3
      continue
    }
    index = index + 1
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

  // Ignore optional userinfo (user:password@host), but reject malformed escapes.
  let host_port = match find_char(authority, '@') {
    Some(index) => {
      let userinfo = authority[0:index].to_owned()
      if !valid_userinfo_chars(userinfo) {
        return Err(InvalidUrl("Invalid URL characters"))
      }
      authority[index + 1:].to_owned()
    }
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
  if bracketed && !is_ip_literal(host) {
    return Err(InvalidUrl("Invalid IPv6 host"))
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

  if !valid_encoded_url_chars(path) || !valid_encoded_url_chars(query) ||
    !valid_encoded_url_chars(fragment) {
    return Err(InvalidUrl("Invalid URL characters"))
  }

  Ok(Url::{ scheme, host, port, path, query, fragment })
}

fn url_authority_host(host : String) -> String {
  if host.has_prefix("[") && host.has_suffix("]") {
    host
  } else if host.contains(":") ||
    (is_ip_literal(host) && !is_ipv6_literal_with_zone(host)) {
    "[" + host + "]"
  } else {
    host
  }
}

/// Host and optional non-default port, bracketing IP literals.
pub fn Url::authority(self : Url) -> String {
  let scheme = self.scheme.to_lower()
  let host_text = url_authority_host(self.host)
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
  timeout_explicit : Bool
} derive(Eq, Debug)

pub fn Request::new(method : HttpMethod, url : Url) -> Request {
  Request::{
    method,
    url,
    headers: Headers::new(),
    body: None,
    timeout_ms: 30000,
    timeout_explicit: false,
  }
}

pub fn Request::with_method(self : Request, verb : HttpMethod) -> Request {
  Request::{ ..self, method: verb }
}

pub fn Request::with_header(self : Request, name : String, value : String) -> Request {
  Request::{ ..self, headers: self.headers.add(name, value) }
}

fn is_form_safe_byte(byte : Byte) -> Bool {
  (byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') ||
  (byte >= b'0' && byte <= b'9') || byte == b'*' || byte == b'-' ||
  byte == b'.' || byte == b'_'
}

fn form_encode_component(value : String) -> String {
  let hex : Array[Byte] = [
    b'0', b'1', b'2', b'3', b'4', b'5', b'6', b'7', b'8', b'9', b'A', b'B',
    b'C', b'D', b'E', b'F',
  ]
  let output = Buffer(size_hint=value.length())
  for byte in @utf8.encode(value) {
    if is_form_safe_byte(byte) {
      output.write_byte(byte)
    } else if byte == b' ' {
      output.write_byte(b'+')
    } else {
      let code = byte.to_int()
      output.write_byte(b'%')
      output.write_byte(hex[(code >> 4) & 0xF])
      output.write_byte(hex[code & 0xF])
    }
  }
  @utf8.decode_lossy(output.to_bytes()[:])
}

/// Encode fields as an application/x-www-form-urlencoded request body.
pub fn Request::with_form(self : Request, fields : Array[(String, String)]) -> Request {
  let body = Buffer(size_hint=256)
  let mut first = true
  for field in fields {
    let (name, value) = field
    if !first {
      body.write_byte(b'&')
    }
    first = false
    body.write_bytes(@utf8.encode(form_encode_component(name)))
    body.write_byte(b'=')
    body.write_bytes(@utf8.encode(form_encode_component(value)))
  }
  self
    .set_header("Content-Type", "application/x-www-form-urlencoded")
    .with_body(body.to_bytes())
}

/// A file part in a multipart/form-data request body.
pub struct MultipartFile {
  field_name : String
  file_name : String
  content_type : String
  data : Bytes
} derive(Eq, Debug)

pub fn MultipartFile::new(
  field_name : String,
  file_name : String,
  content_type : String,
  data : Bytes,
) -> MultipartFile {
  MultipartFile::{ field_name, file_name, content_type, data }
}

fn multipart_param(value : String) -> String {
  let output = Buffer(size_hint=value.length())
  for byte in @utf8.encode(value) {
    if byte == b'"' || byte == b'\\' {
      output.write_byte(b'\\')
      output.write_byte(byte)
    } else if byte == b'\r' || byte == b'\n' {
      output.write_byte(b' ')
    } else {
      output.write_byte(byte)
    }
  }
  @utf8.decode_lossy(output.to_bytes()[:])
}

fn multipart_contains_bytes(haystack : Bytes, needle : Bytes) -> Bool {
  if needle.length() == 0 {
    return true
  }
  if needle.length() > haystack.length() {
    return false
  }
  let mut index = 0
  while index + needle.length() <= haystack.length() {
    let mut offset = 0
    while offset < needle.length() && haystack[index + offset] == needle[offset] {
      offset = offset + 1
    }
    if offset == needle.length() {
      return true
    }
    index = index + 1
  }
  false
}

fn multipart_contains_text(value : String, needle : Bytes) -> Bool {
  multipart_contains_bytes(@utf8.encode(value), needle)
}

fn multipart_boundary_collides(
  fields : Array[(String, String)],
  files : Array[MultipartFile],
  boundary : String,
) -> Bool {
  let needle = @utf8.encode(boundary)
  for field in fields {
    let (name, value) = field
    if multipart_contains_text(name, needle) || multipart_contains_text(value, needle) {
      return true
    }
  }
  for file in files {
    if multipart_contains_text(file.field_name, needle) ||
      multipart_contains_text(file.file_name, needle) ||
      multipart_contains_text(file.content_type, needle) ||
      multipart_contains_bytes(file.data, needle) {
      return true
    }
  }
  false
}

fn multipart_generate_boundary(
  fields : Array[(String, String)],
  files : Array[MultipartFile],
) -> String {
  let base = "----FeatherFormBoundary"
  let mut boundary = base
  let mut suffix = 0
  while multipart_boundary_collides(fields, files, boundary) {
    suffix = suffix + 1
    boundary = base + suffix.to_string()
  }
  boundary
}

fn multipart_body(
  fields : Array[(String, String)],
  files : Array[MultipartFile],
  boundary : String,
) -> Bytes {
  let body = Buffer(size_hint=512)
  for field in fields {
    let (name, value) = field
    body.write_bytes(
      @utf8.encode(
        "--" + boundary + "\r\nContent-Disposition: form-data; name=\"" +
        multipart_param(name) + "\"\r\n\r\n",
      ),
    )
    body.write_bytes(@utf8.encode(value))
    body.write_bytes(@utf8.encode("\r\n"))
  }
  for file in files {
    body.write_bytes(
      @utf8.encode(
        "--" + boundary + "\r\nContent-Disposition: form-data; name=\"" +
        multipart_param(file.field_name) + "\"; filename=\"" +
        multipart_param(file.file_name) + "\"\r\nContent-Type: " +
        multipart_param(file.content_type) + "\r\n\r\n",
      ),
    )
    body.write_bytes(file.data)
    body.write_bytes(@utf8.encode("\r\n"))
  }
  body.write_bytes(@utf8.encode("--" + boundary + "--\r\n"))
  body.to_bytes()
}

/// Encode text fields and files as a multipart/form-data request body. The
/// boundary is generated automatically and cannot collide with any part.
pub fn Request::with_multipart(
  self : Request,
  fields : Array[(String, String)],
  files : Array[MultipartFile],
) -> Request {
  let boundary = multipart_generate_boundary(fields, files)
  self
    .set_header("Content-Type", "multipart/form-data; boundary=" + boundary)
    .with_body(multipart_body(fields, files, boundary))
}

pub fn Request::with_basic_auth(self : Request, username : String, password : String) -> Request {
  let encoded = @base64.encode(@utf8.encode(username + ":" + password))
  Request::{ ..self, headers: self.headers.set("Authorization", "Basic " + encoded) }
}

pub fn Request::set_header(self : Request, name : String, value : String) -> Request {
  Request::{ ..self, headers: self.headers.set(name, value) }
}

pub fn Request::without_header(self : Request, name : String) -> Request {
  Request::{ ..self, headers: self.headers.remove(name) }
}

pub fn Request::with_body(self : Request, body : Bytes) -> Request {
  Request::{ ..self, body: Some(body) }
}

pub fn Request::with_timeout(self : Request, timeout_ms : Int) -> Request {
  Request::{
    ..self,
    timeout_ms: if timeout_ms < 0 { 0 } else { timeout_ms },
    timeout_explicit: true,
  }
}

pub fn Request::get_header(self : Request, name : String) -> Option[String] {
  self.headers.get(name)
}

pub fn Request::get_header_all(self : Request, name : String) -> List[String] {
  self.headers.get_all(name)
}

/// HTTP Response
pub struct Response {
  version : String
  status : Int
  headers : Headers
  body : &Stream // Stream for reading response body
  max_body_bytes : Int
}

pub fn Response::new(status : Int, headers : Headers, body : &Stream) -> Response {
  Response::{
    version: "HTTP/1.1",
    status,
    headers,
    body,
    max_body_bytes: DEFAULT_MAX_BODY_BYTES,
  }
}

pub fn Response::new_with_version(
  version : String,
  status : Int,
  headers : Headers,
  body : &Stream,
) -> Response {
  Response::{
    version,
    status,
    headers,
    body,
    max_body_bytes: DEFAULT_MAX_BODY_BYTES,
  }
}

fn Response::with_max_body_bytes(
  self : Response,
  max_body_bytes : Int,
) -> Response {
  Response::{
    ..self,
    max_body_bytes: if max_body_bytes < 0 { 0 } else { max_body_bytes },
  }
}

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
          let _ = self.body.close()
          return Err(NetworkError(ReadError("invalid read count")))
        }
        let bytes = chunk.to_bytes()
        if bytes.length() == 0 {
          let _ = self.body.close()
          return Err(NetworkError(ReadError("stream returned no data")))
        }
        if bytes.length() > limit - output.length() {
          let _ = self.body.close()
          return Err(NetworkError(ReadError("response body too large")))
        }
        output.write_bytes(bytes)
      }
      Err(err) => {
        let _ = self.body.close()
        return Err(http_error_from_net(err))
      }
    }
  }
  Ok(output.to_bytes())
}

/// Read the complete response body, enforcing the response's size limit.
pub fn Response::read_body(self : Response) -> Result[Bytes, HttpError] {
  self.read_body_with_limit(self.max_body_bytes)
}

/// Read the complete response body and transparently decode any
/// `Content-Encoding` that Feather understands (`gzip`, `deflate`).
/// Other encodings return an error; a missing/`identity` encoding is a no-op.
pub fn Response::read_body_decoded(self : Response) -> Result[Bytes, HttpError] {
  self.read_body_decoded_with_limit(self.max_body_bytes)
}

/// Like `read_body_decoded`, but bounds the decoded output by `max_bytes`.
pub fn Response::read_body_decoded_with_limit(
  self : Response,
  max_bytes : Int,
) -> Result[Bytes, HttpError] {
  let limit = if max_bytes < 0 { 0 } else { max_bytes }
  let raw = match self.read_body() {
    Ok(body) => body
    Err(err) => return Err(err)
  }
  if raw.length() == 0 {
    return Ok(raw)
  }
  // Repeated Content-Encoding header lines are equivalent to a single
  // comma-separated value listing the codings in the order they were applied
  // (RFC 7230 §3.2.2), so combine every line before decoding.
  let values = self.get_header_all("Content-Encoding")
  if values.length() == 0 {
    if raw.length() > limit {
      return Err(NetworkError(ReadError("response body too large")))
    }
    return Ok(raw)
  }
  let mut combined = ""
  for value in values.iter() {
    if combined.length() > 0 {
      combined = combined + ", "
    }
    combined = combined + value
  }
  let decoded = match decode_encodings(combined, raw, limit) {
    Ok(decoded) => decoded
    Err(err) => return Err(err)
  }
  if decoded.length() > limit {
    return Err(NetworkError(ReadError("response body too large")))
  }
  Ok(decoded)
}

/// Apply a (possibly comma-separated) `Content-Encoding` header. Encodings are
/// listed in the order they were applied, so they are undone in reverse.
fn decode_encodings(
  header : String,
  data : Bytes,
  max_bytes : Int,
) -> Result[Bytes, HttpError] {
  let encodings = header.split(",").to_array()
  let mut current = data
  let mut index = encodings.length() - 1
  while index >= 0 {
    let token = encodings[index].trim().to_owned()
    if token.length() > 0 && token.to_lower() != "identity" {
      current = match decode_content_encoding(token, current, max_bytes) {
        Ok(decoded) => decoded
        Err(err) => return Err(err)
      }
    }
    index = index - 1
  }
  Ok(current)
}

/// Decode the complete response body as UTF-8 text, decompressing any
/// recognised `Content-Encoding` first.
pub fn Response::text(self : Response) -> Result[String, HttpError] {
  match self.read_body_decoded() {
    Ok(body) => Ok(@utf8.decode_lossy(body[:]))
    Err(err) => Err(err)
  }
}

pub fn Response::get_header(self : Response, name : String) -> Option[String] {
  self.headers.get(name)
}

pub fn Response::get_header_all(self : Response, name : String) -> List[String] {
  self.headers.get_all(name)
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

pub fn &HttpClient::post_form(
  self : &HttpClient,
  url : String,
  fields : Array[(String, String)],
) -> Result[Response, HttpError] {
  let parsed_url = match Url::parse(url) {
    Ok(url) => url
    Err(err) => return Err(err)
  }
  self.request(Request::new(POST, parsed_url).with_form(fields))
}

pub fn &HttpClient::post_multipart(
  self : &HttpClient,
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
