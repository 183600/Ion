/// HTTP/1.1 codec for encoding requests and decoding responses
pub struct H1Codec {
  stream : &Stream
  // Shared with the response stream so bytes buffered while reading a head
  // remain visible when the same codec is reused for the next exchange.
  priv reader : @ref.Ref[StreamReader]
  mut last_is_head : Bool
  mut last_is_connect : Bool
  // Whether the most recently encoded request asked for a protocol upgrade.
  // A 101 response is only an upgrade tunnel when the request offered one.
  priv mut last_is_upgrade : Bool
  // Valid protocols offered by the most recent upgrade request, used to make
  // sure a 101 response actually selected one of them.
  priv mut last_upgrade_protocols : Array[String]
  mut close_after_request : Bool
  // Set when a request head carried `Expect: 100-continue` and the body has
  // not been written yet. `decode_response` sends it after an interim 100.
  priv mut deferred_pending : Bool
  priv mut deferred_body_bytes : Bytes
  priv mut deferred_trailers : Headers
  priv mut deferred_chunked : Bool
  // How long to wait for an interim/final response before sending a deferred
  // `Expect: 100-continue` body anyway. A value of 0 waits indefinitely for
  // the response (the historical behavior). Built-in socket transports make
  // this a real poll; other streams fall back to `read_ready`.
  mut expect_timeout_ms : Int
  max_body_bytes : Int
  on_complete : ((Bool) -> Unit)?
}

const DEFAULT_MAX_BODY_BYTES : Int = 67108864
const DEFAULT_EXPECT_CONTINUE_WAIT_MS : Int = 1000
// CONNECT tunnels carry an opaque byte stream rather than a response
// representation, so the normal response-body cap does not apply to them.
const TUNNEL_BODY_LIMIT : Int = 2147483647

pub fn H1Codec::new(stream : &Stream) -> H1Codec {
  H1Codec::new_with_limit(stream, DEFAULT_MAX_BODY_BYTES)
}

pub fn H1Codec::new_with_limit(stream : &Stream, max_body_bytes : Int) -> H1Codec {
  H1Codec::make(stream, max_body_bytes, None)
}

/// Bound how long a request that advertised `Expect: 100-continue` waits for
/// the peer's interim response before sending the body. This avoids a deadlock
/// with peers that ignore the expectation and wait for the body. A value below
/// 1 restores the unbounded (historical) wait.
pub fn H1Codec::with_expect_timeout(
  self : H1Codec,
  timeout_ms : Int,
) -> H1Codec {
  self.expect_timeout_ms = if timeout_ms < 0 { 0 } else { timeout_ms }
  self
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
    last_is_connect: false,
    last_is_upgrade: false,
    last_upgrade_protocols: [],
    close_after_request: false,
    deferred_pending: false,
    deferred_body_bytes: b"",
    deferred_trailers: Headers::new(),
    deferred_chunked: false,
    expect_timeout_ms: DEFAULT_EXPECT_CONTINUE_WAIT_MS,
    max_body_bytes: limit,
    on_complete,
  }
}

struct StreamReader {
  stream : &Stream
  mut pending : Bytes
  mut pending_offset : Int
  // Wire bytes consumed by the most recent read_line, including the line
  // terminator. This keeps size limits byte-based even when invalid UTF-8 is
  // decoded lossily for parsing.
  mut last_line_bytes : Int
}

fn StreamReader::new(stream : &Stream) -> StreamReader {
  StreamReader::{
    stream,
    pending: b"",
    pending_offset: 0,
    last_line_bytes: 0,
  }
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

/// Remove the `100-continue` expectation from one Expect field value while
/// preserving any other expectations the caller supplied. A bodyless request
/// must not advertise an expectation that only applies to request content.
fn without_expect_continue(value : String) -> String {
  let parts : Array[String] = []
  for part in split_header_list(value) {
    let token = part.trim().to_owned()
    if token.length() > 0 && token.to_lower() != "100-continue" {
      parts.push(token)
    }
  }
  parts.join(", ")
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
fn method_defines_body(verb : HttpMethod) -> Bool {
  match canonical_http_method(verb) {
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

fn send_deferred_request_body(
  stream : &Stream,
  body : Bytes,
  trailers : Headers,
  chunked : Bool,
) -> Result[Unit, HttpError] {
  match write_request_body(stream, body, trailers, chunked) {
    Ok(_) => ()
    Err(err) => return Err(http_error_from_net(err))
  }
  match stream.flush() {
    Ok(_) => Ok(())
    Err(err) => Err(http_error_from_net(err))
  }
}

fn write_request_body(
  stream : &Stream,
  body : Bytes,
  trailers : Headers,
  chunked : Bool,
) -> Result[Unit, NetError] {
  if chunked {
    write_chunked_body(stream, body, trailers)
  } else if body.length() > 0 {
    write_all(stream, body)
  } else {
    Ok(())
  }
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
  self.last_is_connect = false
  self.last_is_upgrade = false
  self.last_upgrade_protocols = []
  self.close_after_request = false
  self.deferred_pending = false
  let resolved_method = canonical_http_method(req.method)
  if !valid_url_path_chars(req.url.path) ||
    !valid_url_query_chars(req.url.query) {
    return Err(InvalidUrl("Invalid request target"))
  }
  let is_connect = resolved_method == CONNECT
  if is_connect && (req.url.path != "/" || req.url.query.length() > 0) {
    return Err(InvalidUrl("CONNECT requires an authority-form target"))
  }
  let absolute = !is_connect && absolute_form.unwrap_or(false)
  let asterisk_form = req.url.path == "*"
  if asterisk_form && resolved_method != OPTIONS {
    return Err(InvalidUrl("Asterisk-form is only valid for OPTIONS"))
  }
  if asterisk_form && req.url.query.length() > 0 {
    return Err(InvalidUrl("Asterisk-form cannot include a query"))
  }
  let target = if is_connect {
    req.url.connect_authority()
  } else if asterisk_form {
    "*"
  } else if absolute {
    req.url.origin() + req.url.request_target()
  } else {
    req.url.request_target()
  }
  if !valid_request_target(target, allow_brackets=absolute || is_connect) {
    return Err(InvalidUrl("Invalid request target"))
  }
  if !valid_host(if is_connect { target } else { req.url.authority() }) {
    return Err(InvalidUrl("Invalid host"))
  }
  let host_header_value = if is_connect {
    target
  } else {
    req.url.authority()
  }
  let verb = resolved_method.to_string()
  // `HttpMethod::Custom` is public, so validate the token again at the wire
  // boundary instead of relying only on the constructor.
  if !valid_header_name(verb) {
    return Err(InvalidMethod(verb))
  }
  let req_line = verb + " " + target + " HTTP/1.1\r\n"

  for header in req.headers.iter() {
    if !valid_header_name(header.name) || !valid_header_value(header.value) {
      return Err(InvalidHeader(header.name))
    }
  }
  // RFC 9110 §7.8: an Upgrade field is only meaningful when the request also
  // nominates `upgrade` in Connection. A lone Upgrade field would be ignored
  // by conforming peers, so reject it instead of sending contradictory
  // framing.
  if req.headers.contains("Upgrade") &&
    (!headers_have_token(req.headers, "Connection", "upgrade") ||
      upgrade_protocols(req.headers).length() == 0) {
    return Err(InvalidHeader("Upgrade"))
  }
  let host_values = req.headers.get_all("Host")
  if host_values.length() > 1 {
    return Err(InvalidHeader("Host"))
  }
  if host_values.length() == 1 && !valid_host(host_values.nth(0).unwrap()) {
    return Err(InvalidHeader("Host"))
  }
  // RFC 9110 §9.3.6 requires the Host field of a CONNECT request to be
  // identical to the authority-form request-target. Accepting a different
  // value would make the tunnel endpoint ambiguous for proxies.
  if is_connect && host_values.length() == 1 &&
    lowercase_host_preserving_zone(host_values.nth(0).unwrap()) !=
      lowercase_host_preserving_zone(host_header_value) {
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
  // RFC 9110 §9.3.8: a client MUST NOT generate content in a TRACE request.
  if resolved_method == TRACE && (body_length > 0 || req.trailers.length() > 0) {
    return Err(InvalidHeader("TRACE request content is not allowed"))
  }
  // CONNECT establishes a tunnel rather than transferring request content.
  // Rejecting framed bodies avoids sending a body the peer would interpret as
  // the first bytes of the tunnelled protocol.
  if is_connect && (req.body is Some(_) || req.trailers.length() > 0 ||
    chunked || content_length is Some(_)) {
    return Err(InvalidHeader("CONNECT request content is not allowed"))
  }
  match content_length {
    Some(declared) => if declared != body_length {
      return Err(InvalidHeader("Content-Length"))
    }
    None => ()
  }

  // Build headers
  let mut headers_str = ""

  // Add Host header if not present. CONNECT uses its authority-form target so
  // the port is always present, matching RFC 9110 §9.3.6.
  if !req.headers.contains("Host") {
    headers_str += "Host: " + host_header_value + "\r\n"
  }

  // Add Content-Length when the caller did not choose a framing mode. Methods
  // that define a body send an explicit zero length when none was supplied so
  // servers and intermediaries never have to guess (RFC 9112 §6.3).
  if (req.body is Some(_) || method_defines_body(resolved_method)) &&
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

  // RFC 9110 §10.1.1: a client must not send a 100-continue expectation for a
  // request that has no content. Trailers still count as content because they
  // require the deferred chunked terminator to be sent.
  let defer_body = headers_have_token(req.headers, "Expect", "100-continue") &&
    (body_length > 0 || has_trailers)

  // Add other headers. RFC 6265 §5.4 requires a request to carry at most one
  // Cookie field, so combine repeated caller-supplied fragments with "; " at
  // the position of the first one instead of emitting several field lines.
  let mut cookie_written = false
  for header in req.headers.iter() {
    if header.name.to_lower() == "expect" &&
      headers_have_token(req.headers, "Expect", "100-continue") && !defer_body {
      let filtered = without_expect_continue(header.value)
      if filtered.length() > 0 {
        headers_str += header.name + ": " + filtered + "\r\n"
      }
      continue
    }
    if header.name.to_lower() == "cookie" {
      if cookie_written {
        continue
      }
      cookie_written = true
      headers_str += header.name + ": " +
        req.headers.get_all("Cookie").to_array().join("; ") +
        "\r\n"
      continue
    }
    headers_str += header.name + ": " + header.value + "\r\n"
  }

  // End headers
  headers_str += "\r\n"

  // Write request line and headers
  let header_data = @utf8.encode(req_line + headers_str)
  match write_all(self.stream, header_data) {
    Ok(_) => ()
    Err(err) => return Err(http_error_from_net(err))
  }

  let body = match req.body {
    Some(body) => body
    None => b""
  }
  // RFC 9110 §10.1.1: when the client advertises `Expect: 100-continue`, it
  // waits for an interim response before sending the content. The body is
  // written by `decode_response` once a 100 arrives; a final response without
  // one means the peer does not want the body (for example 417). A bodyless
  // request never has a deferred body to send.
  if defer_body {
    self.deferred_body_bytes = body
    self.deferred_trailers = req.trailers
    self.deferred_chunked = chunked
    self.deferred_pending = true
  } else {
    match write_request_body(self.stream, body, req.trailers, chunked) {
      Ok(_) => ()
      Err(err) => return Err(http_error_from_net(err))
    }
  }

  // Flush the stream
  match self.reader.val.stream.flush() {
    Ok(_) => {
      self.last_is_head = resolved_method == HEAD
      self.last_is_connect = is_connect
      self.last_is_upgrade = request_requests_upgrade(req.headers)
      self.last_upgrade_protocols = upgrade_protocols(req.headers)
      self.close_after_request = headers_have_token(req.headers, "Connection", "close")
      Ok(())
    }
    Err(err) => Err(http_error_from_net(err))
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
  reader.last_line_bytes = length
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
  // RFC 9112 §2.2 allows a client to ignore empty lines received before the
  // response-line. Bound them with the same head budget so a peer cannot send
  // unlimited blank lines before the status line.
  let mut head_bytes = 0
  let mut response_line = ""
  while true {
    let line = match read_line(reader) {
      Ok(Some(line)) => line
      Ok(None) => return Err(ProtocolError("Invalid response line"))
      Err(err) => return Err(http_error_from_net(err))
    }
    head_bytes = head_bytes + reader.last_line_bytes
    if head_bytes > MAX_RESPONSE_HEAD_BYTES {
      return Err(ProtocolError("Response header section too large"))
    }
    if line.length() > 0 {
      response_line = line
      break
    }
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
      Err(err) => return Err(http_error_from_net(err))
    }
    if line.length() == 0 {
      break
    }
    head_bytes = head_bytes + reader.last_line_bytes
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

/// Whether one `Upgrade` protocol value has the RFC 9110 grammar
/// `protocol-name [ "/" protocol-version ]`, with both parts being tokens.
fn valid_upgrade_protocol(value : String) -> Bool {
  let slash = match value.find("/") {
    Some(index) => index
    None => return value.length() > 0 && {
      let mut valid = true
      for ch in value {
        if !is_header_token_char(ch) {
          valid = false
        }
      }
      valid
    }
  }
  let name = value[0:slash].to_owned()
  let version = value[slash + 1:].to_owned()
  if name.length() == 0 || version.length() == 0 {
    return false
  }
  for ch in name {
    if !is_header_token_char(ch) {
      return false
    }
  }
  for ch in version {
    if !is_header_token_char(ch) {
      return false
    }
  }
  true
}

/// Collect the valid protocol tokens offered by `Upgrade` headers.
fn upgrade_protocols(headers : Headers) -> Array[String] {
  let protocols : Array[String] = []
  for value in headers.get_all("Upgrade") {
    for part in split_header_list(value) {
      let token = part.trim().to_owned().to_lower()
      if token.length() > 0 && valid_upgrade_protocol(token) &&
        !protocols.contains(token) {
        protocols.push(token)
      }
    }
  }
  protocols
}

/// Whether the response headers confirm a switch to one of the protocols the
/// request offered. Both `Connection: Upgrade` and a matching `Upgrade` field
/// are required by RFC 9110 §7.8.
fn response_confirms_upgrade(
  headers : Headers,
  requested : Array[String],
) -> Bool {
  if !headers_have_token(headers, "Connection", "upgrade") {
    return false
  }
  for protocol in upgrade_protocols(headers) {
    if requested.contains(protocol) {
      return true
    }
  }
  false
}

/// Whether a request explicitly offered a protocol upgrade. Both the
/// `Connection: Upgrade` nomination and a non-empty, valid `Upgrade` field are
/// required; otherwise a 101 response is unsolicited.
fn request_requests_upgrade(headers : Headers) -> Bool {
  headers_have_token(headers, "Connection", "upgrade") &&
  upgrade_protocols(headers).length() > 0
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
  let request_connect = self.last_is_connect
  let request_upgrade = self.last_is_upgrade
  let request_upgrade_protocols = self.last_upgrade_protocols
  self.last_is_head = false
  self.last_is_connect = false
  self.last_is_upgrade = false
  self.last_upgrade_protocols = []
  self.close_after_request = false
  // A deferred body belongs to the request that produced the response being
  // read now. Take it out of the codec so an error, a final response without
  // 100, or a reused codec can never send it with a later exchange.
  let deferred_pending = self.deferred_pending
  let deferred_body_bytes = self.deferred_body_bytes
  let deferred_trailers = self.deferred_trailers
  let deferred_chunked = self.deferred_chunked
  self.deferred_pending = false
  let mut deferred_body_sent = false
  // The wait is attempted once, before reading the first response byte. Once
  // the peer has started responding (for example with 103 Early Hints), keep
  // reading its response instead of starting a second wait.
  let mut expect_wait_done = false
  let mut informational_count = 0
  let early_hints : Array[(Int, Headers)] = []
  while true {
    if deferred_pending && !deferred_body_sent && !expect_wait_done {
      expect_wait_done = true
      if self.expect_timeout_ms > 0 &&
        self.reader.val.pending_offset >= self.reader.val.pending.length() {
        match self.reader.val.stream.wait_readable(self.expect_timeout_ms) {
          Ok(true) => ()
          Ok(false) => {
            // The peer did not answer the expectation in time. Send the body
            // rather than blocking forever; a later 100 is still consumed and
            // must not cause the body to be sent twice.
            match send_deferred_request_body(
              self.reader.val.stream,
              deferred_body_bytes,
              deferred_trailers,
              deferred_chunked,
            ) {
              Ok(_) => ()
              Err(err) => return Err(err)
            }
            deferred_body_sent = true
          }
          Err(err) => return Err(http_error_from_net(err))
        }
      }
    }
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
    // Keep interim headers for callers that act on `103 Early Hints`. A 101
    // is the final protocol switch response, not an early hint.
    if response_head.status >= 100 && response_head.status < 200 &&
      response_head.status != 101 {
      early_hints.push((response_head.status, response_head.headers))
    }
    // A 100 Continue accepts the deferred request content. Other interim
    // responses (such as 103 Early Hints) do not, so the body stays pending.
    if response_head.status == 100 && !deferred_body_sent && deferred_pending {
      match send_deferred_request_body(
        self.reader.val.stream,
        deferred_body_bytes,
        deferred_trailers,
        deferred_chunked,
      ) {
        Ok(_) => ()
        Err(err) => return Err(err)
      }
      deferred_body_sent = true
    }
    // Skip interim responses such as 100 Continue; 101 is a final response.
    if response_head.status >= 100 && response_head.status < 200 &&
      response_head.status != 101 {
      informational_count = informational_count + 1
      if informational_count > 8 {
        return Err(ProtocolError("Too many informational responses"))
      }
      // The peer has started responding but has not accepted the deferred
      // body yet. Re-arm the bounded wait for the next response so a peer that
      // sends early hints and then waits for the request body cannot deadlock.
      if deferred_pending && !deferred_body_sent {
        expect_wait_done = false
      }
      continue
    }

    // A 101 response switches only to a protocol the request actually
    // offered. A 101 without any offer is still returned as a bodyless
    // response, but the connection is closed rather than pooled. A 101 that
    // answers an offer with a different/missing protocol is malformed and
    // must not become a tunnel.
    let upgrade_tunnel = response_head.status == 101 && request_upgrade &&
      response_confirms_upgrade(response_head.headers, request_upgrade_protocols)
    if response_head.status == 101 && request_upgrade && !upgrade_tunnel {
      let _ = self.reader.val.stream.close()
      return Err(ProtocolError("HTTP/1.1 101 response does not confirm the requested upgrade"))
    }
    // A successful CONNECT response switches to the tunnelled stream. It is
    // close-delimited and must not carry HTTP body framing (RFC 9110 §9.3.6).
    let connect_tunnel = request_connect &&
      response_head.status >= 200 && response_head.status < 300
    if connect_tunnel &&
      (response_head.headers.contains("Content-Length") ||
        response_head.headers.contains("Transfer-Encoding")) {
      return Err(ProtocolError(
        "Successful CONNECT response must not include framing headers",
      ))
    }
    let trailers = @ref.Ref(Headers::new())
    let response_stream = ResponseStream::{
      reader: self.reader,
      version: response_head.version,
      headers: response_head.headers,
      status: response_head.status,
      head: is_head,
      tunnel: connect_tunnel || upgrade_tunnel,
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
    if connect_tunnel || upgrade_tunnel {
      response_stream.body_mode = BodyUntilEof
      response_stream.close_after_body = true
      response_stream.prepared = true
    } else if deferred_pending && !deferred_body_sent {
      // The peer answered before accepting the deferred request content. The
      // request body was never written, so its framing is incomplete; even a
      // response that looks reusable must not put this connection back in the
      // pool, where the remaining request-body bytes would corrupt the next
      // exchange.
      response_stream.close_after_body = true
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
      )
        .with_trailers(trailers)
        .with_early_hints(early_hints)
        .with_max_body_bytes(
          if connect_tunnel || upgrade_tunnel {
            TUNNEL_BODY_LIMIT
          } else {
            self.max_body_bytes
          },
        ),
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
  // A successful CONNECT response switches the same byte stream to an opaque
  // tunnel, so the body shim must also forward writes.
  tunnel : Bool
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

/// Whether another read can proceed without blocking. Returning partial body
/// data as soon as the transport has none ready keeps streaming responses and
/// CONNECT tunnels responsive instead of waiting for a full 8 KiB buffer.
fn ResponseStream::has_more_input(self : ResponseStream) -> Bool {
  self.reader.val.pending_offset < self.reader.val.pending.length() ||
  self.reader.val.stream.read_ready()
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
    | "age"
    | "allow"
    | "date"
    | "expires"
    | "location"
    | "retry-after"
    | "vary"
    | "warning"
    | "authorization"
    | "proxy-authorization"
    | "www-authenticate"
    | "proxy-authenticate"
    | "authentication-info"
    | "proxy-authentication-info"
    | "cookie"
    | "set-cookie"
    | "cache-control"
    | "pragma"
    | "realm"
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
    trailer_bytes = trailer_bytes + reader.last_line_bytes
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
  // Transfer-Encoding overrides Content-Length for parsing, but a message that
  // carries both is ambiguous and a known request-smuggling vector. Existing
  // behavior keeps the transfer coding (some peers send a harmless stale
  // Content-Length), while refusing to pool a connection whose framing was
  // contradictory (RFC 9112 §6.1).
  let has_transfer_encoding = match transfer_encoding {
    TransferEncodingAbsent => false
    _ => true
  }
  // RFC 9112 §6.1: Transfer-Encoding was introduced in HTTP/1.1. A recipient
  // that receives an HTTP/1.0 message containing it MUST treat the framing as
  // faulty, even when a Content-Length is also present, and close the
  // connection after processing the message. In particular, a peer that sent
  // `Connection: keep-alive` must not make this response poolable.
  if self.version == "HTTP/1.0" && has_transfer_encoding {
    self.close_after_body = true
  }
  if has_transfer_encoding && self.headers.contains("Content-Length") {
    self.close_after_body = true
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
      self.reader.val.pending_offset >= self.reader.val.pending.length() &&
      !self.reader.val.stream.has_buffered_input()
    if !reusable && self.close_unless_poolsafe() {
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
  // Validate the framing fields even when the response is not completed
  // early. With a completion callback the caller may never read the body, so
  // a malformed Content-Length or Transfer-Encoding would otherwise be
  // silently hidden and the connection would remain unreleased.
  let transfer_encoding = match response_transfer_encoding(self.headers) {
    Ok(value) => value
    Err(err) => return Err(self.fail(err))
  }
  match transfer_encoding {
    TransferEncodingAbsent => {
      let content_length = match response_content_length(self.headers) {
        Ok(value) => value
        Err(err) => return Err(self.fail(err))
      }
      match content_length {
        Some(0) =>
          match self.prepare() {
            Ok(_) => {
              self.finish()
              Ok(())
            }
            Err(err) => Err(err)
          }
        _ => Ok(())
      }
    }
    _ => Ok(())
  }
}

/// Whether a non-reusable response must close the transport now. A direct
/// `H1Codec` caller owns the stream and may have already supplied the next
/// response in the same read; keeping the stream open lets its shared reader
/// continue from those buffered bytes. The pooling client, by contrast, must
/// close any transport whose framing can no longer be proven clean, and a
/// response that requested `Connection: close` or switched protocols always
/// closes.
fn ResponseStream::close_unless_poolsafe(self : ResponseStream) -> Bool {
  self.close_after_body || self.status == 101 || self.on_complete is Some(_)
}

fn ResponseStream::finish(self : ResponseStream) -> Unit {
  let reusable = !self.close_after_body &&
    self.reader.val.pending_offset >= self.reader.val.pending.length() &&
    !self.reader.val.stream.has_buffered_input()
  if !reusable {
    if self.close_unless_poolsafe() {
      let _ = self.reader.val.stream.close()
    }
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

pub impl Stream for ResponseStream with fn read_ready(
  self : ResponseStream,
) -> Bool {
  if !self.is_open {
    return false
  }
  if self.is_released_to_pool() {
    // The connection may already be in use by another exchange. Readiness of
    // the retired body stream must not inspect or wait on that session.
    return false
  }
  if self.error is Some(_) || self.completed {
    // A read must observe the stored failure or EOF immediately.
    return true
  }
  if !self.prepared {
    // Preparing only parses the already-decoded head; it never waits for the
    // body. A framing failure is also immediately observable by a read.
    match self.prepare() {
      Ok(_) => ()
      Err(_) => return true
    }
  }
  if self.error is Some(_) || self.completed {
    return true
  }
  if self.reader.val.pending_offset < self.reader.val.pending.length() {
    return true
  }
  match self.body_mode {
    BodyNone | BodyUnknown => true
    BodyFixed => self.remaining == 0 || self.reader.val.stream.read_ready()
    BodyChunked | BodyUntilEof => self.reader.val.stream.read_ready()
  }
}

pub impl Stream for ResponseStream with fn wait_readable(
  self : ResponseStream,
  timeout_ms : Int,
) -> Result[Bool, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  if self.is_released_to_pool() {
    return Err(NetError::Closed)
  }
  if self.read_ready() {
    return Ok(true)
  }
  self.reader.val.stream.wait_readable(timeout_ms)
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
        if !self.has_more_input() {
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
        if !self.tunnel && self.total_read > self.max_body_bytes - count {
          return Err(self.fail(NetError::ReadError("response body too large")))
        }
        self.total_read = self.total_read + count
        produced = produced + count
        if !self.has_more_input() {
          break
        }
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
            if produced > 0 && !self.has_more_input() {
              break
            }
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
              if produced > 0 && !self.has_more_input() {
                break
              }
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
            if !self.has_more_input() {
              break
            }
          }
        }
      }
    }
  }
  Ok(produced)
}

pub impl Stream for ResponseStream with fn write(self : ResponseStream, buf : Buffer) -> Result[Int, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  if self.tunnel {
    self.reader.val.stream.write(buf)
  } else {
    let _ = buf
    Err(NetError::WriteError("Response stream is read-only"))
  }
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

/// Encode one request and decode its response, keeping the codec's buffered
/// reader state for a later exchange on the same stream.
pub fn H1Codec::request(
  self : H1Codec,
  request : Request,
  absolute_form? : Bool,
) -> Result[Response, HttpError] {
  match self.encode_request(request, absolute_form=absolute_form.unwrap_or(false)) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  self.decode_response(head=canonical_http_method(request.method) == HEAD)
}

/// Run HTTP/1.1 exchanges on an already established stream. The codec keeps
/// bytes read ahead from one response available to the next one, so callers
/// with a persistent transport can issue sequential requests without losing
/// buffered input.
pub impl HttpClient for H1Codec with fn request(
  self : H1Codec,
  request : Request,
) -> Result[Response, HttpError] {
  match self.encode_request(request) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  self.decode_response(head=canonical_http_method(request.method) == HEAD)
}

/// Encode one HTTP/1.1 request and decode its response on an already
/// established stream. This is the HTTP/1.1 counterpart to `h2_request` for
/// callers that provide their own `Stream` (for example a custom transport or
/// a tunnel) instead of using `UnifiedClient`'s dialer.
pub fn h1_request(
  stream : &Stream,
  request : Request,
  absolute_form? : Bool,
) -> Result[Response, HttpError] {
  h1_request_with_limit(stream, request, DEFAULT_MAX_BODY_BYTES, absolute_form?)
}

/// Like `h1_request`, but cap the response body at `max_body_bytes`.
pub fn h1_request_with_limit(
  stream : &Stream,
  request : Request,
  max_body_bytes : Int,
  absolute_form? : Bool,
) -> Result[Response, HttpError] {
  let codec = H1Codec::new_with_limit(stream, max_body_bytes)
  codec.request(request, absolute_form=absolute_form.unwrap_or(false))
}
