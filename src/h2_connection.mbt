/// A single HTTP/2 client exchange. HTTP/2 is negotiated by ALPN; the
/// connection handles one request stream and returns a buffered response.

const H2_MAX_HEADER_BLOCK_BYTES : Int = 1048576
const H2_SETTINGS_MAX_CONCURRENT_STREAMS : Int = 0x3

struct H2FlowState {
  mut connection_send_window : Int
  mut stream_send_window : Int
  mut peer_initial_window : Int
  mut peer_max_frame_size : Int
  mut peer_max_header_list_size : Int
  mut peer_max_concurrent_streams : Int
}

fn H2FlowState::new() -> H2FlowState {
  H2FlowState::{
    connection_send_window: H2_DEFAULT_WINDOW_SIZE,
    stream_send_window: H2_DEFAULT_WINDOW_SIZE,
    peer_initial_window: H2_DEFAULT_WINDOW_SIZE,
    peer_max_frame_size: H2_MAX_FRAME_SIZE,
    peer_max_header_list_size: H2_MAX_WINDOW_SIZE,
    peer_max_concurrent_streams: H2_MAX_WINDOW_SIZE,
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
  mut goaway_last_stream_id : Int?
  mut informational_count : Int
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
    goaway_last_stream_id: None,
    informational_count: 0,
  }
}

/// Extract the last processed stream id and error code from a GOAWAY payload.
/// The high bit of the first four octets is reserved and must be ignored.
fn h2_parse_goaway(payload : Bytes) -> Result[(Int, Int), HttpError] {
  if payload.length() < 8 {
    return Err(ProtocolError("Invalid HTTP/2 GOAWAY length"))
  }
  let stream_id = ((payload[0].to_int() & 0x7f) << 24) |
    (payload[1].to_int() << 16) |
    (payload[2].to_int() << 8) |
    payload[3].to_int()
  let error_code = (payload[4].to_int() << 24) |
    (payload[5].to_int() << 16) |
    (payload[6].to_int() << 8) |
    payload[7].to_int()
  Ok((stream_id, error_code))
}

fn h2_parse_rst_stream_error(payload : Bytes) -> Result[Int, HttpError] {
  if payload.length() != 4 {
    return Err(ProtocolError("Invalid HTTP/2 RST_STREAM length"))
  }
  Ok((payload[0].to_int() << 24) |
    (payload[1].to_int() << 16) |
    (payload[2].to_int() << 8) |
    payload[3].to_int())
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

fn h2_valid_field_value(value : String) -> Bool {
  if !valid_header_value(value) {
    return false
  }
  if value.length() == 0 {
    return true
  }
  let first = value.get_char(0)
  let last = value.get_char(value.length() - 1)
  !(first == Some(' ') || first == Some('\t') ||
    last == Some(' ') || last == Some('\t'))
}

fn h2_forbidden_header(name : String) -> Bool {
  match name.to_lower() {
    "connection" | "proxy-connection" | "keep-alive" | "transfer-encoding" |
    "upgrade" => true
    _ => false
  }
}

fn h2_forbidden_trailer_field(name : String) -> Bool {
  match name.to_lower() {
    "content-length" | "transfer-encoding" | "host" | "connection" |
    "trailer" | "te" | "upgrade" | "keep-alive" | "proxy-connection" => true
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
  let trailers_mode = self.status_seen
  if fields.length() == 0 {
    if !trailers_mode {
      return Err(ProtocolError("Empty HTTP/2 header block"))
    }
    if self.body_forbidden {
      return Err(ProtocolError("HTTP/2 response must not include trailers"))
    }
    // An empty trailing HEADERS block is a valid (if unusual) way to end a
    // stream: there are simply no trailer fields. It still has to satisfy the
    // same END_STREAM and Content-Length rules as a non-empty trailer block.
    if !end_stream {
      return Err(ProtocolError("HTTP/2 trailers did not end the stream"))
    }
    if !self.body_forbidden && self.content_length is Some(length) &&
      self.body.length() != length {
      return Err(ProtocolError("HTTP/2 response body does not match Content-Length"))
    }
    self.trailers = Headers::new()
    self.ended = true
    return Ok(())
  }
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
      if !h2_valid_field_name(name) || !h2_valid_field_value(value) {
        return Err(ProtocolError("Invalid HTTP/2 response header"))
      }
      if h2_forbidden_header(name) ||
        (name == "te" && value.trim().to_lower() != "trailers") {
        return Err(ProtocolError("Connection-specific HTTP/2 response header"))
      }
      if trailers_mode && h2_forbidden_trailer_field(name) {
        return Err(ProtocolError("Invalid HTTP/2 trailer field"))
      }
      regular = regular.add(name, value)
    }
  }
  if trailers_mode {
    if status_text is Some(_) {
      return Err(ProtocolError("HTTP/2 trailers contain :status"))
    }
    if self.body_forbidden {
      return Err(ProtocolError("HTTP/2 response must not include trailers"))
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
  if status == 101 {
    return Err(ProtocolError("HTTP/2 does not allow 101 Switching Protocols"))
  }
  if status < 200 {
    if end_stream {
      return Err(ProtocolError("Informational HTTP/2 response ended the stream"))
    }
    self.informational_count = self.informational_count + 1
    if self.informational_count > 8 {
      return Err(ProtocolError("Too many informational HTTP/2 responses"))
    }
    return Ok(())
  }
  self.status = status
  self.status_seen = true
  self.headers = regular
  // Responses to HEAD and 204/205/304 carry no payload body.
  self.body_forbidden = self.head || status == 204 || status == 205 ||
    status == 304
  // Content-Length is still validated for bodyless responses so a malformed
  // field cannot be silently accepted just because no body follows it.
  let declared = match response_content_length(regular) {
    Ok(value) => value
    Err(_) => return Err(ProtocolError("Invalid HTTP/2 Content-Length"))
  }
  if !self.body_forbidden {
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

fn h2_int_in_array(values : Array[Int], target : Int) -> Bool {
  for value in values {
    if value == target {
      return true
    }
  }
  false
}

fn h2_apply_settings(
  payload : Bytes,
  flow : H2FlowState,
) -> Result[Unit, HttpError] {
  let seen : Array[Int] = []
  let mut offset = 0
  while offset < payload.length() {
    if offset + 6 > payload.length() {
      return Err(ProtocolError("Invalid HTTP/2 SETTINGS length"))
    }
    let identifier = (payload[offset].to_int() << 8) | payload[offset + 1].to_int()
    // RFC 9113 §6.5: a SETTINGS frame containing the same parameter more than
    // once is a connection error. This applies to unknown identifiers too.
    if h2_int_in_array(seen, identifier) {
      return Err(ProtocolError("Duplicate HTTP/2 setting"))
    }
    seen.push(identifier)
    let value_high = payload[offset + 2].to_int()
    let value = (value_high << 24) |
      (payload[offset + 3].to_int() << 16) |
      (payload[offset + 4].to_int() << 8) |
      payload[offset + 5].to_int()
    if identifier == H2_SETTINGS_ENABLE_PUSH {
      // A server must not ask the client to enable push. The setting is still
      // legal when it explicitly disables push with value 0. Values are
      // unsigned 32-bit, so compare against 0/1 without relying on sign.
      if value == 1 {
        return Err(ProtocolError("HTTP/2 server sent ENABLE_PUSH"))
      }
      if value != 0 {
        return Err(ProtocolError("Invalid HTTP/2 ENABLE_PUSH"))
      }
    } else if identifier == H2_SETTINGS_INITIAL_WINDOW_SIZE {
      // SETTINGS values are unsigned 32-bit. A high bit set exceeds the
      // largest legal flow-control window (2^31-1).
      if (value_high & 0x80) != 0 || value > H2_MAX_WINDOW_SIZE {
        return Err(ProtocolError("Invalid HTTP/2 initial window size"))
      }
      let delta = value - flow.peer_initial_window
      if delta > 0 {
        if flow.stream_send_window > H2_MAX_WINDOW_SIZE - delta {
          return Err(ProtocolError("HTTP/2 stream window overflow"))
        }
      } else if delta < 0 {
        if flow.stream_send_window < -H2_MAX_WINDOW_SIZE - delta {
          return Err(ProtocolError("HTTP/2 stream window overflow"))
        }
      }
      flow.stream_send_window = flow.stream_send_window + delta
      flow.peer_initial_window = value
    } else if identifier == H2_SETTINGS_MAX_FRAME_SIZE {
      if value < H2_MAX_FRAME_SIZE || value > H2_MAX_FRAME_SIZE_LIMIT {
        return Err(ProtocolError("Invalid HTTP/2 max frame size"))
      }
      flow.peer_max_frame_size = value
    } else if identifier == H2_SETTINGS_MAX_CONCURRENT_STREAMS {
      flow.peer_max_concurrent_streams = if (value_high & 0x80) != 0 {
        H2_MAX_WINDOW_SIZE
      } else {
        value
      }
    } else if identifier == H2_SETTINGS_MAX_HEADER_LIST_SIZE {
      flow.peer_max_header_list_size = if (value_high & 0x80) != 0 {
        H2_MAX_WINDOW_SIZE
      } else {
        value
      }
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
      } else {
        // Server push is disabled, so no other stream can carry a response.
        return Err(ProtocolError("HTTP/2 DATA on unknown stream"))
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
        return Err(ProtocolError("HTTP/2 HEADERS on unknown stream"))
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
          Ok(_) => ()
          Err(err) => return Err(err)
        }
        match stream.flush() {
          Ok(_) => Ok(())
          Err(err) => Err(http_error_from_net(err))
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
        // WINDOW_UPDATE for a stream that has already ended is legal and must
        // not be treated as an overflow error.
        if self.ended {
          return Ok(())
        }
        if flow.stream_send_window > H2_MAX_WINDOW_SIZE - increment {
          return Err(ProtocolError("HTTP/2 stream window overflow"))
        }
        flow.stream_send_window = flow.stream_send_window + increment
      } else if frame.stream_id > self.stream_id {
        return Err(ProtocolError("HTTP/2 WINDOW_UPDATE on idle stream"))
      }
      Ok(())
    }
    H2_FRAME_PING => {
      if (frame.flags & H2_FLAG_ACK) == 0 {
        match h2_write_frame(stream, H2_FRAME_PING, H2_FLAG_ACK, 0, frame.payload) {
          Ok(_) => ()
          Err(err) => return Err(err)
        }
        match stream.flush() {
          Ok(_) => Ok(())
          Err(err) => Err(http_error_from_net(err))
        }
      } else {
        Ok(())
      }
    }
    H2_FRAME_RST_STREAM => {
      if frame.stream_id == self.stream_id {
        let error_code = match h2_parse_rst_stream_error(frame.payload) {
          Ok(value) => value
          Err(err) => return Err(err)
        }
        if error_code == 7 {
          Err(ProtocolError("HTTP/2 stream refused"))
        } else {
          Err(ProtocolError("HTTP/2 stream reset by server"))
        }
      } else if frame.stream_id > self.stream_id {
        Err(ProtocolError("HTTP/2 RST_STREAM on idle stream"))
      } else {
        Ok(())
      }
    }
    H2_FRAME_GOAWAY => {
      let (last_stream_id, error_code) = match h2_parse_goaway(frame.payload) {
        Ok(value) => value
        Err(err) => return Err(err)
      }
      match self.goaway_last_stream_id {
        Some(previous) => if last_stream_id > previous {
          return Err(ProtocolError("HTTP/2 GOAWAY stream id increased"))
        }
        None => ()
      }
      self.goaway_last_stream_id = Some(last_stream_id)
      if error_code != 0 {
        return Err(
          ProtocolError("HTTP/2 GOAWAY error " + error_code.to_string()),
        )
      }
      // A graceful GOAWAY may be sent before the server has finished the
      // streams it already accepted. Those responses are still valid; only
      // streams newer than the advertised id must fail.
      if last_stream_id < self.stream_id {
        Err(ProtocolError("HTTP/2 connection closed by GOAWAY"))
      } else {
        Ok(())
      }
    }
    H2_FRAME_PUSH_PROMISE => {
      Err(ProtocolError("HTTP/2 server push is disabled"))
    }
    H2_FRAME_PRIORITY => Ok(())
    _ => Ok(())
  }
}

/// Header names nominated by `Connection` are hop-by-hop for this message and
/// must not be forwarded onto an HTTP/2 connection. Fixed hop-by-hop fields
/// are handled by `h2_forbidden_header`; this also covers application-specific
/// names such as `Connection: x-trace`.
fn h2_connection_nominated_names(headers : Headers) -> Array[String] {
  let names : Array[String] = []
  for value in headers.get_all("Connection") {
    for token in split_header_list(value) {
      let name = token.trim().to_owned().to_lower()
      if name.length() > 0 && h2_valid_field_name(name) &&
        !h2_name_in_array(names, name) {
        names.push(name)
      }
    }
  }
  names
}

fn h2_name_in_array(names : Array[String], name : String) -> Bool {
  for candidate in names {
    if candidate == name {
      return true
    }
  }
  false
}

fn h2_header_list_size(headers : Array[(String, String)]) -> Int {
  let mut total = 0
  for header in headers {
    let (name, value) = header
    total = total + hpack_entry_size(name, value)
  }
  total
}

fn h2_request_headers(request : Request) -> Result[Array[(String, String)], HttpError] {
  if !valid_url_path_chars(request.url.path) ||
    !valid_url_query_chars(request.url.query) {
    return Err(InvalidUrl("Invalid request target"))
  }
  if !valid_host(request.url.authority()) {
    return Err(InvalidUrl("Invalid host"))
  }
  let connection_nominated = h2_connection_nominated_names(request.headers)
  let body_length = match request.body {
    Some(body) => body.length()
    None => 0
  }
  let content_lengths = request.headers.get_all("Content-Length")
  let content_length = match request_content_length(request.headers) {
    Ok(value) => value
    Err(_) => return Err(InvalidHeader("Content-Length"))
  }
  match content_length {
    Some(declared) => if declared != body_length {
      return Err(InvalidHeader("Content-Length"))
    }
    None => ()
  }
  let headers : Array[(String, String)] = [
    (":method", request.method.to_string()),
    (":scheme", request.url.scheme.to_lower()),
    (":authority", request.url.authority()),
    (":path", request.url.request_target()),
  ]
  if (request.body is Some(_) || method_defines_body(request.method)) &&
    content_lengths.length() == 0 &&
    !h2_name_in_array(connection_nominated, "content-length") {
    headers.push(("content-length", body_length.to_string()))
  }
  if !request.headers.contains("User-Agent") &&
    !h2_name_in_array(connection_nominated, "user-agent") {
    headers.push(("user-agent", "Feather/0.1.0"))
  }
  for header in request.headers.iter() {
    let name = header.name.to_lower()
    if h2_forbidden_header(name) || name == "host" ||
      h2_name_in_array(connection_nominated, name) {
      continue
    }
    if name == "te" && header.value.trim().to_lower() != "trailers" {
      continue
    }
    if name == "content-length" {
      // Normalize accepted whitespace/leading zeroes before putting the field
      // on the wire; HTTP/2 field values must not have surrounding OWS.
      headers.push((name, body_length.to_string()))
      continue
    }
    if !h2_valid_field_name(name) || !h2_valid_field_value(header.value) {
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

fn H2ClientConnection::send_preface(self : H2ClientConnection) -> Result[Unit, HttpError] {
  match write_all(self.stream, h2_preface_bytes) {
    Ok(_) => ()
    Err(err) => return Err(http_error_from_net(err))
  }
  let settings = h2_settings_payload([
    (H2_SETTINGS_ENABLE_PUSH, 0),
    (H2_SETTINGS_INITIAL_WINDOW_SIZE, H2_MAX_WINDOW_SIZE),
    (H2_SETTINGS_MAX_HEADER_LIST_SIZE, 1048576),
  ])
  match h2_write_frame(self.stream, H2_FRAME_SETTINGS, 0, 0, settings) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  match h2_send_window_update(
    self.stream,
    0,
    H2_MAX_WINDOW_SIZE - H2_DEFAULT_WINDOW_SIZE,
  ) {
    Ok(_) => Ok(())
    Err(err) => Err(err)
  }
}

/// A persistent HTTP/2 client connection. It owns the client connection
/// preface, its HPACK decoder, and the next available client-initiated stream
/// id, so sequential requests can reuse the same TLS/TCP connection without
/// renegotiating it.
pub struct H2ClientConnection {
  stream : &Stream
  reader : StreamReader
  decoder : HpackDecoder
  flow : H2FlowState
  mut next_stream_id : Int
  mut closed : Bool
  mut settings_received : Bool
}

/// Create a connection and send the client preface and initial SETTINGS. The
/// preface is flushed with the first request, matching the usual client
/// behavior of batching the settings and request head.
pub fn H2ClientConnection::new(stream : &Stream) -> Result[H2ClientConnection, HttpError] {
  let connection = H2ClientConnection::{
    stream,
    reader: StreamReader::new(stream),
    decoder: HpackDecoder::new(),
    flow: H2FlowState::new(),
    next_stream_id: 1,
    closed: false,
    settings_received: false,
  }
  match connection.send_preface() {
    Ok(_) => Ok(connection)
    Err(err) => Err(err)
  }
}

/// Whether this connection can still be used for another request.
fn H2ClientConnection::is_open(self : H2ClientConnection) -> Bool {
  !self.closed && self.stream.peer_addr() is Ok(_)
}

/// Close the underlying stream. Closing an already closed connection is a
/// no-op.
pub fn H2ClientConnection::close(self : H2ClientConnection) -> Unit {
  self.closed = true
  let _ = self.stream.close()
}

/// Consume connection-level frames that were already buffered when the
/// response ended. A GOAWAY or malformed trailing frame makes the session
/// unusable for another request; SETTINGS and PING are acknowledged.
fn H2ClientConnection::drain_buffered_connection_frames(
  self : H2ClientConnection,
  state : H2ResponseState,
  flow : H2FlowState,
) -> Unit {
  while h2_frame_is_buffered(self.reader) {
    let frame_type = self.reader.pending[self.reader.pending_offset + 3].to_int()
    match frame_type {
      H2_FRAME_SETTINGS
      | H2_FRAME_PING
      | H2_FRAME_WINDOW_UPDATE
      | H2_FRAME_GOAWAY
      | H2_FRAME_PRIORITY => ()
      _ => {
        // A PUSH_PROMISE (push is disabled) or CONTINUATION here is always a
        // connection error. Frames for the just-finished stream are likewise
        // invalid. Keep frames for a not-yet-opened stream buffered: callers
        // may have supplied several sequential responses in one test buffer.
        let offset = self.reader.pending_offset
        let frame_stream_id = ((self.reader.pending[offset + 5].to_int() & 0x7f) << 24) |
          (self.reader.pending[offset + 6].to_int() << 16) |
          (self.reader.pending[offset + 7].to_int() << 8) |
          self.reader.pending[offset + 8].to_int()
        if frame_type == H2_FRAME_PUSH_PROMISE ||
          frame_type == H2_FRAME_CONTINUATION ||
          frame_stream_id <= state.stream_id {
          self.closed = true
        }
        return
      }
    }
    let frame = match h2_read_frame(self.reader) {
      Ok(frame) => frame
      Err(_) => {
        self.closed = true
        return
      }
    }
    match frame.frame_type {
      H2_FRAME_SETTINGS | H2_FRAME_PING | H2_FRAME_WINDOW_UPDATE =>
        match state.handle_frame(frame, flow, self.stream) {
          Ok(_) => ()
          Err(_) => {
            self.closed = true
            return
          }
        }
      H2_FRAME_GOAWAY => {
        match h2_parse_goaway(frame.payload) {
          Ok((last_stream_id, _)) => state.goaway_last_stream_id = Some(last_stream_id)
          Err(_) => ()
        }
        self.closed = true
        return
      }
      H2_FRAME_PRIORITY => ()
      _ => {
        self.closed = true
        return
      }
    }
  }
}

/// Read and apply the server's initial SETTINGS frame before opening the first
/// stream. The server connection preface always starts with SETTINGS, so this
/// establishes its limits without guessing at defaults.
fn H2ClientConnection::read_initial_settings(
  self : H2ClientConnection,
  flow : H2FlowState,
) -> Result[Unit, HttpError] {
  match self.stream.flush() {
    Ok(_) => ()
    Err(err) => {
      self.closed = true
      return Err(http_error_from_net(err))
    }
  }
  while true {
    let frame = match h2_read_frame(self.reader) {
      Ok(frame) => frame
      Err(err) => {
        self.closed = true
        return Err(err)
      }
    }
    match frame.frame_type {
      H2_FRAME_SETTINGS => {
        if (frame.flags & H2_FLAG_ACK) != 0 {
          // The server connection preface must begin with its own SETTINGS
          // frame, not an acknowledgement of the client's settings.
          self.closed = true
          return Err(ProtocolError("HTTP/2 server did not start with SETTINGS"))
        }
        match h2_apply_settings(frame.payload, flow) {
          Ok(_) => ()
          Err(err) => {
            self.closed = true
            return Err(err)
          }
        }
        match h2_write_frame(self.stream, H2_FRAME_SETTINGS, H2_FLAG_ACK, 0, b"") {
          Ok(_) => ()
          Err(err) => {
            self.closed = true
            return Err(err)
          }
        }
        match self.stream.flush() {
          Ok(_) => ()
          Err(err) => {
            self.closed = true
            return Err(http_error_from_net(err))
          }
        }
        self.settings_received = true
        return Ok(())
      }
      H2_FRAME_PING =>
        if (frame.flags & H2_FLAG_ACK) == 0 {
          match h2_write_frame(self.stream, H2_FRAME_PING, H2_FLAG_ACK, 0, frame.payload) {
            Ok(_) => ()
            Err(err) => {
              self.closed = true
              return Err(err)
            }
          }
          match self.stream.flush() {
            Ok(_) => ()
            Err(err) => {
              self.closed = true
              return Err(http_error_from_net(err))
            }
          }
        }
      _ => {
        self.closed = true
        return Err(ProtocolError("HTTP/2 server did not start with SETTINGS"))
      }
    }
  }
  Err(ProtocolError("HTTP/2 server did not send SETTINGS"))
}

/// Apply settings and answer PING frames that are already buffered before
/// opening a new stream. WINDOW_UPDATE is left for the body loop because it
/// may target the stream that is about to be opened.
fn H2ClientConnection::drain_buffered_settings(
  self : H2ClientConnection,
  flow : H2FlowState,
) -> Result[Unit, HttpError] {
  while h2_frame_is_buffered(self.reader) {
    let offset = self.reader.pending_offset
    let frame_type = self.reader.pending[offset + 3].to_int()
    let frame_stream_id = ((self.reader.pending[offset + 5].to_int() & 0x7f) << 24) |
      (self.reader.pending[offset + 6].to_int() << 16) |
      (self.reader.pending[offset + 7].to_int() << 8) |
      self.reader.pending[offset + 8].to_int()
    if frame_type == H2_FRAME_WINDOW_UPDATE &&
      frame_stream_id == self.next_stream_id {
      // This update belongs to the stream that is about to be opened. Leave
      // it buffered for the body loop, which resets the stream window first.
      return Ok(())
    }
    if frame_type == H2_FRAME_GOAWAY &&
      self.reader.pending.length() - offset >= 13 {
      let last_stream_id = ((self.reader.pending[offset + 9].to_int() & 0x7f) << 24) |
        (self.reader.pending[offset + 10].to_int() << 16) |
        (self.reader.pending[offset + 11].to_int() << 8) |
        self.reader.pending[offset + 12].to_int()
      if last_stream_id >= self.next_stream_id {
        // The next stream was accepted before the peer sent GOAWAY. Leave
        // both the GOAWAY and its response for the response loop.
        return Ok(())
      }
    }
    match frame_type {
      H2_FRAME_SETTINGS
      | H2_FRAME_PING
      | H2_FRAME_PRIORITY
      | H2_FRAME_GOAWAY
      | H2_FRAME_WINDOW_UPDATE => ()
      _ => return Ok(())
    }
    let frame = match h2_read_frame(self.reader) {
      Ok(frame) => frame
      Err(err) => {
        self.closed = true
        return Err(err)
      }
    }
    match frame.frame_type {
      H2_FRAME_SETTINGS =>
        if (frame.flags & H2_FLAG_ACK) == 0 {
          match h2_apply_settings(frame.payload, flow) {
            Ok(_) => ()
            Err(err) => {
              self.closed = true
              return Err(err)
            }
          }
          match h2_write_frame(self.stream, H2_FRAME_SETTINGS, H2_FLAG_ACK, 0, b"") {
            Ok(_) => ()
            Err(err) => {
              self.closed = true
              return Err(err)
            }
          }
          match self.stream.flush() {
            Ok(_) => ()
            Err(err) => {
              self.closed = true
              return Err(http_error_from_net(err))
            }
          }
        }
      H2_FRAME_PING =>
        if (frame.flags & H2_FLAG_ACK) == 0 {
          match h2_write_frame(self.stream, H2_FRAME_PING, H2_FLAG_ACK, 0, frame.payload) {
            Ok(_) => ()
            Err(err) => {
              self.closed = true
              return Err(err)
            }
          }
          match self.stream.flush() {
            Ok(_) => ()
            Err(err) => {
              self.closed = true
              return Err(http_error_from_net(err))
            }
          }
        }
      H2_FRAME_WINDOW_UPDATE => {
        let increment = match h2_parse_window_update(frame.payload) {
          Ok(value) => value
          Err(err) => {
            self.closed = true
            return Err(err)
          }
        }
        // Only the connection window can still matter before the next stream
        // is opened. Updates for already-closed streams are harmless, but an
        // update for a stream that has never been opened is a protocol error.
        if frame.stream_id == 0 {
          if flow.connection_send_window > H2_MAX_WINDOW_SIZE - increment {
            self.closed = true
            return Err(ProtocolError("HTTP/2 connection window overflow"))
          }
          flow.connection_send_window = flow.connection_send_window + increment
        } else if frame.stream_id >= self.next_stream_id {
          self.closed = true
          return Err(ProtocolError("HTTP/2 WINDOW_UPDATE on idle stream"))
        }
      }
      H2_FRAME_GOAWAY => {
        self.closed = true
        let error_code = match h2_parse_goaway(frame.payload) {
          Ok((_, code)) => code
          Err(err) => return Err(err)
        }
        if error_code != 0 {
          return Err(ProtocolError("HTTP/2 GOAWAY error " + error_code.to_string()))
        }
        return Err(ProtocolError("HTTP/2 connection closed by GOAWAY"))
      }
      _ => ()
    }
  }
  Ok(())
}

/// Perform one request on this connection, reusing the client connection
/// preface, HPACK decoder and connection-level flow-control window.
pub fn H2ClientConnection::request_with_limit(
  self : H2ClientConnection,
  request : Request,
  max_body_bytes : Int,
) -> Result[Response, HttpError] {
  if !self.is_open() {
    return Err(ConnectionClosed)
  }
  let headers = match h2_request_headers(request) {
    Ok(headers) => headers
    Err(err) => return Err(err)
  }
  if !self.settings_received {
    match self.read_initial_settings(self.flow) {
      Ok(_) => ()
      Err(err) => return Err(err)
    }
  }
  match self.drain_buffered_settings(self.flow) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  if self.flow.peer_max_concurrent_streams < 1 {
    return Err(ProtocolError("HTTP/2 max concurrent streams is zero"))
  }
  if h2_header_list_size(headers) > self.flow.peer_max_header_list_size {
    return Err(ProtocolError("HTTP/2 request header list too large"))
  }
  let stream_id = self.next_stream_id
  if stream_id < 1 || stream_id > H2_MAX_WINDOW_SIZE {
    self.closed = true
    return Err(ProtocolError("HTTP/2 stream id exhausted"))
  }
  let block = hpack_encode(headers)
  let body = match request.body {
    Some(body) => body
    None => b""
  }
  let end_stream = body.length() == 0
  // A new stream starts with the peer's current initial window.
  self.flow.stream_send_window = self.flow.peer_initial_window
  match h2_write_header_block(self.stream, stream_id, block, end_stream) {
    Ok(_) => ()
    Err(err) => {
      self.closed = true
      return Err(err)
    }
  }
  // Stream ids are never reused. Advancing here also prevents a failed
  // exchange from sending another HEADERS frame on the same stream.
  self.next_stream_id = stream_id + 2
  // Make the request visible to the peer before blocking on the response.
  match self.stream.flush() {
    Ok(_) => ()
    Err(err) => {
      self.closed = true
      return Err(http_error_from_net(err))
    }
  }

  let state = H2ResponseState::new(
    stream_id,
    self.decoder,
    max_body_bytes,
    request.method == HEAD,
  )
  let flow = self.flow
  let mut sent = 0
  while sent < body.length() && !state.ended {
    let available = if flow.connection_send_window < flow.stream_send_window {
      flow.connection_send_window
    } else {
      flow.stream_send_window
    }
    if available <= 0 {
      let frame = match h2_read_frame(self.reader) {
        Ok(frame) => frame
        Err(err) => {
          self.closed = true
          return Err(err)
        }
      }
      match state.handle_frame(frame, flow, self.stream) {
        Ok(_) => ()
        Err(err) => {
          self.closed = true
          return Err(err)
        }
      }
      continue
    }
    let remaining = body.length() - sent
    let wanted = if available < remaining { available } else { remaining }
    let take = if wanted < H2_MAX_FRAME_SIZE { wanted } else { H2_MAX_FRAME_SIZE }
    let last = sent + take == body.length()
    let flags = if last { H2_FLAG_END_STREAM } else { 0 }
    match h2_write_frame(
      self.stream,
      H2_FRAME_DATA,
      flags,
      stream_id,
      body.exact_view(start=sent, end=sent + take).to_owned(),
    ) {
      Ok(_) => ()
      Err(err) => {
        self.closed = true
        return Err(err)
      }
    }
    // Flush each body frame before the loop may block waiting for a window
    // update or a response frame.
    match self.stream.flush() {
      Ok(_) => ()
      Err(err) => {
        self.closed = true
        return Err(http_error_from_net(err))
      }
    }
    sent = sent + take
    flow.connection_send_window = flow.connection_send_window - take
    flow.stream_send_window = flow.stream_send_window - take
  }

  while !state.ended {
    let frame = match h2_read_frame(self.reader) {
      Ok(frame) => frame
      Err(err) => {
        self.closed = true
        return Err(err)
      }
    }
    match state.handle_frame(frame, flow, self.stream) {
      Ok(_) => ()
      Err(err) => {
        self.closed = true
        return Err(err)
      }
    }
  }
  self.drain_buffered_connection_frames(state, flow)
  // An early final response (for example 413 or 401) leaves the request side
  // of this stream half-open. Reset the stream instead of returning the
  // connection to the pool with an unfinished upload.
  if sent < body.length() && !self.closed {
    match h2_write_frame(
      self.stream,
      H2_FRAME_RST_STREAM,
      0,
      stream_id,
      b"\x00\x00\x00\x08",
    ) {
      Ok(_) => ()
      Err(_) => self.closed = true
    }
  }
  match self.stream.flush() {
    Ok(_) => ()
    Err(err) => {
      self.closed = true
      return Err(http_error_from_net(err))
    }
  }
  if state.goaway_last_stream_id is Some(_) {
    // The peer will not accept another stream on this connection.
    self.closed = true
  }
  Ok(h2_make_response(state))
}

/// Perform one request with the default response body limit.
pub fn H2ClientConnection::request(
  self : H2ClientConnection,
  request : Request,
) -> Result[Response, HttpError] {
  self.request_with_limit(request, DEFAULT_MAX_BODY_BYTES)
}

fn h2_request_with_limit(
  stream : &Stream,
  request : Request,
  max_body_bytes : Int,
) -> Result[Response, HttpError] {
  let connection = match H2ClientConnection::new(stream) {
    Ok(connection) => connection
    Err(err) => return Err(err)
  }
  connection.request_with_limit(request, max_body_bytes)
}

/// Perform one HTTP/2 request over an ALPN-negotiated stream. The connection
/// must already have negotiated the `h2` protocol; the caller owns closing it.
pub fn h2_request(stream : &Stream, request : Request) -> Result[Response, HttpError] {
  h2_request_with_limit(stream, request, DEFAULT_MAX_BODY_BYTES)
}
