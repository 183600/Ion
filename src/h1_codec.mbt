/// HTTP/1.1 codec for encoding requests and decoding responses
pub struct H1Codec {
  stream : &Stream
  // Shared with the response stream so bytes buffered while reading a head
  // remain visible when the same codec is reused for the next exchange.
  reader : @ref.Ref[StreamReader]
  mut last_is_head : Bool
  mut close_after_request : Bool
  max_body_bytes : Int
  on_complete : ((Bool) -> Unit)?
}

const DEFAULT_MAX_BODY_BYTES : Int = 67108864

pub fn H1Codec::new(stream : &Stream) -> H1Codec {
  H1Codec::new_with_limit(stream, DEFAULT_MAX_BODY_BYTES)
}

pub fn H1Codec::new_with_limit(stream : &Stream, max_body_bytes : Int) -> H1Codec {
  H1Codec::make(stream, max_body_bytes, None)
}

pub fn H1Codec::new_with_completion(
  stream : &Stream,
  on_complete : (Bool) -> Unit,
) -> H1Codec {
  H1Codec::make(stream, DEFAULT_MAX_BODY_BYTES, Some(on_complete))
}

pub fn H1Codec::new_with_limit_and_completion(
  stream : &Stream,
  max_body_bytes : Int,
  on_complete : (Bool) -> Unit,
) -> H1Codec {
  H1Codec::make(stream, max_body_bytes, Some(on_complete))
}

fn H1Codec::make(
  stream : &Stream,
  max_body_bytes : Int,
  on_complete : ((Bool) -> Unit)?,
) -> H1Codec {
  let limit = if max_body_bytes < 0 { 0 } else { max_body_bytes }
  H1Codec::{
    stream,
    reader: @ref.Ref(StreamReader::new(stream)),
    last_is_head: false,
    close_after_request: false,
    max_body_bytes: limit,
    on_complete,
  }
}

struct StreamReader {
  stream : &Stream
  mut pending : Bytes
  mut pending_offset : Int
}

fn StreamReader::new(stream : &Stream) -> StreamReader {
  StreamReader::{ stream, pending: b"", pending_offset: 0 }
}

fn StreamReader::next_byte(self : StreamReader) -> Result[Byte?, NetError] {
  if self.pending_offset < self.pending.length() {
    let byte = self.pending[self.pending_offset]
    self.pending_offset = self.pending_offset + 1
    return Ok(Some(byte))
  }

  self.pending = b""
  self.pending_offset = 0
  let buf = Buffer(size_hint=4096)
  let count = match self.stream.read(buf) {
    Ok(count) => count
    Err(err) => return Err(err)
  }
  if count < 0 {
    return Err(NetError::ReadError("invalid read count"))
  }
  if count == 0 {
    return Ok(None)
  }
  self.pending = buf.to_bytes()
  if self.pending.length() == 0 {
    return Err(NetError::ReadError("stream returned no data"))
  }
  let byte = self.pending[0]
  self.pending_offset = 1
  Ok(Some(byte))
}

fn StreamReader::read_exact(
  self : StreamReader,
  length : Int,
  output : Array[Byte],
) -> Result[Unit, NetError] {
  let mut remaining = length
  while remaining > 0 {
    if self.pending_offset >= self.pending.length() {
      self.pending = b""
      self.pending_offset = 0
      let hint = if remaining > 8192 { 8192 } else { remaining }
      let buf = Buffer(size_hint=hint)
      let count = match self.stream.read(buf) {
        Ok(count) => count
        Err(err) => return Err(err)
      }
      if count < 0 {
        return Err(NetError::ReadError("invalid read count"))
      }
      if count == 0 {
        return Err(NetError::ReadError("unexpected end of response body"))
      }
      self.pending = buf.to_bytes()
      if self.pending.length() == 0 {
        return Err(NetError::ReadError("stream returned no data"))
      }
    }
    let available = self.pending.length() - self.pending_offset
    let take = if available < remaining { available } else { remaining }
    let mut i = 0
    while i < take {
      output.push(self.pending[self.pending_offset + i])
      i = i + 1
    }
    self.pending_offset = self.pending_offset + take
    remaining = remaining - take
  }
  Ok(())
}

fn StreamReader::read_some(
  self : StreamReader,
  output : Buffer,
  max_bytes : Int,
) -> Result[Int, NetError] {
  if max_bytes <= 0 {
    return Ok(0)
  }
  if self.pending_offset < self.pending.length() {
    let available = self.pending.length() - self.pending_offset
    let take = if available < max_bytes { available } else { max_bytes }
    let mut i = 0
    while i < take {
      output.write_byte(self.pending[self.pending_offset + i])
      i = i + 1
    }
    self.pending_offset = self.pending_offset + take
    return Ok(take)
  }

  self.pending = b""
  self.pending_offset = 0
  let hint = if max_bytes > 8192 { 8192 } else { max_bytes }
  let buf = Buffer(size_hint=hint)
  let count = match self.stream.read(buf) {
    Ok(count) => count
    Err(err) => return Err(err)
  }
  if count < 0 {
    return Err(NetError::ReadError("invalid read count"))
  }
  if count == 0 {
    return Ok(0)
  }
  let bytes = buf.to_bytes()
  if bytes.length() == 0 {
    return Err(NetError::ReadError("stream returned no data"))
  }
  let take = if bytes.length() < max_bytes { bytes.length() } else { max_bytes }
  output.write_bytes(bytes.exact_view(start=0, end=take))
  if take < bytes.length() {
    self.pending = bytes
    self.pending_offset = take
  }
  Ok(take)
}

fn write_all(stream : &Stream, data : Bytes) -> Result[Unit, NetError] {
  let total = data.length()
  let mut offset = 0
  while offset < total {
    let chunk = @buffer.from_bytes(data.exact_view(start=offset))
    let result = stream.write(chunk)
    match result {
      Ok(written) => {
        if written <= 0 {
          return Err(NetError::WriteError("stream made no progress"))
        }
        if written > total - offset {
          return Err(NetError::WriteError("stream reported too many bytes written"))
        }
        offset = offset + written
      }
      Err(err) => return Err(err)
    }
  }
  Ok(())
}

fn is_header_token_char(ch : Char) -> Bool {
  (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
  (ch >= '0' && ch <= '9') || ch == '!' || ch == '#' || ch == '$' ||
  ch == '%' || ch == '&' || ch == '\u{27}' || ch == '*' || ch == '+' ||
  ch == '-' || ch == '.' || ch == '^' || ch == '_' || ch == '\u{60}' ||
  ch == '|' || ch == '~'
}

fn valid_header_name(name : String) -> Bool {
  if name.length() == 0 {
    return false
  }
  for ch in name {
    if !is_header_token_char(ch) {
      return false
    }
  }
  true
}

fn valid_header_value(value : String) -> Bool {
  for ch in value {
    if (ch < ' ' && ch != '\t') || ch == '\u{7f}' {
      return false
    }
  }
  true
}

fn trim_header_ows(value : String) -> String {
  let mut start = 0
  while start < value.length() {
    let ch = value.get_char(start)
    if ch == Some(' ') || ch == Some('\t') {
      start = start + 1
    } else {
      break
    }
  }
  let mut end = value.length()
  while end > start {
    let ch = value.get_char(end - 1)
    if ch == Some(' ') || ch == Some('\t') {
      end = end - 1
    } else {
      break
    }
  }
  value[start:end].to_owned()
}

fn valid_request_target(value : String, allow_brackets? : Bool) -> Bool {
  if value.length() == 0 || !valid_encoded_url_chars(value) {
    return false
  }
  for ch in value {
    if ch <= ' ' || ch == '\u{7f}' || ch == '#' {
      return false
    }
    if (ch == '[' || ch == ']') && !allow_brackets.unwrap_or(false) {
      return false
    }
  }
  true
}

fn valid_host_port(value : String) -> Bool {
  if !is_decimal_digits(value) {
    return false
  }
  let port = try {
    @string.parse_int(value[:])
  } catch {
    _ => return false
  }
  port >= 1 && port <= 65535
}

fn valid_host(value : String) -> Bool {
  if value.length() == 0 {
    return false
  }
  if value.has_prefix("[") {
    let close = match value.find("]") {
      Some(index) => index
      None => return false
    }
    if close <= 1 {
      return false
    }
    if !is_ip_literal(value[1:close].to_owned()) {
      return false
    }
    let rest = value[close + 1:]
    if rest.length() == 0 {
      return true
    }
    if !rest.has_prefix(":") {
      return false
    }
    return valid_host_port(rest[1:].to_owned())
  }
  match value.rev_find(":") {
    Some(index) => {
      if index == 0 || value[0:index].contains(":") {
        return false
      }
      valid_url_host_chars(value[0:index].to_owned()) &&
      valid_host_port(value[index + 1:].to_owned())
    }
    None => valid_url_host_chars(value)
  }
}

fn split_header_list(value : String) -> Array[String] {
  let parts : Array[String] = []
  let mut start = 0
  let mut index = 0
  let mut quoted = false
  let mut escaped = false
  while index < value.length() {
    let ch = match value.get_char(index) {
      Some(ch) => ch
      None => {
        // Low surrogate of an astral character: skip it and keep the scalar
        // in the current token. All delimiters handled here are BMP ASCII.
        index = index + 1
        continue
      }
    }
    if escaped {
      escaped = false
    } else if quoted {
      if ch == '\\' {
        escaped = true
      } else if ch == '"' {
        quoted = false
      }
    } else if ch == '"' {
      quoted = true
    } else if ch == ',' {
      parts.push(value[start:index].to_owned())
      start = index + 1
    }
    index = index + 1
  }
  parts.push(value[start:].to_owned())
  parts
}

fn header_has_token(value : String, token : String) -> Bool {
  let token = token.to_lower()
  for part in split_header_list(value) {
    if part.trim().to_owned().to_lower() == token {
      return true
    }
  }
  false
}

fn headers_have_token(headers : Headers, name : String, token : String) -> Bool {
  for value in headers.get_all(name) {
    if header_has_token(value, token) {
      return true
    }
  }
  false
}

fn request_content_length(headers : Headers) -> Result[Option[Int], HttpError] {
  let values = headers.get_all("Content-Length")
  if values.length() == 0 {
    return Ok(None)
  }
  if values.length() > 1 {
    return Err(InvalidHeader("Content-Length"))
  }
  let text = values.nth(0).unwrap().trim().to_owned()
  if !is_decimal_digits(text) {
    return Err(InvalidHeader("Content-Length"))
  }
  let length = try {
    @string.parse_int(text[:])
  } catch {
    _ => return Err(InvalidHeader("Content-Length"))
  }
  if length < 0 {
    return Err(InvalidHeader("Content-Length"))
  }
  Ok(Some(length))
}

fn request_is_chunked(headers : Headers) -> Result[Bool, HttpError] {
  let values = headers.get_all("Transfer-Encoding")
  if values.length() == 0 {
    return Ok(false)
  }
  // Repeated field lines are equivalent to one comma-separated list in the
  // order they appear (RFC 9110 §5.3), so combine them before parsing.
  let mut combined = ""
  for value in values {
    if combined.length() > 0 {
      combined = combined + ", "
    }
    combined = combined + value
  }
  let mut seen = false
  for part in split_header_list(combined) {
    if part.trim().length() == 0 {
      continue
    }
    if !valid_transfer_coding(part) {
      return Err(InvalidHeader("Transfer-Encoding"))
    }
    let token = transfer_coding_name(part)
    if token != "chunked" || seen {
      return Err(InvalidHeader("Transfer-Encoding"))
    }
    seen = true
  }
  if !seen {
    return Err(InvalidHeader("Transfer-Encoding"))
  }
  Ok(true)
}

/// Methods for which an absent body still has a defined meaning, so an explicit
/// `Content-Length: 0` should be sent when the caller did not frame the body.
fn method_defines_body(method : HttpMethod) -> Bool {
  match method {
    POST => true
    PUT => true
    PATCH => true
    _ => false
  }
}

fn validate_request_trailers(trailers : Headers) -> Result[Unit, HttpError] {
  for trailer in trailers.iter() {
    if !valid_header_name(trailer.name) ||
      !valid_header_value(trailer.value) ||
      is_forbidden_trailer_field(trailer.name) {
      return Err(InvalidHeader(trailer.name))
    }
  }
  Ok(())
}

fn request_trailer_names(trailers : Headers) -> String {
  let names = Buffer(size_hint=64)
  for trailer in trailers.iter() {
    if names.length() > 0 {
      names.write_bytes(@utf8.encode(", "))
    }
    names.write_bytes(@utf8.encode(trailer.name))
  }
  @utf8.decode_lossy(names.to_bytes()[:])
}

fn write_chunked_body(
  stream : &Stream,
  body : Bytes,
  trailers : Headers,
) -> Result[Unit, NetError] {
  if body.length() > 0 {
    let size_line = body.length().to_string(radix=16) + "\r\n"
    match write_all(stream, @utf8.encode(size_line)) {
      Ok(_) => ()
      Err(err) => return Err(err)
    }
    match write_all(stream, body) {
      Ok(_) => ()
      Err(err) => return Err(err)
    }
    match write_all(stream, @utf8.encode("\r\n")) {
      Ok(_) => ()
      Err(err) => return Err(err)
    }
  }
  match write_all(stream, @utf8.encode("0\r\n")) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  for trailer in trailers.iter() {
    match write_all(
      stream,
      @utf8.encode(trailer.name + ": " + trailer.value + "\r\n"),
    ) {
      Ok(_) => ()
      Err(err) => return Err(err)
    }
  }
  write_all(stream, @utf8.encode("\r\n"))
}

/// Encode HTTP request to HTTP/1.1 format.
///
/// `absolute_form` selects the request-target form: `false` (the default) sends
/// origin-form (`path?query`) for direct connections, `true` sends
/// absolute-form (`http://host/path`) as required when talking to a forward
/// proxy over plain HTTP (RFC 9112 §3.2.2).
pub fn H1Codec::encode_request(
  self : H1Codec,
  req : Request,
  absolute_form? : Bool,
) -> Result[Unit, HttpError] {
  // A request replaces any framing state left by a previous encode that never
  // reached the wire; success below sets the state for this request.
  self.last_is_head = false
  self.close_after_request = false
  if !valid_url_path_chars(req.url.path) ||
    !valid_url_query_chars(req.url.query) {
    return Err(InvalidUrl("Invalid request target"))
  }
  let absolute = absolute_form.unwrap_or(false) && req.url.scheme.to_lower() == "http"
  let target = if absolute {
    req.url.origin() + req.url.request_target()
  } else {
    req.url.request_target()
  }
  if !valid_request_target(target, allow_brackets=absolute) {
    return Err(InvalidUrl("Invalid request target"))
  }
  if !valid_host(req.url.authority()) {
    return Err(InvalidUrl("Invalid host"))
  }
  let req_line = req.method.to_string() + " " + target + " HTTP/1.1\r\n"

  for header in req.headers.iter() {
    if !valid_header_name(header.name) || !valid_header_value(header.value) {
      return Err(InvalidHeader(header.name))
    }
  }
  let host_values = req.headers.get_all("Host")
  if host_values.length() > 1 {
    return Err(InvalidHeader("Host"))
  }
  if host_values.length() == 1 && !valid_host(host_values.nth(0).unwrap()) {
    return Err(InvalidHeader("Host"))
  }

  let content_length = match request_content_length(req.headers) {
    Ok(value) => value
    Err(err) => return Err(err)
  }
  let mut chunked = match request_is_chunked(req.headers) {
    Ok(value) => value
    Err(err) => return Err(err)
  }
  if content_length is Some(_) && chunked {
    return Err(InvalidHeader("Transfer-Encoding"))
  }

  let has_trailers = req.trailers.length() > 0
  if has_trailers {
    match validate_request_trailers(req.trailers) {
      Ok(_) => ()
      Err(err) => return Err(err)
    }
    // Trailers need a self-delimiting body, so they cannot coexist with an
    // explicit Content-Length. Chunked framing can be selected implicitly.
    if content_length is Some(_) {
      return Err(InvalidHeader("Content-Length"))
    }
    chunked = true
  }
  let synthesize_chunked = has_trailers && !req.headers.contains("Transfer-Encoding")

  let body_length = match req.body {
    Some(body) => body.length()
    None => 0
  }
  match content_length {
    Some(declared) => if declared != body_length {
      return Err(InvalidHeader("Content-Length"))
    }
    None => ()
  }

  // Build headers
  let mut headers_str = ""

  // Add Host header if not present
  if !req.headers.contains("Host") {
    headers_str += "Host: " + req.url.authority() + "\r\n"
  }

  // Add Content-Length when the caller did not choose a framing mode. Methods
  // that define a body send an explicit zero length when none was supplied so
  // servers and intermediaries never have to guess (RFC 9112 §6.3).
  if (req.body is Some(_) || method_defines_body(req.method)) &&
    content_length is None && !chunked {
    headers_str += "Content-Length: " + body_length.to_string() + "\r\n"
  }

  // Request trailers require chunked framing. Advertise both the framing and
  // the trailer names when the caller did not provide them explicitly.
  if synthesize_chunked {
    headers_str += "Transfer-Encoding: chunked\r\n"
  }
  if has_trailers && !req.headers.contains("Trailer") {
    headers_str += "Trailer: " + request_trailer_names(req.trailers) + "\r\n"
  }

  // Add User-Agent if not present
  if !req.headers.contains("User-Agent") {
    headers_str += "User-Agent: Feather/0.1.0\r\n"
  }

  // Add other headers
  for header in req.headers.iter() {
    headers_str += header.name + ": " + header.value + "\r\n"
  }

  // End headers
  headers_str += "\r\n"

  // Write request line and headers
  let header_data = @utf8.encode(req_line + headers_str)
  match write_all(self.stream, header_data) {
    Ok(_) => ()
    Err(err) => return Err(NetworkError(err))
  }

  // Write body using the selected framing
  let body_result = if chunked {
    match req.body {
      Some(body) => write_chunked_body(self.stream, body, req.trailers)
      None => write_chunked_body(self.stream, b"", req.trailers)
    }
  } else {
    match req.body {
      Some(body) => write_all(self.stream, body)
      None => Ok(())
    }
  }
  match body_result {
    Ok(_) => ()
    Err(err) => return Err(NetworkError(err))
  }

  // Flush the stream
  match self.reader.val.stream.flush() {
    Ok(_) => {
      self.last_is_head = req.method == HEAD
      self.close_after_request = headers_have_token(req.headers, "Connection", "close")
      Ok(())
    }
    Err(err) => Err(NetworkError(err))
  }
}

fn read_line(
  reader : StreamReader,
  max_bytes? : Int,
) -> Result[String?, NetError] {
  let limit = match max_bytes {
    Some(value) => value
    None => 8192
  }
  let line = Buffer(size_hint=128)
  let mut any = false
  while true {
    let byte = match reader.next_byte() {
      Ok(Some(byte)) => byte
      Ok(None) => {
        if !any {
          return Ok(None)
        }
        break
      }
      Err(err) => return Err(err)
    }
    any = true
    line.write_byte(byte)
    if line.length() > limit {
      return Err(NetError::ReadError("response line too long"))
    }
    if byte == b'\n' {
      break
    }
  }
  let bytes = line.to_bytes()
  let length = bytes.length()
  let end = if length >= 2 && bytes[length - 2] == b'\r' && bytes[length - 1] == b'\n' {
    length - 2
  } else if length >= 1 && bytes[length - 1] == b'\n' {
    length - 1
  } else {
    length
  }
  Ok(Some(@utf8.decode_lossy(bytes.exact_view(start=0, end=end))))
}

struct ResponseHead {
  version : String
  status : Int
  headers : Headers
}

const MAX_RESPONSE_HEADERS : Int = 200
/// Bound the whole response head, not just each line: 200 lines of 8 KiB
/// would otherwise allow a peer to make the client buffer more than a
/// megabyte before the body framing is even known.
const MAX_RESPONSE_HEAD_BYTES : Int = 1048576

fn read_response_head(reader : StreamReader) -> Result[ResponseHead, HttpError] {
  let response_line = match read_line(reader) {
    Ok(Some(line)) => line
    Ok(None) => return Err(ProtocolError("Invalid response line"))
    Err(err) => return Err(NetworkError(err))
  }
  let mut head_bytes = @utf8.encode(response_line).length() + 2
  if head_bytes > MAX_RESPONSE_HEAD_BYTES {
    return Err(ProtocolError("Response header section too large"))
  }
  let first_space = match response_line.find(" ") {
    Some(index) => index
    None => return Err(ProtocolError("Invalid response line"))
  }
  let version = response_line[0:first_space].to_owned()
  if version != "HTTP/1.1" && version != "HTTP/1.0" {
    return Err(ProtocolError("Unsupported HTTP version"))
  }
  let mut status_start = first_space
  while status_start < response_line.length() &&
    response_line.get_char(status_start) == Some(' ') {
    status_start = status_start + 1
  }
  let mut status_end = status_start
  while status_end < response_line.length() &&
    response_line.get_char(status_end) != Some(' ') {
    status_end = status_end + 1
  }
  if status_end - status_start != 3 {
    return Err(ProtocolError("Invalid status code"))
  }
  let status_text = response_line[status_start:status_end].to_owned()
  if !is_decimal_digits(status_text) {
    return Err(ProtocolError("Invalid status code"))
  }
  let status = try {
    @string.parse_int(status_text[:])
  } catch {
    _ => return Err(ProtocolError("Invalid status code"))
  }
  if status < 100 || status > 599 {
    return Err(ProtocolError("Invalid status code"))
  }
  for ch in response_line[status_end:].to_owned() {
    if (ch < ' ' && ch != '\t') || ch == '\u{7f}' {
      return Err(ProtocolError("Invalid status line"))
    }
  }

  let mut headers = Headers::new()
  let mut header_count = 0
  while true {
    let line = match read_line(reader) {
      Ok(Some(line)) => line
      Ok(None) => return Err(ProtocolError("Unexpected end of response headers"))
      Err(err) => return Err(NetworkError(err))
    }
    if line.length() == 0 {
      break
    }
    head_bytes = head_bytes + @utf8.encode(line).length() + 2
    if head_bytes > MAX_RESPONSE_HEAD_BYTES {
      return Err(ProtocolError("Response header section too large"))
    }
    // Obsolete line folding is ambiguous and must not be accepted.
    if line.get_char(0) == Some(' ') || line.get_char(0) == Some('\t') {
      return Err(ProtocolError("Invalid header format"))
    }
    header_count = header_count + 1
    if header_count > MAX_RESPONSE_HEADERS {
      return Err(ProtocolError("Too many response headers"))
    }

    let colon_idx = match line.find(":") {
      Some(index) => index
      None => return Err(ProtocolError("Invalid header format"))
    }

    let name = line[0:colon_idx].to_owned()
    if !valid_header_name(name) {
      return Err(ProtocolError("Invalid header format"))
    }
    let value = trim_header_ows(line[colon_idx + 1:].to_owned())
    if !valid_header_value(value) {
      return Err(ProtocolError("Invalid header value"))
    }

    headers = headers.add(name, value)
  }

  Ok(ResponseHead::{ version, status, headers })
}

/// Decode HTTP response from HTTP/1.1 format
pub fn H1Codec::decode_response(
  self : H1Codec,
  head? : Bool,
) -> Result[Response, HttpError] {
  let is_head = match head {
    Some(value) => value
    None => self.last_is_head
  }
  // This response consumes the state set by encode_request, even if decoding
  // fails. Leaving a stale HEAD/Connection flag behind would mis-frame a later
  // response when the codec is reused after an error.
  let request_close = self.close_after_request
  self.last_is_head = false
  self.close_after_request = false
  let mut informational_count = 0
  while true {
    let response_head = match read_response_head(self.reader.val) {
      Ok(head) => head
      Err(err) => return Err(err)
    }
    // Interim responses cannot carry content, so framing fields are forbidden
    // on them (RFC 9110 §8.6 and RFC 9112 §6.1). Rejecting them also avoids
    // accidentally treating framing metadata meant for a later response as
    // part of the interim head.
    if response_head.status >= 100 && response_head.status < 200 &&
      (response_head.headers.contains("Content-Length") ||
        response_head.headers.contains("Transfer-Encoding")) {
      return Err(ProtocolError("Informational response must not include framing headers"))
    }
    // Skip interim responses such as 100 Continue; 101 is a final response.
    if response_head.status >= 100 && response_head.status < 200 &&
      response_head.status != 101 {
      informational_count = informational_count + 1
      if informational_count > 8 {
        return Err(ProtocolError("Too many informational responses"))
      }
      continue
    }

    let trailers = @ref.Ref(Headers::new())
    let response_stream = ResponseStream::{
      reader: self.reader,
      version: response_head.version,
      headers: response_head.headers,
      status: response_head.status,
      head: is_head,
      max_body_bytes: self.max_body_bytes,
      body_mode: BodyUnknown,
      remaining: 0,
      total_read: 0,
      chunk_state: ChunkSize,
      close_after_body: request_close,
      prepared: false,
      error: None,
      is_open: true,
      on_complete: self.on_complete,
      completed: false,
      released_to_pool: false,
      trailers,
    }
    if self.on_complete is Some(_) {
      // Bodyless and zero-length responses can be completed before the caller
      // sees them. Framing validation still matters: returning a response
      // whose stream is already poisoned would hide a protocol error from
      // callers that never read a (non-existent) body.
      let completed = if is_head || response_head.status == 101 ||
        response_head.status == 204 || response_head.status == 205 ||
        response_head.status == 304 {
        response_stream.prepare()
      } else {
        response_stream.complete_if_empty()
      }
      match completed {
        Ok(_) => ()
        Err(err) => return Err(http_error_from_net(err))
      }
    }
    let response_stream : &Stream = response_stream

    return Ok(
      Response::new_with_version(
        response_head.version,
        response_head.status,
        response_head.headers,
        response_stream,
      ).with_trailers(trailers).with_max_body_bytes(self.max_body_bytes),
    )
  }
  Err(ProtocolError("Invalid response"))
}

enum ResponseBodyMode {
  BodyUnknown
  BodyNone
  BodyFixed
  BodyChunked
  BodyUntilEof
}

enum ResponseTransferEncoding {
  TransferEncodingAbsent
  TransferEncodingChunked
  TransferEncodingUntilEof
}

enum ChunkReadState {
  ChunkSize
  ChunkData
}

/// Response stream for reading HTTP response body
struct ResponseStream {
  reader : @ref.Ref[StreamReader]
  version : String
  headers : Headers
  status : Int
  head : Bool
  mut max_body_bytes : Int
  mut body_mode : ResponseBodyMode
  mut remaining : Int
  mut total_read : Int
  mut chunk_state : ChunkReadState
  mut close_after_body : Bool
  mut prepared : Bool
  mut error : NetError?
  mut is_open : Bool
  on_complete : ((Bool) -> Unit)?
  mut completed : Bool
  mut released_to_pool : Bool
  trailers : @ref.Ref[Headers]
}

fn ResponseStream::complete(self : ResponseStream, reusable : Bool) -> Unit {
  if self.completed {
    return
  }
  self.completed = true
  self.released_to_pool = reusable && self.on_complete is Some(_)
  match self.on_complete {
    Some(callback) => callback(reusable)
    None => ()
  }
}

fn ResponseStream::is_released_to_pool(self : ResponseStream) -> Bool {
  self.completed && self.released_to_pool
}

fn skip_chunk_ext_ows(value : String, start : Int) -> Int {
  let mut index = start
  while index < value.length() {
    let ch = value.get_char(index)
    if ch == Some(' ') || ch == Some('\t') {
      index = index + 1
    } else {
      break
    }
  }
  index
}

fn is_chunk_quoted_text_char(ch : Char) -> Bool {
  ch == '\t' || ch == ' ' || ch == '!' || (ch >= '#' && ch <= '[') ||
  (ch >= ']' && ch <= '~') || ch >= '\u{80}'
}

fn is_chunk_quoted_pair_char(ch : Char) -> Bool {
  ch == '\t' || ch == ' ' || (ch >= '!' && ch <= '~') || ch >= '\u{80}'
}

fn valid_chunk_extensions(value : String) -> Bool {
  let length = value.length()
  let mut index = 0
  while index < length {
    if value.get_char(index) != Some(';') {
      return false
    }
    index = skip_chunk_ext_ows(value, index + 1)
    let name_start = index
    while index < length {
      let ch = match value.get_char(index) {
        Some(ch) => ch
        None => break
      }
      if !is_header_token_char(ch) {
        break
      }
      index = index + 1
    }
    if index == name_start {
      return false
    }
    let name_end = index
    index = skip_chunk_ext_ows(value, index)
    if index == length && index > name_end {
      return false
    }
    if index < length && value.get_char(index) == Some('=') {
      index = skip_chunk_ext_ows(value, index + 1)
      if index >= length {
        return false
      }
      if value.get_char(index) == Some('"') {
        index = index + 1
        let mut closed = false
        while index < length {
          let ch = match value.get_char(index) {
            Some(ch) => ch
            None => {
              index = index + 1
              continue
            }
          }
          if ch == '"' {
            index = index + 1
            closed = true
            break
          }
          if ch == '\\' {
            index = index + 1
            if index >= length {
              return false
            }
            let escaped = match value.get_char(index) {
              Some(ch) => ch
              None => return false
            }
            if !is_chunk_quoted_pair_char(escaped) {
              return false
            }
          } else if !is_chunk_quoted_text_char(ch) {
            return false
          }
          index = index + 1
        }
        if !closed {
          return false
        }
      } else {
        let token_start = index
        while index < length {
          let ch = match value.get_char(index) {
            Some(ch) => ch
            None => break
          }
          if !is_header_token_char(ch) {
            break
          }
          index = index + 1
        }
        if index == token_start {
          return false
        }
      }
      let value_end = index
      index = skip_chunk_ext_ows(value, index)
      if index == length && index > value_end {
        return false
      }
    }
    if index < length && value.get_char(index) != Some(';') {
      return false
    }
  }
  true
}

fn read_chunk_size(reader : StreamReader) -> Result[Int, NetError] {
  let line = match read_line(reader) {
    Ok(Some(line)) => line
    Ok(None) => return Err(NetError::ReadError("unexpected end of chunked body"))
    Err(err) => return Err(err)
  }
  let extension_index = line.find(";")
  let size_text = match extension_index {
    Some(index) => {
      let raw = line[0:index].to_owned()
      // BWS is only allowed between the size and the extension. Leading
      // whitespace is not part of chunk-size and must be rejected.
      if raw.length() == 0 || raw.get_char(0) == Some(' ') ||
        raw.get_char(0) == Some('\t') {
        return Err(NetError::ReadError("invalid chunk size"))
      }
      let mut end = raw.length()
      while end > 0 {
        let ch = raw.get_char(end - 1)
        if ch == Some(' ') || ch == Some('\t') {
          end = end - 1
        } else {
          break
        }
      }
      raw[0:end].to_owned()
    }
    None => line
  }
  if !is_hex_digits(size_text) {
    return Err(NetError::ReadError("invalid chunk size"))
  }
  let size = try {
    @string.parse_int(size_text[:], base=16)
  } catch {
    _ => return Err(NetError::ReadError("invalid chunk size"))
  }
  if size < 0 {
    return Err(NetError::ReadError("invalid chunk size"))
  }
  match extension_index {
    Some(index) =>
      if !valid_chunk_extensions(line[index:].to_owned()) {
        return Err(NetError::ReadError("invalid chunk extension"))
      }
    None => ()
  }
  Ok(size)
}

fn is_forbidden_trailer_field(name : String) -> Bool {
  match name.to_lower() {
    "content-length"
    | "transfer-encoding"
    | "host"
    | "connection"
    | "trailer"
    | "te"
    | "upgrade"
    | "keep-alive"
    | "proxy-connection"
    | "content-encoding"
    | "content-type"
    | "content-range"
    | "authorization"
    | "proxy-authorization"
    | "www-authenticate"
    | "proxy-authenticate"
    | "cookie"
    | "set-cookie"
    | "cache-control"
    | "expect"
    | "max-forwards"
    | "range"
    | "if-match"
    | "if-none-match"
    | "if-modified-since"
    | "if-unmodified-since"
    | "if-range" => true
    _ => false
  }
}

fn consume_chunk_trailers(
  reader : StreamReader,
  trailers : @ref.Ref[Headers],
) -> Result[Unit, NetError] {
  let mut trailer_count = 0
  let mut trailer_bytes = 0
  let mut collected = Headers::new()
  while true {
    let trailer = match read_line(reader) {
      Ok(Some(trailer)) => trailer
      Ok(None) => return Err(NetError::ReadError("unexpected end of chunked trailers"))
      Err(err) => return Err(err)
    }
    if trailer.length() == 0 {
      trailers.val = collected
      return Ok(())
    }
    trailer_bytes = trailer_bytes + @utf8.encode(trailer).length() + 2
    if trailer_bytes > MAX_RESPONSE_HEAD_BYTES {
      return Err(NetError::ReadError("chunked trailer section too large"))
    }
    if trailer.get_char(0) == Some(' ') || trailer.get_char(0) == Some('\t') {
      return Err(NetError::ReadError("invalid chunked trailer"))
    }
    trailer_count = trailer_count + 1
    if trailer_count > MAX_RESPONSE_HEADERS {
      return Err(NetError::ReadError("too many chunked trailers"))
    }
    let colon_idx = match trailer.find(":") {
      Some(index) => index
      None => return Err(NetError::ReadError("invalid chunked trailer"))
    }
    let name = trailer[0:colon_idx].to_owned()
    let value = trim_header_ows(trailer[colon_idx + 1:].to_owned())
    if !valid_header_name(name) || !valid_header_value(value) ||
      is_forbidden_trailer_field(name) {
      return Err(NetError::ReadError("invalid chunked trailer"))
    }
    collected = collected.add(name, value)
  }
  Ok(())
}

fn valid_transfer_coding(value : String) -> Bool {
  let length = value.length()
  let mut index = skip_chunk_ext_ows(value, 0)
  let name_start = index
  while index < length {
    let ch = match value.get_char(index) {
      Some(ch) => ch
      None => break
    }
    if !is_header_token_char(ch) {
      break
    }
    index = index + 1
  }
  if index == name_start {
    return false
  }
  index = skip_chunk_ext_ows(value, index)
  while index < length {
    if value.get_char(index) != Some(';') {
      return false
    }
    index = skip_chunk_ext_ows(value, index + 1)
    let parameter_start = index
    while index < length {
      let ch = match value.get_char(index) {
        Some(ch) => ch
        None => break
      }
      if !is_header_token_char(ch) {
        break
      }
      index = index + 1
    }
    if index == parameter_start {
      return false
    }
    index = skip_chunk_ext_ows(value, index)
    if index >= length || value.get_char(index) != Some('=') {
      return false
    }
    index = skip_chunk_ext_ows(value, index + 1)
    if index >= length {
      return false
    }
    if value.get_char(index) == Some('"') {
      index = index + 1
      let mut closed = false
      while index < length {
        let ch = match value.get_char(index) {
          Some(ch) => ch
          None => {
            index = index + 1
            continue
          }
        }
        if ch == '"' {
          index = index + 1
          closed = true
          break
        }
        if ch == '\\' {
          index = index + 1
          if index >= length {
            return false
          }
          let escaped = match value.get_char(index) {
            Some(ch) => ch
            None => return false
          }
          if !is_chunk_quoted_pair_char(escaped) {
            return false
          }
        } else if !is_chunk_quoted_text_char(ch) {
          return false
        }
        index = index + 1
      }
      if !closed {
        return false
      }
    } else {
      let token_start = index
      while index < length {
        let ch = match value.get_char(index) {
          Some(ch) => ch
          None => break
        }
        if !is_header_token_char(ch) {
          break
        }
        index = index + 1
      }
      if index == token_start {
        return false
      }
    }
    index = skip_chunk_ext_ows(value, index)
  }
  true
}

fn transfer_coding_name(value : String) -> String {
  // transfer-coding = token *( OWS ";" OWS transfer-parameter ); parameters
  // do not change the coding's identity, so only the name is significant.
  let token = value.trim().to_owned()
  match token.find(";") {
    Some(index) => token[0:index].trim().to_owned().to_lower()
    None => token.to_lower()
  }
}

fn response_transfer_encoding(
  headers : Headers,
) -> Result[ResponseTransferEncoding, NetError] {
  let values = headers.get_all("Transfer-Encoding")
  if values.length() == 0 {
    return Ok(TransferEncodingAbsent)
  }
  let mut chunked_seen = false
  let mut coding_after_chunked = false
  let mut coding_seen = false
  for value in values {
    for part in split_header_list(value) {
      if part.trim().length() == 0 {
        continue
      }
      if !valid_transfer_coding(part) {
        return Err(NetError::ReadError("invalid Transfer-Encoding"))
      }
      coding_seen = true
      let token = transfer_coding_name(part)
      if token == "chunked" {
        if chunked_seen {
          // Applying the chunked coding more than once is forbidden.
          return Err(NetError::ReadError("invalid Transfer-Encoding"))
        }
        chunked_seen = true
      } else if chunked_seen {
        // Another coding was applied after chunked, so the final coding is
        // not chunked and the response is close-delimited (RFC 9112 §6.3).
        coding_after_chunked = true
      }
    }
  }
  if !coding_seen {
    return Err(NetError::ReadError("invalid Transfer-Encoding"))
  }
  if chunked_seen && !coding_after_chunked {
    Ok(TransferEncodingChunked)
  } else {
    Ok(TransferEncodingUntilEof)
  }
}

/// The transfer codings on a response, in the order they were applied. The
/// chunked coding is included so callers can reason about whether it was the
/// final coding; `ResponseStream` has already removed its framing by the time
/// a decoded body is read.
fn response_transfer_codings(
  headers : Headers,
) -> Result[Array[String], HttpError] {
  let values = headers.get_all("Transfer-Encoding")
  let codings : Array[String] = []
  if values.length() == 0 {
    return Ok(codings)
  }
  let mut chunked_seen = false
  for value in values {
    for part in split_header_list(value) {
      if part.trim().length() == 0 {
        continue
      }
      if !valid_transfer_coding(part) {
        return Err(ProtocolError("invalid Transfer-Encoding"))
      }
      let token = transfer_coding_name(part)
      if token == "chunked" {
        if chunked_seen {
          return Err(ProtocolError("invalid Transfer-Encoding"))
        }
        chunked_seen = true
      }
      codings.push(token)
    }
  }
  if codings.length() == 0 {
    return Err(ProtocolError("invalid Transfer-Encoding"))
  }
  Ok(codings)
}

fn response_content_length(headers : Headers) -> Result[Option[Int], NetError] {
  let mut result : Option[Int] = None
  for header in headers.iter() {
    if header.name.to_lower() == "content-length" {
      for part in header.value.split(",") {
        let value = part.trim().to_owned()
        if !is_decimal_digits(value) {
          return Err(NetError::ReadError("invalid Content-Length"))
        }
        let parsed = try {
          @string.parse_int(value[:])
        } catch {
          _ => return Err(NetError::ReadError("invalid Content-Length"))
        }
        if parsed < 0 {
          return Err(NetError::ReadError("invalid Content-Length"))
        }
        match result {
          None => result = Some(parsed)
          Some(existing) => if existing != parsed {
            return Err(NetError::ReadError("conflicting Content-Length headers"))
          }
        }
      }
    }
  }
  Ok(result)
}

fn ResponseStream::fail(self : ResponseStream, err : NetError) -> NetError {
  let _ = self.reader.val.stream.close()
  self.error = Some(err)
  self.complete(false)
  err
}

fn ResponseStream::prepare(self : ResponseStream) -> Result[Unit, NetError] {
  if self.prepared {
    return Ok(())
  }
  self.prepared = true
  let close_connection = headers_have_token(self.headers, "Connection", "close")
  let keep_alive = headers_have_token(self.headers, "Connection", "keep-alive")
  let close_by_default = self.version == "HTTP/1.0" && !keep_alive
  self.close_after_body = self.close_after_body || close_connection || close_by_default

  // Validate framing fields even for responses that cannot carry a body, so a
  // malformed Content-Length/Transfer-Encoding is not silently pooled.
  let transfer_encoding = match response_transfer_encoding(self.headers) {
    Ok(value) => value
    Err(err) => return Err(self.fail(err))
  }
  // Transfer-Encoding overrides Content-Length, even when the latter is
  // malformed, so only validate Content-Length when no coding is present.
  let content_length = match transfer_encoding {
    TransferEncodingAbsent =>
      match response_content_length(self.headers) {
        Ok(value) => value
        Err(err) => return Err(self.fail(err))
      }
    _ => None
  }

  // 204 responses must not carry framing fields at all (RFC 9110 §8.6,
  // RFC 9112 §6.1). A 205 response may only advertise a zero-length body, so
  // a non-zero Content-Length or any transfer coding is also invalid.
  let invalid_bodyless_framing = match self.status {
    204 =>
      self.headers.contains("Content-Length") ||
      self.headers.contains("Transfer-Encoding")
    205 =>
      (match transfer_encoding {
        TransferEncodingAbsent => false
        _ => true
      }) ||
      (content_length is Some(length) && length != 0)
    _ => false
  }
  if invalid_bodyless_framing {
    return Err(self.fail(NetError::ReadError(
      "invalid framing for bodyless response",
    )))
  }
  // A 304 has no body, so a transfer coding cannot describe a payload we can
  // consume. If the peer nonetheless sends chunked framing after the head,
  // reusing the connection would desynchronize the next response. Close it
  // instead of pooling it.
  if self.status == 304 {
    match transfer_encoding {
      TransferEncodingAbsent => ()
      _ => self.close_after_body = true
    }
  }

  if self.head || self.status == 204 || self.status == 205 || self.status == 304 ||
    (self.status >= 100 && self.status < 200) {
    let reusable = !(self.status == 101 || self.close_after_body) &&
      self.reader.val.pending_offset >= self.reader.val.pending.length()
    if !reusable {
      let _ = self.reader.val.stream.close()
    }
    self.body_mode = BodyNone
    self.complete(reusable)
    return Ok(())
  }

  match transfer_encoding {
    TransferEncodingChunked => {
      self.body_mode = BodyChunked
      return Ok(())
    }
    TransferEncodingUntilEof => {
      self.body_mode = BodyUntilEof
      self.close_after_body = true
      return Ok(())
    }
    TransferEncodingAbsent => ()
  }
  match content_length {
    Some(length) => {
      if length > self.max_body_bytes {
        return Err(self.fail(NetError::ReadError("response body too large")))
      }
      self.remaining = length
      self.body_mode = BodyFixed
    }
    None => {
      self.body_mode = BodyUntilEof
      self.close_after_body = true
    }
  }
  Ok(())
}

fn ResponseStream::complete_if_empty(
  self : ResponseStream,
) -> Result[Unit, NetError] {
  if response_transfer_encoding(self.headers) is Ok(TransferEncodingAbsent) &&
    response_content_length(self.headers) is Ok(Some(0)) {
    match self.prepare() {
      Ok(_) => {
        self.finish()
        Ok(())
      }
      Err(err) => Err(err)
    }
  } else {
    Ok(())
  }
}

fn ResponseStream::finish(self : ResponseStream) -> Unit {
  let reusable = !self.close_after_body &&
    self.reader.val.pending_offset >= self.reader.val.pending.length()
  if !reusable {
    let _ = self.reader.val.stream.close()
    self.complete(false)
  } else {
    self.complete(true)
  }
}

pub impl Stream for ResponseStream with fn set_body_limit(
  self : ResponseStream,
  max_body_bytes : Int,
) -> Unit {
  let limit = if max_body_bytes < 0 { 0 } else { max_body_bytes }
  if limit > self.max_body_bytes {
    self.max_body_bytes = limit
  }
}

pub impl Stream for ResponseStream with fn read(self : ResponseStream, buf : Buffer) -> Result[Int, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  match self.error {
    Some(err) => return Err(err)
    None => ()
  }
  if self.completed {
    return Ok(0)
  }
  if !self.prepared {
    match self.prepare() {
      Ok(_) => ()
      Err(err) => return Err(err)
    }
  }
  if self.completed {
    return Ok(0)
  }

  let limit = 8192
  let mut produced = 0
  while produced < limit {
    match self.body_mode {
      BodyNone | BodyUnknown => break
      BodyFixed => {
        if self.remaining == 0 {
          self.finish()
          break
        }
        let want = if self.remaining < limit - produced {
          self.remaining
        } else {
          limit - produced
        }
        let count = match self.reader.val.read_some(buf, want) {
          Ok(count) => count
          Err(err) => return Err(self.fail(err))
        }
        if count == 0 {
          return Err(self.fail(NetError::ReadError("unexpected end of response body")))
        }
        self.remaining = self.remaining - count
        self.total_read = self.total_read + count
        produced = produced + count
        if self.remaining == 0 {
          self.finish()
          break
        }
      }
      BodyUntilEof => {
        let count = match self.reader.val.read_some(buf, limit - produced) {
          Ok(count) => count
          Err(err) => return Err(self.fail(err))
        }
        if count == 0 {
          let _ = self.reader.val.stream.close()
          self.complete(false)
          break
        }
        if self.total_read > self.max_body_bytes - count {
          return Err(self.fail(NetError::ReadError("response body too large")))
        }
        self.total_read = self.total_read + count
        produced = produced + count
      }
      BodyChunked => {
        match self.chunk_state {
          ChunkSize => {
            let size = match read_chunk_size(self.reader.val) {
              Ok(size) => size
              Err(err) => return Err(self.fail(err))
            }
            if size == 0 {
              match consume_chunk_trailers(self.reader.val, self.trailers) {
                Ok(_) => ()
                Err(err) => return Err(self.fail(err))
              }
              self.finish()
              break
            }
            if size > self.max_body_bytes - self.total_read {
              return Err(self.fail(NetError::ReadError("response body too large")))
            }
            self.remaining = size
            self.chunk_state = ChunkData
          }
          ChunkData => {
            if self.remaining == 0 {
              let terminator : Array[Byte] = []
              match self.reader.val.read_exact(2, terminator) {
                Ok(_) => ()
                Err(err) => return Err(self.fail(err))
              }
              if terminator.length() != 2 || terminator[0] != b'\r' ||
                terminator[1] != b'\n' {
                return Err(self.fail(NetError::ReadError("invalid chunk terminator")))
              }
              self.chunk_state = ChunkSize
              continue
            }
            let want = if self.remaining < limit - produced {
              self.remaining
            } else {
              limit - produced
            }
            let count = match self.reader.val.read_some(buf, want) {
              Ok(count) => count
              Err(err) => return Err(self.fail(err))
            }
            if count == 0 {
              return Err(self.fail(NetError::ReadError("unexpected end of chunked body")))
            }
            self.remaining = self.remaining - count
            self.total_read = self.total_read + count
            produced = produced + count
          }
        }
      }
    }
  }
  Ok(produced)
}

pub impl Stream for ResponseStream with fn write(self : ResponseStream, buf : Buffer) -> Result[Int, NetError] {
  let _ = buf
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Err(NetError::WriteError("Response stream is read-only"))
}

pub impl Stream for ResponseStream with fn flush(self : ResponseStream) -> Result[Unit, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  if self.is_released_to_pool() {
    return Ok(())
  }
  self.reader.val.stream.flush()
}

pub impl Stream for ResponseStream with fn close(self : ResponseStream) -> Result[Unit, NetError] {
  if !self.is_open {
    return Ok(())
  }
  self.is_open = false
  if self.completed && self.on_complete is Some(_) {
    return Ok(())
  }
  match self.on_complete {
    Some(callback) => {
      self.completed = true
      callback(false)
      self.reader.val.stream.close()
    }
    None => self.reader.val.stream.close()
  }
}

pub impl Stream for ResponseStream with fn set_timeout(self : ResponseStream, timeout_ms : Int) -> Result[Unit, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  if self.is_released_to_pool() {
    return Ok(())
  }
  self.reader.val.stream.set_timeout(timeout_ms)
}

pub impl Stream for ResponseStream with fn peer_addr(self : ResponseStream) -> Result[String, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  if self.is_released_to_pool() {
    return Err(NetError::Closed)
  }
  self.reader.val.stream.peer_addr()
}

pub impl Stream for ResponseStream with fn local_addr(self : ResponseStream) -> Result[String, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  if self.is_released_to_pool() {
    return Err(NetError::Closed)
  }
  self.reader.val.stream.local_addr()
}
