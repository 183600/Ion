/// HTTP/1.1 codec for encoding requests and decoding responses
pub struct H1Codec {
  stream : &Stream
  reader : StreamReader
  mut last_is_head : Bool
  max_body_bytes : Int
}

const DEFAULT_MAX_BODY_BYTES : Int = 67108864

pub fn H1Codec::new(stream : &Stream) -> H1Codec {
  H1Codec::new_with_limit(stream, DEFAULT_MAX_BODY_BYTES)
}

pub fn H1Codec::new_with_limit(stream : &Stream, max_body_bytes : Int) -> H1Codec {
  let limit = if max_body_bytes < 0 { 0 } else { max_body_bytes }
  H1Codec::{
    stream,
    reader: StreamReader::new(stream),
    last_is_head: false,
    max_body_bytes: limit,
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
  let buf = @buffer.new(size_hint=4096)
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
      let buf = @buffer.new(size_hint=hint)
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

fn StreamReader::read_to_eof(
  self : StreamReader,
  output : Array[Byte],
  max_bytes : Int,
) -> Result[Unit, NetError] {
  while true {
    if self.pending_offset < self.pending.length() {
      let mut i = self.pending_offset
      while i < self.pending.length() {
        if output.length() >= max_bytes {
          return Err(NetError::ReadError("response body too large"))
        }
        output.push(self.pending[i])
        i = i + 1
      }
      self.pending = b""
      self.pending_offset = 0
      continue
    }
    let buf = @buffer.new(size_hint=4096)
    let count = match self.stream.read(buf) {
      Ok(count) => count
      Err(err) => return Err(err)
    }
    if count < 0 {
      return Err(NetError::ReadError("invalid read count"))
    }
    if count == 0 {
      return Ok(())
    }
    let bytes = buf.to_bytes()
    let mut i = 0
    while i < bytes.length() {
      if output.length() >= max_bytes {
        return Err(NetError::ReadError("response body too large"))
      }
      output.push(bytes[i])
      i = i + 1
    }
  }
  Ok(())
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

fn valid_header_name(name : String) -> Bool {
  if name.length() == 0 {
    return false
  }
  for ch in name {
    if ch <= ' ' || ch == '\u{7f}' || ch == ':' {
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

fn valid_request_target(value : String) -> Bool {
  if value.length() == 0 {
    return false
  }
  for ch in value {
    if ch <= ' ' || ch == '\u{7f}' || ch == '#' {
      return false
    }
  }
  true
}

fn valid_host(value : String) -> Bool {
  if value.length() == 0 {
    return false
  }
  if (value.contains("[") || value.contains("]")) &&
    !(value.has_prefix("[") && value.has_suffix("]")) {
    return false
  }
  for ch in value {
    if ch <= ' ' || ch == '\u{7f}' || ch == '/' || ch == '?' || ch == '#' ||
      ch == '@' {
      return false
    }
  }
  true
}

fn header_has_token(value : String, token : String) -> Bool {
  let token = token.to_lower()
  for part in value.split(",") {
    if part.trim().to_string().to_lower() == token {
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
  let text = values.nth(0).unwrap().trim().to_string()
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
  if values.length() > 1 {
    return Err(InvalidHeader("Transfer-Encoding"))
  }
  let mut final_token = ""
  let mut seen = false
  for part in values.nth(0).unwrap().split(",") {
    let token = part.trim().to_string().to_lower()
    if token.length() == 0 {
      return Err(InvalidHeader("Transfer-Encoding"))
    }
    final_token = token
    seen = true
  }
  if !seen || final_token != "chunked" {
    return Err(InvalidHeader("Transfer-Encoding"))
  }
  Ok(true)
}

fn write_chunked_body(stream : &Stream, body : Bytes) -> Result[Unit, NetError] {
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
  write_all(stream, @utf8.encode("0\r\n\r\n"))
}

/// Encode HTTP request to HTTP/1.1 format
pub fn H1Codec::encode_request(self : H1Codec, req : Request) -> Result[Unit, HttpError] {
  self.last_is_head = req.method == HEAD
  let target = req.url.request_target()
  if !valid_request_target(target) {
    return Err(InvalidUrl("Invalid request target"))
  }
  if !valid_host(req.url.host) {
    return Err(InvalidUrl("Invalid host"))
  }
  let req_line = req.method.to_string() + " " + target + " HTTP/1.1\r\n"

  for header in req.headers.iter() {
    if !valid_header_name(header.name) || !valid_header_value(header.value) {
      return Err(InvalidHeader(header.name))
    }
  }

  let content_length = match request_content_length(req.headers) {
    Ok(value) => value
    Err(err) => return Err(err)
  }
  let chunked = match request_is_chunked(req.headers) {
    Ok(value) => value
    Err(err) => return Err(err)
  }
  if content_length is Some(_) && chunked {
    return Err(InvalidHeader("Transfer-Encoding"))
  }

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

  // Add Content-Length when the caller did not choose a framing mode.
  if req.body is Some(_) && content_length is None && !chunked {
    headers_str += "Content-Length: " + body_length.to_string() + "\r\n"
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
      Some(body) => write_chunked_body(self.stream, body)
      None => write_chunked_body(self.stream, b"")
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
  match self.reader.stream.flush() {
    Ok(_) => Ok(())
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
  let line = @buffer.new(size_hint=128)
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

fn read_response_head(reader : StreamReader) -> Result[ResponseHead, HttpError] {
  let response_line = match read_line(reader) {
    Ok(Some(line)) => line
    Ok(None) => return Err(ProtocolError("Invalid response line"))
    Err(err) => return Err(NetworkError(err))
  }
  let first_space = match response_line.find(" ") {
    Some(index) => index
    None => return Err(ProtocolError("Invalid response line"))
  }
  let version = response_line.substring(start=0, end=first_space)
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
  let status_text = response_line.substring(start=status_start, end=status_end)
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

    let name = line.substring(start=0, end=colon_idx).trim().to_string()
    if !valid_header_name(name) {
      return Err(ProtocolError("Invalid header format"))
    }
    let value = line.substring(start=colon_idx + 1).trim().to_string()
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
  let mut informational_count = 0
  while true {
    let response_head = match read_response_head(self.reader) {
      Ok(head) => head
      Err(err) => return Err(err)
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

    let response_stream : &Stream = ResponseStream::{
      reader: self.reader,
      version: response_head.version,
      headers: response_head.headers,
      status: response_head.status,
      head: is_head,
      max_body_bytes: self.max_body_bytes,
      body: [],
      offset: 0,
      loaded: false,
      error: None,
      is_open: true,
    }

    return Ok(Response::new_with_version(
      response_head.version,
      response_head.status,
      response_head.headers,
      response_stream,
    ))
  }
  Err(ProtocolError("Invalid response"))
}

/// Response stream for reading HTTP response body
struct ResponseStream {
  reader : StreamReader
  version : String
  headers : Headers
  status : Int
  head : Bool
  max_body_bytes : Int
  body : Array[Byte]
  mut offset : Int
  mut loaded : Bool
  mut error : NetError?
  mut is_open : Bool
}

fn read_chunked_body(
  reader : StreamReader,
  output : Array[Byte],
  max_bytes : Int,
) -> Result[Unit, NetError] {
  while true {
    let line = match read_line(reader) {
      Ok(Some(line)) => line
      Ok(None) => return Err(NetError::ReadError("unexpected end of chunked body"))
      Err(err) => return Err(err)
    }
    let size_text = match line.find(";") {
      Some(index) => line.substring(start=0, end=index)
      None => line
    }
    let size_text = size_text.trim().to_string()
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
    if size == 0 {
      // Consume optional trailers until the final empty line.
      while true {
        let trailer = match read_line(reader) {
          Ok(Some(trailer)) => trailer
          Ok(None) => return Err(NetError::ReadError("unexpected end of chunked trailers"))
          Err(err) => return Err(err)
        }
        if trailer.length() == 0 {
          break
        }
      }
      return Ok(())
    }
    if output.length() > max_bytes - size {
      return Err(NetError::ReadError("response body too large"))
    }
    match reader.read_exact(size, output) {
      Ok(_) => ()
      Err(err) => return Err(err)
    }
    let terminator : Array[Byte] = []
    match reader.read_exact(2, terminator) {
      Ok(_) => ()
      Err(err) => return Err(err)
    }
    if terminator.length() != 2 || terminator[0] != b'\r' || terminator[1] != b'\n' {
      return Err(NetError::ReadError("invalid chunk terminator"))
    }
  }
  Ok(())
}

fn response_content_length(headers : Headers) -> Result[Option[String], NetError] {
  let mut result : Option[String] = None
  let mut conflict = false
  for header in headers.iter() {
    if header.name.to_lower() == "content-length" {
      let value = header.value.trim().to_string()
      match result {
        None => result = Some(value)
        Some(existing) => if existing != value {
          conflict = true
        }
      }
    }
  }
  if conflict {
    Err(NetError::ReadError("conflicting Content-Length headers"))
  } else {
    Ok(result)
  }
}

fn ResponseStream::load(self : ResponseStream) -> Result[Unit, NetError] {
  if self.loaded {
    return match self.error {
      Some(err) => Err(err)
      None => Ok(())
    }
  }
  self.loaded = true
  let close_connection = match self.headers.get("Connection") {
    Some(value) => header_has_token(value, "close")
    None => false
  }
  let keep_alive = match self.headers.get("Connection") {
    Some(value) => header_has_token(value, "keep-alive")
    None => false
  }
  let close_by_default = self.version == "HTTP/1.0" && !keep_alive

  // Responses to HEAD and 1xx/204/304 responses never carry a body.
  if self.head || self.status == 204 || self.status == 205 || self.status == 304 ||
    (self.status >= 100 && self.status < 200) {
    if close_connection || close_by_default {
      let _ = self.reader.stream.close()
    }
    return Ok(())
  }

  let transfer_encoding = self.headers.get("Transfer-Encoding")
  let chunked = match transfer_encoding {
    Some(value) => header_has_token(value, "chunked")
    None => false
  }
  let content_length = match response_content_length(self.headers) {
    Ok(value) => value
    Err(err) => {
      let _ = self.reader.stream.close()
      self.error = Some(err)
      return Err(err)
    }
  }

  let mut close_after_load = false
  let result = if chunked {
    read_chunked_body(self.reader, self.body, self.max_body_bytes)
  } else {
    match content_length {
      Some(value) => {
        let length_text = value.trim().to_string()
        if !is_decimal_digits(length_text) {
          let err = NetError::ReadError("invalid Content-Length")
          let _ = self.reader.stream.close()
          self.error = Some(err)
          return Err(err)
        }
        let parsed = try {
          Some(@string.parse_int(length_text[:]))
        } catch {
          _ => None
        }
        match parsed {
          Some(length) => {
            if length > self.max_body_bytes {
              let err = NetError::ReadError("response body too large")
              let _ = self.reader.stream.close()
              self.error = Some(err)
              return Err(err)
            }
            self.reader.read_exact(length, self.body)
          }
          None => {
            let err = NetError::ReadError("invalid Content-Length")
            let _ = self.reader.stream.close()
            self.error = Some(err)
            return Err(err)
          }
        }
      }
      None => {
        close_after_load = true
        self.reader.read_to_eof(self.body, self.max_body_bytes)
      }
    }
  }

  match result {
    Ok(_) => {
      if close_after_load || close_connection || close_by_default {
        let _ = self.reader.stream.close()
      }
      Ok(())
    }
    Err(err) => {
      let _ = self.reader.stream.close()
      self.error = Some(err)
      Err(err)
    }
  }
}

pub impl Stream for ResponseStream with fn read(self : ResponseStream, buf : Buffer) -> Result[Int, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  match self.load() {
    Ok(_) => ()
    Err(err) => return Err(err)
  }

  let remaining = self.body.length() - self.offset
  if remaining <= 0 {
    return Ok(0)
  }
  let count = if remaining > 8192 { 8192 } else { remaining }
  let mut i = 0
  while i < count {
    buf.write_byte(self.body[self.offset + i])
    i = i + 1
  }
  self.offset = self.offset + count
  Ok(count)
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
  self.reader.stream.flush()
}

pub impl Stream for ResponseStream with fn close(self : ResponseStream) -> Result[Unit, NetError] {
  if !self.is_open {
    return Ok(())
  }
  self.is_open = false
  self.reader.stream.close()
}

pub impl Stream for ResponseStream with fn set_timeout(self : ResponseStream, timeout_ms : Int) -> Result[Unit, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  self.reader.stream.set_timeout(timeout_ms)
}

pub impl Stream for ResponseStream with fn peer_addr(self : ResponseStream) -> Result[String, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  self.reader.stream.peer_addr()
}

pub impl Stream for ResponseStream with fn local_addr(self : ResponseStream) -> Result[String, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  self.reader.stream.local_addr()
}
