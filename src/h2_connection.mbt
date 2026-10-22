/// A single HTTP/2 client exchange. HTTP/2 is negotiated by ALPN; the
/// connection handles one request stream and returns a buffered response.

const H2_MAX_HEADER_BLOCK_BYTES : Int = 1048576

struct H2FlowState {
  mut connection_send_window : Int
  mut stream_send_window : Int
  mut peer_initial_window : Int
}

fn H2FlowState::new() -> H2FlowState {
  H2FlowState::{
    connection_send_window: H2_DEFAULT_WINDOW_SIZE,
    stream_send_window: H2_DEFAULT_WINDOW_SIZE,
    peer_initial_window: H2_DEFAULT_WINDOW_SIZE,
  }
}

fn h2_window_update_payload(increment : Int) -> Bytes {
  let payload = Buffer(size_hint=4)
  payload.write_byte(((increment >> 24) & 0x7f).to_byte())
  payload.write_byte(((increment >> 16) & 0xff).to_byte())
  payload.write_byte(((increment >> 8) & 0xff).to_byte())
  payload.write_byte((increment & 0xff).to_byte())
  payload.to_bytes()
}

fn h2_send_window_update(
  stream : &Stream,
  stream_id : Int,
  increment : Int,
) -> Result[Unit, HttpError] {
  h2_write_frame(
    stream,
    H2_FRAME_WINDOW_UPDATE,
    0,
    stream_id,
    h2_window_update_payload(increment),
  )
}

struct H2ResponseState {
  stream_id : Int
  decoder : HpackDecoder
  max_body_bytes : Int
  head : Bool
  mut status : Int
  mut status_seen : Bool
  mut headers : Headers
  mut content_length : Int?
  mut body_forbidden : Bool
  body : Buffer
  mut trailers : Headers
  mut ended : Bool
  mut header_block : Buffer
  mut in_header_block : Bool
  mut header_block_end_stream : Bool
}

fn H2ResponseState::new(
  stream_id : Int,
  decoder : HpackDecoder,
  max_body_bytes : Int,
  head : Bool,
) -> H2ResponseState {
  H2ResponseState::{
    stream_id,
    decoder,
    max_body_bytes: if max_body_bytes < 0 { 0 } else { max_body_bytes },
    head,
    status: 0,
    status_seen: false,
    headers: Headers::new(),
    content_length: None,
    body_forbidden: false,
    body: Buffer(size_hint=4096),
    trailers: Headers::new(),
    ended: false,
    header_block: Buffer(size_hint=256),
    in_header_block: false,
    header_block_end_stream: false,
  }
}

fn h2_parse_status(value : String) -> Result[Int, HttpError] {
  if value.length() != 3 {
    return Err(ProtocolError("Invalid HTTP/2 :status"))
  }
  let mut status = 0
  for ch in value {
    if ch < '0' || ch > '9' {
      return Err(ProtocolError("Invalid HTTP/2 :status"))
    }
    status = status * 10 + (ch.to_int() - '0'.to_int())
  }
  if status < 100 || status > 599 {
    return Err(ProtocolError("Invalid HTTP/2 :status"))
  }
  Ok(status)
}

fn h2_valid_field_name(name : String) -> Bool {
  if name.length() == 0 {
    return false
  }
  for ch in name {
    if ch >= 'A' && ch <= 'Z' {
      return false
    }
    if !is_header_token_char(ch) {
      return false
    }
  }
  true
}

fn h2_forbidden_header(name : String) -> Bool {
  match name.to_lower() {
    "connection" | "proxy-connection" | "keep-alive" | "transfer-encoding" |
    "upgrade" | "host" => true
    _ => false
  }
}

fn H2ResponseState::apply_header_block(
  self : H2ResponseState,
  block : Bytes,
  end_stream : Bool,
) -> Result[Unit, HttpError] {
  let fields = match self.decoder.decode(block) {
    Ok(fields) => fields
    Err(err) => return Err(err)
  }
  if fields.length() == 0 {
    return Err(ProtocolError("Empty HTTP/2 header block"))
  }
  let trailers_mode = self.status_seen
  let mut status_text : String? = None
  let mut regular = Headers::new()
  let mut pseudo_allowed = true
  for field in fields {
    let (name, value) = field
    if name.length() > 0 && name.get_char(0) == Some(':') {
      if !pseudo_allowed {
        return Err(ProtocolError("HTTP/2 pseudo-header after regular header"))
      }
      if name != ":status" || status_text is Some(_) {
        return Err(ProtocolError("Invalid HTTP/2 response pseudo-header"))
      }
      status_text = Some(value)
    } else {
      pseudo_allowed = false
      if !h2_valid_field_name(name) || !valid_header_value(value) {
        return Err(ProtocolError("Invalid HTTP/2 response header"))
      }
      if h2_forbidden_header(name) ||
        (name == "te" && value.trim().to_lower() != "trailers") {
        return Err(ProtocolError("Connection-specific HTTP/2 response header"))
      }
      if trailers_mode && is_forbidden_trailer_field(name) {
        return Err(ProtocolError("Invalid HTTP/2 trailer field"))
      }
      regular = regular.add(name, value)
    }
  }
  if trailers_mode {
    if status_text is Some(_) {
      return Err(ProtocolError("HTTP/2 trailers contain :status"))
    }
    if !end_stream {
      return Err(ProtocolError("HTTP/2 trailers did not end the stream"))
    }
    if !self.body_forbidden && self.content_length is Some(length) &&
      self.body.length() != length {
      return Err(ProtocolError("HTTP/2 response body does not match Content-Length"))
    }
    self.trailers = regular
    self.ended = true
    return Ok(())
  }
  let status_text = match status_text {
    Some(value) => value
    None => return Err(ProtocolError("HTTP/2 response is missing :status"))
  }
  let status = match h2_parse_status(status_text) {
    Ok(value) => value
    Err(err) => return Err(err)
  }
  if status < 200 {
    if end_stream {
      return Err(ProtocolError("Informational HTTP/2 response ended the stream"))
    }
    return Ok(())
  }
  self.status = status
  self.status_seen = true
  self.headers = regular
  // Responses to HEAD and 204/205/304 carry no payload body. A 101 response
  // is not used by HTTP/2, but it also terminates the HTTP message.
  self.body_forbidden = self.head || status == 101 || status == 204 ||
    status == 205 || status == 304
  if !self.body_forbidden {
    let declared = match response_content_length(regular) {
      Ok(value) => value
      Err(_) => return Err(ProtocolError("Invalid HTTP/2 Content-Length"))
    }
    match declared {
      Some(length) => {
        if length > self.max_body_bytes {
          return Err(ProtocolError("HTTP/2 response body too large"))
        }
        self.content_length = Some(length)
      }
      None => self.content_length = None
    }
  } else {
    self.content_length = None
  }
  if end_stream {
    if self.content_length is Some(length) && length != 0 {
      return Err(ProtocolError("HTTP/2 response body does not match Content-Length"))
    }
    self.ended = true
  }
  Ok(())
}

fn h2_apply_settings(
  payload : Bytes,
  flow : H2FlowState,
) -> Result[Unit, HttpError] {
  let mut offset = 0
  while offset < payload.length() {
    let identifier = (payload[offset].to_int() << 8) | payload[offset + 1].to_int()
    let value_high = payload[offset + 2].to_int()
    let value = (value_high << 24) |
      (payload[offset + 3].to_int() << 16) |
      (payload[offset + 4].to_int() << 8) |
      payload[offset + 5].to_int()
    if identifier == H2_SETTINGS_INITIAL_WINDOW_SIZE {
      // SETTINGS values are unsigned 32-bit. A high bit set exceeds the
      // largest legal flow-control window (2^31-1).
      if (value_high & 0x80) != 0 || value > H2_MAX_WINDOW_SIZE {
        return Err(ProtocolError("Invalid HTTP/2 initial window size"))
      }
      flow.stream_send_window = flow.stream_send_window + (value - flow.peer_initial_window)
      flow.peer_initial_window = value
    }
    offset = offset + 6
  }
  Ok(())
}

fn H2ResponseState::handle_frame(
  self : H2ResponseState,
  frame : H2Frame,
  flow : H2FlowState,
  stream : &Stream,
) -> Result[Unit, HttpError] {
  if self.in_header_block && frame.frame_type != H2_FRAME_CONTINUATION {
    return Err(ProtocolError("Interleaved HTTP/2 header block"))
  }
  match frame.frame_type {
    H2_FRAME_DATA => {
      let payload = match h2_data_payload(frame) {
        Ok(value) => value
        Err(err) => return Err(err)
      }
      if frame.stream_id == self.stream_id {
        if !self.status_seen {
          return Err(ProtocolError("HTTP/2 DATA before response headers"))
        }
        if self.body_forbidden {
          if payload.length() > 0 {
            return Err(ProtocolError("HTTP/2 response must not include a body"))
          }
        } else {
          if payload.length() > self.max_body_bytes - self.body.length() {
            return Err(ProtocolError("HTTP/2 response body too large"))
          }
          if self.content_length is Some(length) &&
            payload.length() > length - self.body.length() {
            return Err(ProtocolError("HTTP/2 response body does not match Content-Length"))
          }
          self.body.write_bytes(payload)
        }
        if (frame.flags & H2_FLAG_END_STREAM) != 0 {
          if !self.body_forbidden && self.content_length is Some(length) &&
            self.body.length() != length {
            return Err(ProtocolError("HTTP/2 response body does not match Content-Length"))
          }
          self.ended = true
        }
      }
      // The connection-level receive window is replenished as bytes arrive.
      if frame.stream_id == self.stream_id && frame.payload.length() > 0 {
        match h2_send_window_update(stream, 0, frame.payload.length()) {
          Ok(_) => ()
          Err(err) => return Err(err)
        }
      }
      Ok(())
    }
    H2_FRAME_HEADERS => {
      if frame.stream_id != self.stream_id {
        return Ok(())
      }
      let block = match h2_header_block_payload(frame) {
        Ok(value) => value
        Err(err) => return Err(err)
      }
      let end_stream = (frame.flags & H2_FLAG_END_STREAM) != 0
      if (frame.flags & H2_FLAG_END_HEADERS) != 0 {
        self.apply_header_block(block, end_stream)
      } else {
        if block.length() > H2_MAX_HEADER_BLOCK_BYTES {
          return Err(ProtocolError("HTTP/2 header block too large"))
        }
        self.header_block.write_bytes(block)
        self.in_header_block = true
        self.header_block_end_stream = end_stream
        Ok(())
      }
    }
    H2_FRAME_CONTINUATION => {
      if !self.in_header_block || frame.stream_id != self.stream_id {
        return Err(ProtocolError("Unexpected HTTP/2 CONTINUATION"))
      }
      if frame.payload.length() > H2_MAX_HEADER_BLOCK_BYTES - self.header_block.length() {
        return Err(ProtocolError("HTTP/2 header block too large"))
      }
      self.header_block.write_bytes(frame.payload)
      if (frame.flags & H2_FLAG_END_HEADERS) != 0 {
        self.in_header_block = false
        let block = self.header_block.to_bytes()
        self.header_block = Buffer(size_hint=256)
        self.apply_header_block(block, self.header_block_end_stream)
      } else {
        Ok(())
      }
    }
    H2_FRAME_SETTINGS => {
      if (frame.flags & H2_FLAG_ACK) == 0 {
        match h2_apply_settings(frame.payload, flow) {
          Ok(_) => ()
          Err(err) => return Err(err)
        }
        match h2_write_frame(stream, H2_FRAME_SETTINGS, H2_FLAG_ACK, 0, b"") {
          Ok(_) => Ok(())
          Err(err) => Err(err)
        }
      } else {
        Ok(())
      }
    }
    H2_FRAME_WINDOW_UPDATE => {
      let increment = match h2_parse_window_update(frame.payload) {
        Ok(value) => value
        Err(err) => return Err(err)
      }
      if frame.stream_id == 0 {
        if flow.connection_send_window > H2_MAX_WINDOW_SIZE - increment {
          return Err(ProtocolError("HTTP/2 connection window overflow"))
        }
        flow.connection_send_window = flow.connection_send_window + increment
      } else if frame.stream_id == self.stream_id {
        if flow.stream_send_window > H2_MAX_WINDOW_SIZE - increment {
          return Err(ProtocolError("HTTP/2 stream window overflow"))
        }
        flow.stream_send_window = flow.stream_send_window + increment
      }
      Ok(())
    }
    H2_FRAME_PING => {
      if (frame.flags & H2_FLAG_ACK) == 0 {
        match h2_write_frame(stream, H2_FRAME_PING, H2_FLAG_ACK, 0, frame.payload) {
          Ok(_) => Ok(())
          Err(err) => Err(err)
        }
      } else {
        Ok(())
      }
    }
    H2_FRAME_RST_STREAM => {
      if frame.stream_id == self.stream_id {
        Err(ProtocolError("HTTP/2 stream reset by server"))
      } else {
        Ok(())
      }
    }
    H2_FRAME_GOAWAY => Err(ProtocolError("HTTP/2 connection closed by GOAWAY"))
    H2_FRAME_PUSH_PROMISE => {
      Err(ProtocolError("HTTP/2 server push is disabled"))
    }
    H2_FRAME_PRIORITY => Ok(())
    _ => Ok(())
  }
}

fn h2_request_headers(request : Request) -> Result[Array[(String, String)], HttpError] {
  if !valid_url_component_chars(request.url.path) ||
    !valid_url_component_chars(request.url.query) {
    return Err(InvalidUrl("Invalid request target"))
  }
  if !valid_host(request.url.authority()) {
    return Err(InvalidUrl("Invalid host"))
  }
  let body_length = match request.body {
    Some(body) => body.length()
    None => 0
  }
  let content_lengths = request.headers.get_all("Content-Length")
  if content_lengths.length() > 1 {
    return Err(InvalidHeader("Content-Length"))
  }
  if content_lengths.length() == 1 {
    let declared = content_lengths.nth(0).unwrap()
    if declared != body_length.to_string() {
      return Err(InvalidHeader("Content-Length"))
    }
  }
  let headers : Array[(String, String)] = [
    (":method", request.method.to_string()),
    (":scheme", request.url.scheme.to_lower()),
    (":authority", request.url.authority()),
    (":path", request.url.request_target()),
  ]
  if (request.body is Some(_) || method_defines_body(request.method)) &&
    content_lengths.length() == 0 {
    headers.push(("content-length", body_length.to_string()))
  }
  if !request.headers.contains("User-Agent") {
    headers.push(("user-agent", "Feather/0.1.0"))
  }
  for header in request.headers.iter() {
    let name = header.name.to_lower()
    if h2_forbidden_header(name) {
      continue
    }
    if name == "te" && header.value.trim().to_lower() != "trailers" {
      continue
    }
    if !h2_valid_field_name(name) || !valid_header_value(header.value) {
      return Err(InvalidHeader(header.name))
    }
    headers.push((name, header.value))
  }
  Ok(headers)
}

fn h2_body_stream(data : Bytes) -> H2BodyStream {
  H2BodyStream::{ data, offset: 0 }
}

struct H2BodyStream {
  data : Bytes
  mut offset : Int
}

pub impl Stream for H2BodyStream with fn read(self : H2BodyStream, buf : Buffer) -> Result[Int, NetError] {
  let remaining = self.data.length() - self.offset
  if remaining <= 0 {
    return Ok(0)
  }
  let take = if remaining < 4096 { remaining } else { 4096 }
  buf.write_bytes(self.data.exact_view(start=self.offset, end=self.offset + take))
  self.offset = self.offset + take
  Ok(take)
}

pub impl Stream for H2BodyStream with fn write(self : H2BodyStream, buf : Buffer) -> Result[Int, NetError] {
  let _ = self
  let _ = buf
  Err(NetError::WriteError("HTTP/2 response body is read-only"))
}

pub impl Stream for H2BodyStream with fn flush(self : H2BodyStream) -> Result[Unit, NetError] {
  let _ = self
  Ok(())
}

pub impl Stream for H2BodyStream with fn close(self : H2BodyStream) -> Result[Unit, NetError] {
  let _ = self
  Ok(())
}

pub impl Stream for H2BodyStream with fn set_timeout(self : H2BodyStream, timeout_ms : Int) -> Result[Unit, NetError] {
  let _ = self
  let _ = timeout_ms
  Ok(())
}

pub impl Stream for H2BodyStream with fn peer_addr(self : H2BodyStream) -> Result[String, NetError] {
  let _ = self
  Err(NetError::InvalidAddress("HTTP/2 response body has no peer"))
}

pub impl Stream for H2BodyStream with fn local_addr(self : H2BodyStream) -> Result[String, NetError] {
  let _ = self
  Err(NetError::InvalidAddress("HTTP/2 response body has no address"))
}

fn h2_make_response(state : H2ResponseState) -> Response {
  let response = Response::new_with_version(
    "HTTP/2",
    state.status,
    state.headers,
    h2_body_stream(state.body.to_bytes()),
  )
  let trailers = @ref.Ref(state.trailers)
  response.with_trailers(trailers).with_max_body_bytes(state.max_body_bytes)
}

fn h2_write_header_block(
  stream : &Stream,
  stream_id : Int,
  block : Bytes,
  end_stream : Bool,
) -> Result[Unit, HttpError] {
  let total = block.length()
  let mut offset = 0
  let mut first = true
  while true {
    let remaining = total - offset
    let take = if remaining < H2_MAX_FRAME_SIZE { remaining } else { H2_MAX_FRAME_SIZE }
    let payload = block.exact_view(start=offset, end=offset + take).to_owned()
    let mut flags = 0
    if first && end_stream {
      flags = flags | H2_FLAG_END_STREAM
    }
    if offset + take == total {
      flags = flags | H2_FLAG_END_HEADERS
    }
    let frame_type = if first { H2_FRAME_HEADERS } else { H2_FRAME_CONTINUATION }
    match h2_write_frame(stream, frame_type, flags, stream_id, payload) {
      Ok(_) => ()
      Err(err) => return Err(err)
    }
    offset = offset + take
    first = false
    if offset >= total {
      return Ok(())
    }
  }
  Ok(())
}

fn h2_request_with_limit(
  stream : &Stream,
  request : Request,
  max_body_bytes : Int,
) -> Result[Response, HttpError] {
  match write_all(stream, h2_preface_bytes) {
    Ok(_) => ()
    Err(err) => return Err(http_error_from_net(err))
  }
  let settings = h2_settings_payload([
    (H2_SETTINGS_ENABLE_PUSH, 0),
    (H2_SETTINGS_INITIAL_WINDOW_SIZE, H2_MAX_WINDOW_SIZE),
    (H2_SETTINGS_MAX_HEADER_LIST_SIZE, 1048576),
  ])
  match h2_write_frame(stream, H2_FRAME_SETTINGS, 0, 0, settings) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  match h2_send_window_update(stream, 0, H2_MAX_WINDOW_SIZE - H2_DEFAULT_WINDOW_SIZE) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }

  let headers = match h2_request_headers(request) {
    Ok(headers) => headers
    Err(err) => return Err(err)
  }
  let block = hpack_encode(headers)
  let body = match request.body {
    Some(body) => body
    None => b""
  }
  let end_stream = body.length() == 0
  match h2_write_header_block(stream, 1, block, end_stream) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }

  let reader = StreamReader::new(stream)
  let decoder = HpackDecoder::new()
  let state = H2ResponseState::new(1, decoder, max_body_bytes, request.method == HEAD)
  let flow = H2FlowState::new()
  let mut sent = 0
  while sent < body.length() && !state.ended {
    let available = if flow.connection_send_window < flow.stream_send_window {
      flow.connection_send_window
    } else {
      flow.stream_send_window
    }
    if available <= 0 {
      let frame = match h2_read_frame(reader) {
        Ok(frame) => frame
        Err(err) => return Err(err)
      }
      match state.handle_frame(frame, flow, stream) {
        Ok(_) => ()
        Err(err) => return Err(err)
      }
      continue
    }
    let remaining = body.length() - sent
    let wanted = if available < remaining { available } else { remaining }
    let take = if wanted < H2_MAX_FRAME_SIZE { wanted } else { H2_MAX_FRAME_SIZE }
    let last = sent + take == body.length()
    let flags = if last { H2_FLAG_END_STREAM } else { 0 }
    match h2_write_frame(
      stream,
      H2_FRAME_DATA,
      flags,
      1,
      body.exact_view(start=sent, end=sent + take).to_owned(),
    ) {
      Ok(_) => ()
      Err(err) => return Err(err)
    }
    sent = sent + take
    flow.connection_send_window = flow.connection_send_window - take
    flow.stream_send_window = flow.stream_send_window - take
  }

  while !state.ended {
    let frame = match h2_read_frame(reader) {
      Ok(frame) => frame
      Err(err) => return Err(err)
    }
    match state.handle_frame(frame, flow, stream) {
      Ok(_) => ()
      Err(err) => return Err(err)
    }
  }
  match stream.flush() {
    Ok(_) => ()
    Err(err) => return Err(http_error_from_net(err))
  }
  Ok(h2_make_response(state))
}

/// Perform one HTTP/2 request over an ALPN-negotiated stream. The connection
/// must already have negotiated the `h2` protocol; the caller owns closing it.
pub fn h2_request(stream : &Stream, request : Request) -> Result[Response, HttpError] {
  h2_request_with_limit(stream, request, DEFAULT_MAX_BODY_BYTES)
}
