/// HTTP/1.1 codec for encoding requests and decoding responses
pub struct H1Codec {
  stream : &Stream
}

pub fn H1Codec::new(stream : &Stream) -> H1Codec {
  H1Codec::{ stream }
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

/// Encode HTTP request to HTTP/1.1 format
pub fn H1Codec::encode_request(self : H1Codec, req : Request) -> Result[Unit, HttpError] {
  let path = if req.url.path.length() > 0 { req.url.path } else { "/" }
  let target = if req.url.query.length() > 0 {
    path + "?" + req.url.query
  } else {
    path
  }
  let req_line = req.method.to_string() + " " + target + " HTTP/1.1\r\n"

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
  match self.stream.flush() {
    Ok(_) => Ok(())
    Err(err) => Err(NetworkError(err))
  }
}

fn read_stream_line(stream : &Stream) -> Result[String, NetError] {
  let mut line = ""
  while true {
    let buf = @buffer.new(size_hint=1)
    let read_result = stream.read(buf)
    let bytes_read = match read_result {
      Ok(count) => count
      Err(err) => return Err(err)
    }
    if bytes_read == 0 {
      break
    }
    let bytes = buf.to_bytes()
    let ch = bytes[0].to_char()
    line += ch.to_string()
    if ch == '\n' {
      break
    }
  }
  if line.length() >= 2 && line.has_suffix("\r\n") {
    Ok(line.substring(start=0, end=line.length() - 2))
  } else {
    Ok(line)
  }
}

/// Decode HTTP response from HTTP/1.1 format
pub fn H1Codec::decode_response(
  self : H1Codec,
  head? : Bool = false,
) -> Result[Response, HttpError] {
  // Read response line
  let response_line = match read_stream_line(self.stream) {
    Ok(line) => line
    Err(err) => return Err(NetworkError(err))
  }
  let parts = response_line.split(" ").collect()

  if parts.length() < 2 {
    return Err(ProtocolError("Invalid response line"))
  }

  let status = try {
    @string.parse_int(parts[1])
  } catch {
    _ => return Err(ProtocolError("Invalid status code"))
  }
  if status < 100 || status > 599 {
    return Err(ProtocolError("Invalid status code"))
  }

  // Read headers
  let mut headers = Headers::new()

  while true {
    let line = match read_stream_line(self.stream) {
      Ok(line) => line
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
    let value = line.substring(start=colon_idx + 1).trim().to_string()

    headers = headers.add(name, value)
  }

  // Create a response stream that can read the body
  let response_stream : &Stream = ResponseStream::{
    stream: self.stream,
    headers,
    status,
    head,
    body: [],
    offset: 0,
    loaded: false,
    error: None,
  }

  Ok(Response::new(status, headers, response_stream))
}

/// Response stream for reading HTTP response body
struct ResponseStream {
  stream : &Stream
  headers : Headers
  status : Int
  head : Bool
  body : Array[Byte]
  mut offset : Int
  mut loaded : Bool
  mut error : NetError?
}

fn append_exact(
  stream : &Stream,
  length : Int,
  output : Array[Byte],
) -> Result[Unit, NetError] {
  let mut remaining = length
  while remaining > 0 {
    let buf = @buffer.new(size_hint=remaining)
    let count = match stream.read(buf) {
      Ok(count) => count
      Err(err) => return Err(err)
    }
    if count == 0 {
      return Err(NetError::ReadError("unexpected end of response body"))
    }
    let bytes = buf.to_bytes()
    let take = if count < remaining { count } else { remaining }
    let mut i = 0
    while i < take {
      output.push(bytes[i])
      i = i + 1
    }
    remaining = remaining - take
  }
  Ok(())
}

fn read_until_eof(stream : &Stream, output : Array[Byte]) -> Result[Unit, NetError] {
  while true {
    let buf = @buffer.new(size_hint=4096)
    let count = match stream.read(buf) {
      Ok(count) => count
      Err(err) => return Err(err)
    }
    if count == 0 {
      return Ok(())
    }
    let bytes = buf.to_bytes()
    let mut i = 0
    while i < count {
      output.push(bytes[i])
      i = i + 1
    }
  }
  Ok(())
}

fn read_chunked_body(stream : &Stream, output : Array[Byte]) -> Result[Unit, NetError] {
  while true {
    let line = match read_stream_line(stream) {
      Ok(line) => line
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
        let trailer = match read_stream_line(stream) {
          Ok(trailer) => trailer
          Err(err) => return Err(err)
        }
        if trailer.length() == 0 {
          break
        }
      }
      return Ok(())
    }
    match append_exact(stream, size, output) {
      Ok(_) => ()
      Err(err) => return Err(err)
    }
    let terminator : Array[Byte] = []
    match append_exact(stream, 2, terminator) {
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

  // Responses to HEAD and 1xx/204/304 responses never carry a body.
  if self.head || self.status == 204 || self.status == 304 ||
    (self.status >= 100 && self.status < 200) {
    return Ok(())
  }

  let transfer_encoding = self.headers.get("Transfer-Encoding")
  let chunked = match transfer_encoding {
    Some(value) => value.to_lower().contains("chunked")
    None => false
  }

  let result = if chunked {
    read_chunked_body(self.stream, self.body)
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
              self.error = Some(err)
              return Err(err)
            }
            append_exact(self.stream, length, self.body)
          }
          None => {
            let err = NetError::ReadError("invalid Content-Length")
            self.error = Some(err)
            return Err(err)
          }
        }
      }
      None => read_until_eof(self.stream, self.body)
    }
  }

  match result {
    Ok(_) => Ok(())
    Err(err) => {
      self.error = Some(err)
      Err(err)
    }
  }
}

pub impl Stream for ResponseStream with fn read(self : ResponseStream, buf : Buffer) -> Result[Int, NetError] {
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
  let _ = self
  let _ = buf
  Err(NetError::WriteError("Response stream is read-only"))
}

pub impl Stream for ResponseStream with fn flush(self : ResponseStream) -> Result[Unit, NetError] {
  self.stream.flush()
}

pub impl Stream for ResponseStream with fn close(self : ResponseStream) -> Result[Unit, NetError] {
  self.stream.close()
}

pub impl Stream for ResponseStream with fn set_timeout(self : ResponseStream, timeout_ms : Int) -> Result[Unit, NetError] {
  self.stream.set_timeout(timeout_ms)
}

pub impl Stream for ResponseStream with fn peer_addr(self : ResponseStream) -> Result[String, NetError] {
  self.stream.peer_addr()
}

pub impl Stream for ResponseStream with fn local_addr(self : ResponseStream) -> Result[String, NetError] {
  self.stream.local_addr()
}
