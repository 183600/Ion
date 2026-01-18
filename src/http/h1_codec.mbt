/// HTTP/1.1 codec for encoding requests and decoding responses
pub struct H1Codec {
  stream : Stream
}

pub fn H1Codec::new(stream : Stream) -> H1Codec {
  H1Codec::{ stream }
}

/// Encode HTTP request to HTTP/1.1 format
pub fn H1Codec::encode_request(self : H1Codec, req : Request) -> Result[Unit, HttpError] {
  // Build request line: METHOD PATH HTTP/1.1
  let req_line = req.method.to_string() + " " + req.url.path + " HTTP/1.1\r\n"
  
  // Build headers
  let mut headers_str = ""
  
  // Add Host header if not present
  let has_host = req.headers.iter().any(fn(h) { h.name == "Host" })
  if not(has_host) {
    let host_header = "Host: " + req.url.host + "\r\n"
    headers_str += host_header
  }
  
  // Add Content-Length if body is present
  if req.body.is_some() {
    let body_len = req.body.unwrap().length()
    headers_str += "Content-Length: " + body_len.to_string() + "\r\n"
  }
  
  // Add User-Agent if not present
  let has_user_agent = req.headers.iter().any(fn(h) { h.name == "User-Agent" })
  if not(has_user_agent) {
    headers_str += "User-Agent: Feather/0.1.0\r\n"
  }
  
  // Add other headers
  for header in req.headers.iter() {
    headers_str += header.name + ": " + header.value + "\r\n"
  }
  
  // End headers
  headers_str += "\r\n"
  
  // Write request line and headers
  let header_data = (req_line + headers_str).to_bytes()
  let written = self.stream.write(Buffer::from_bytes(header_data))
  
  if written.is_err() {
    return Err(NetworkError(written.unwrap_err()))
  }
  
  // Write body if present
  if req.body.is_some() {
    let body = req.body.unwrap()
    let body_buf = Buffer::from_bytes(body)
    let body_written = self.stream.write(body_buf)
    
    if body_written.is_err() {
      return Err(NetworkError(body_written.unwrap_err()))
    }
  }
  
  // Flush the stream
  let flush_result = self.stream.flush()
  if flush_result.is_err() {
    return Err(NetworkError(flush_result.unwrap_err()))
  }
  
  Ok(())
}

/// Decode HTTP response from HTTP/1.1 format
pub fn H1Codec::decode_response(self : H1Codec) -> Result[Response, HttpError] {
  // Read response line
  let response_line = self.read_line()?
  let parts = response_line.split(" ")
  
  if parts.length() < 2 {
    return Err(ProtocolError("Invalid response line"))
  }
  
  let status_str = parts[1]
  let status = status_str.parse_int()
  
  if status.is_err() {
    return Err(ProtocolError("Invalid status code"))
  }
  
  let status_code = status.unwrap()
  
  // Read headers
  let mut headers = Headers::new()
  
  loop {
    let line = self.read_line()?
    if line.length() == 0 {
      break
    }
    
    let colon_idx = line.index_of(":")
    if colon_idx.is_none() {
      return Err(ProtocolError("Invalid header format"))
    }
    
    let name = line.substring(0, colon_idx.unwrap()).trim()
    let value = line.substring(colon_idx.unwrap() + 1, line.length()).trim()
    
    headers = headers.add(name, value)
  }
  
  // Create a response stream that can read the body
  let response_stream = ResponseStream::{ stream: self.stream, headers }
  
  Ok(Response::new(status_code, headers, response_stream))
}

/// Read a line from the stream (until \r\n)
fn read_line(self : H1Codec) -> Result[String, HttpError] {
  let mut line = """
  let mut prev_char = '\0'
  
  loop {
    let buf = Buffer::make(1)
    let read_result = self.stream.read(buf)
    
    if read_result.is_err() {
      return Err(NetworkError(read_result.unwrap_err()))
    }
    
    let bytes_read = read_result.unwrap()
    if bytes_read == 0 {
      break
    }
    
    let char = buf.to_bytes()[0].to_char()
    line += char.to_string()
    
    if char == '\n' && prev_char == '\r' {
      break
    }
    
    prev_char = char
  }
  
  // Remove \r\n from end
  if line.length() >= 2 && line.ends_with("\r\n") {
    Ok(line.substring(0, line.length() - 2))
  } else {
    Ok(line)
  }
}

/// Response stream for reading HTTP response body
struct ResponseStream {
  stream : Stream
  headers : Headers
}

pub impl Stream for ResponseStream with fn read(self : ResponseStream, buf : Buffer) -> Result[Int, NetError] {
  // Check if response uses chunked encoding
  let transfer_encoding = self.headers.get("Transfer-Encoding")
  let is_chunked = transfer_encoding.is_some() && transfer_encoding.unwrap() == "chunked"
  
  if is_chunked {
    // In real implementation, handle chunked encoding
    // For now, fall through to regular read
  }
  
  // Check Content-Length
  let content_length = self.headers.get("Content-Length")
  
  if content_length.is_some() {
    // In real implementation, track bytes read vs content-length
    // For now, just read what's available
  }
  
  self.stream.read(buf)
}

pub impl Stream for ResponseStream with fn write(self : ResponseStream, buf : Buffer) -> Result[Int, NetError] {
  Err(WriteError("Response stream is read-only"))
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
