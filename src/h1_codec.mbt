/// HTTP/1.1 codec for encoding requests and decoding responses
pub struct H1Codec {
  stream : &Stream
  reader : StreamReader
  mut last_is_head : Bool
}

pub fn H1Codec::new(stream : &Stream) -> H1Codec {
  H1Codec::{ stream, reader: StreamReader::new(stream), last_is_head: false }
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
      let buf = @buffer.new(size_hint=remaining)
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
) -> Result[Unit, NetError] {
  while true {
    if self.pending_offset < self.pending.length() {
      let mut i = self.pending_offset
      while i < self.pending.length() {
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

fn host_header_value(url : Url) -> String {
  let host = if url.host.contains(":") {
    "[" + url.host + "]"
  } else {
    url.host
  }
  if (url.scheme == "https" && url.port != 443) ||
    (url.scheme == "http" && url.port != 80) {
    host + ":" + url.port.to_string()
  } else {
    host
  }
}

fn valid_header_name(name : String) -> Bool {
  if name.length() == 0 {
    return false
  }
  for ch in name {
    if ch == '\r' || ch == '\n' || ch == '\u{0}' || ch == ':' ||
      ch == ' ' || ch == '\t' {
      return false
    }
  }
  true
}

fn valid_header_value(value : String) -> Bool {
  for ch in value {
    if ch == '\r' || ch == '\n' || ch == '\u{0}' {
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

/// Encode HTTP request to HTTP/1.1 format
pub fn H1Codec::encode_request(self : H1Codec, req : Request) -> Result[Unit, HttpError] {
  self.last_is_head = req.method == HEAD
  let path = if req.url.path.length() > 0 { req.url.path } else { "/" }
  let target = if req.url.query.length() > 0 {
    path + "?" + req.url.query
  } else {
    path
  }
  let req_line = req.method.to_string() + " " + target + " HTTP/1.1\r\n"

  for header in req.headers.iter() {
    if !valid_header_name(header.name) || !valid_header_value(header.value) {
      return Err(InvalidHeader(header.name))
    }
  }

  // Build headers
  let mut headers_str = ""

  // Add Host header if not present
  let has_host = req.headers.get("Host") is Some(_)
  if !has_host {
    headers_str += "Host: " + host_header_value(req.url) + "\r\n"
  }

  // Add Content-Length if body is present and the caller did not set it.
  match req.body {
    Some(body) => {
      let has_content_length = req.headers.get("Content-Length") is Some(_)
      if !has_content_length {
        headers_str += "Content-Length: " + body.length().to_string() + "\r\n"
      }
    }
    None => ()
  }

  // Add User-Agent if not present
  let has_user_agent = req.headers.get("User-Agent") is Some(_)
  if !has_user_agent {
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

  // Write body if present
  match req.body {
    Some(body) => {
      match write_all(self.stream, body) {
        Ok(_) => ()
        Err(err) => return Err(NetworkError(err))
      }
    }
    None => ()
  }

  // Flush the stream
  match self.reader.stream.flush() {
    Ok(_) => Ok(())
    Err(err) => Err(NetworkError(err))
  }
}

fn read_line(reader : StreamReader) -> Result[String?, NetError] {
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

/// Decode HTTP response from HTTP/1.1 format
pub fn H1Codec::decode_response(
  self : H1Codec,
  head? : Bool,
) -> Result[Response, HttpError] {
  let is_head = match head {
    Some(value) => value
    None => self.last_is_head
  }
  // Read response line
  let response_line = match read_line(self.reader) {
    Ok(Some(line)) => line
    Ok(None) => return Err(ProtocolError("Invalid response line"))
    Err(err) => return Err(NetworkError(err))
  }
  let first_space = match response_line.find(" ") {
    Some(index) => index
    None => return Err(ProtocolError("Invalid response line"))
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
  if status_start == status_end {
    return Err(ProtocolError("Invalid status code"))
  }
  let status = try {
    @string.parse_int(response_line.substring(start=status_start, end=status_end))
  } catch {
    _ => return Err(ProtocolError("Invalid status code"))
  }
  if status < 100 || status > 599 {
    return Err(ProtocolError("Invalid status code"))
  }

  // Read headers
  let mut headers = Headers::new()

  while true {
    let line = match read_line(self.reader) {
      Ok(Some(line)) => line
      Ok(None) => return Err(ProtocolError("Unexpected end of response headers"))
      Err(err) => return Err(NetworkError(err))
    }
    if line.length() == 0 {
      break
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

  // Create a response stream that can read the body
  let response_stream : &Stream = ResponseStream::{
    reader: self.reader,
    headers,
    status,
    head: is_head,
    body: [],
    offset: 0,
    loaded: false,
    error: None,
    is_open: true,
  }

  Ok(Response::new(status, headers, response_stream))
}

/// Response stream for reading HTTP response body
struct ResponseStream {
  reader : StreamReader
  headers : Headers
  status : Int
  head : Bool
  body : Array[Byte]
  mut offset : Int
  mut loaded : Bool
  mut error : NetError?
  mut is_open : Bool
}

fn read_chunked_body(reader : StreamReader, output : Array[Byte]) -> Result[Unit, NetError] {
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
    if size_text.length() == 0 {
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

  // Responses to HEAD and 1xx/204/304 responses never carry a body.
  if self.head || self.status == 204 || self.status == 205 || self.status == 304 ||
    (self.status >= 100 && self.status < 200) {
    if close_connection {
      let _ = self.reader.stream.close()
    }
    return Ok(())
  }

  let transfer_encoding = self.headers.get("Transfer-Encoding")
  let chunked = match transfer_encoding {
    Some(value) => header_has_token(value, "chunked")
    None => false
  }

  let mut close_after_load = false
  let result = if chunked {
    read_chunked_body(self.reader, self.body)
  } else {
    match self.headers.get("Content-Length") {
      Some(value) => {
        let parsed = try {
          Some(@string.parse_int(value.trim()[:]))
        } catch {
          _ => None
        }
        match parsed {
          Some(length) => {
            if length < 0 {
              let err = NetError::ReadError("invalid Content-Length")
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
        self.reader.read_to_eof(self.body)
      }
    }
  }

  match result {
    Ok(_) => {
      if close_after_load || close_connection {
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
