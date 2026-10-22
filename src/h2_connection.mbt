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
  // WINDOW_UPDATE received for the next stream before its HEADERS were sent.
  mut pending_stream_window : Int
  // RFC 8441 extended CONNECT (used for WebSocket over HTTP/2).
  mut peer_enable_connect_protocol : Bool
}

fn H2FlowState::new() -> H2FlowState {
  H2FlowState::{
    connection_send_window: H2_DEFAULT_WINDOW_SIZE,
    stream_send_window: H2_DEFAULT_WINDOW_SIZE,
    peer_initial_window: H2_DEFAULT_WINDOW_SIZE,
    peer_max_frame_size: H2_MAX_FRAME_SIZE,
    peer_max_header_list_size: H2_MAX_WINDOW_SIZE,
    peer_max_concurrent_streams: H2_MAX_WINDOW_SIZE,
    pending_stream_window: 0,
    peer_enable_connect_protocol: false,
  }
}

/// Streams opened by the client use odd identifiers. Even identifiers belong
/// to server-initiated streams, which are invalid because push is disabled.
fn h2_is_client_stream(stream_id : Int) -> Bool {
  stream_id > 0 && (stream_id & 1) == 1
}

/// Largest DATA payload we may send. The peer's setting can only increase the
/// protocol default, and our frame writer also caps at the default.
fn h2_outbound_frame_limit(peer_max_frame_size : Int) -> Int {
  if peer_max_frame_size < H2_MAX_FRAME_SIZE {
    peer_max_frame_size
  } else {
    H2_MAX_FRAME_SIZE
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
  mut max_body_bytes : Int
  head : Bool
  connect : Bool
  mut status : Int
  mut status_seen : Bool
  mut headers : Headers
  mut content_length : Int?
  mut body_forbidden : Bool
  mut body : Buffer
  // Total payload bytes accepted for this stream. `body` is only the bytes
  // that have not been handed to the caller yet, so this separate counter is
  // what Content-Length validation must use.
  mut body_received : Int
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
  connect : Bool,
) -> H2ResponseState {
  H2ResponseState::{
    stream_id,
    decoder,
    max_body_bytes: if max_body_bytes < 0 { 0 } else { max_body_bytes },
    head,
    connect,
    status: 0,
    status_seen: false,
    headers: Headers::new(),
    content_length: None,
    body_forbidden: false,
    body: Buffer(size_hint=4096),
    body_received: 0,
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

/// Read a frame for a client connection. `h2_read_frame` reports a
/// self-dependent PRIORITY frame as a protocol error; that is a stream-scoped
/// priority violation, so a client that does not use priority can discard the
/// frame and keep the connection usable.
fn h2_read_connection_frame(reader : StreamReader) -> Result[H2Frame, HttpError] {
  match h2_read_frame(reader) {
    Err(ProtocolError(message)) =>
      if message == "HTTP/2 stream cannot depend on itself" {
        // The frame was fully consumed. Surface an inert PRIORITY frame so the
        // caller ignores the stream-scoped priority violation without
        // consuming the next frame.
        Ok(H2Frame::{
          frame_type: H2_FRAME_PRIORITY,
          flags: 0,
          stream_id: 0,
          payload: b"",
        })
      } else {
        Err(ProtocolError(message))
      }
    result => result
  }
}

/// A stream-scoped fatal error that leaves the connection usable after a
/// RST_STREAM has been sent for the affected stream.
fn h2_error_is_stream_reset(err : HttpError) -> Bool {
  match err {
    ProtocolError(message) =>
      message == "HTTP/2 stream WINDOW_UPDATE increment is zero"
    _ => false
  }
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
  let name = name.to_lower()
  // Existing HTTP/2 callers treat these response metadata fields as ordinary
  // trailer fields, so keep accepting them. Every other HTTP/1.1 trailer
  // restriction still applies (RFC 9113 §8.1): framing, routing,
  // authentication, request modifiers, and payload transforms cannot move to
  // the trailer section.
  if name == "content-type" || name == "cache-control" {
    return false
  }
  is_forbidden_trailer_field(name)
}

/// Validate request trailer fields before they are written. Request trailers
/// must never carry framing, routing, authentication, or payload metadata.
fn h2_request_trailer_fields(
  trailers : Headers,
) -> Result[Array[(String, String)], HttpError] {
  let fields : Array[(String, String)] = []
  for trailer in trailers.iter() {
    let name = trailer.name.to_lower()
    if !h2_valid_field_name(name) || !h2_valid_field_value(trailer.value) ||
      is_forbidden_trailer_field(name) {
      return Err(InvalidHeader(trailer.name))
    }
    fields.push((name, trailer.value))
  }
  Ok(fields)
}

fn h2_trailer_names(trailers : Headers) -> String {
  let names = Buffer(size_hint=64)
  for trailer in trailers.iter() {
    if names.length() > 0 {
      names.write_bytes(@utf8.encode(", "))
    }
    names.write_bytes(@utf8.encode(trailer.name.to_lower()))
  }
  @utf8.decode_lossy(names.to_bytes()[:])
}

/// Remove the currently buffered body bytes and reset the staging buffer.
/// `body_received` keeps the lifetime total for Content-Length validation.
fn H2ResponseState::take_body(self : H2ResponseState) -> Bytes {
  let data = self.body.to_bytes()
  self.body = Buffer(size_hint=4096)
  data
}

fn H2ResponseState::is_tunnel(self : H2ResponseState) -> Bool {
  self.connect && self.status_seen && self.status >= 200 && self.status < 300
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
      self.body_received != length {
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
      // TE is a request-only field in HTTP/2 (RFC 9113 §8.2.2); a response
      // containing it is malformed even when its value is "trailers".
      if h2_forbidden_header(name) || name == "te" {
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
      self.body_received != length {
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
    if regular.contains("content-length") {
      return Err(ProtocolError(
        "HTTP/2 informational response must not include Content-Length",
      ))
    }
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
  let connect_tunnel = self.connect && status >= 200 && status < 300
  // A successful CONNECT response switches to an opaque tunnel; it has no
  // HTTP message body framing. Responses to HEAD, 204, 205 and 304 otherwise
  // carry no payload body.
  if connect_tunnel && regular.contains("content-length") {
    return Err(ProtocolError(
      "Successful CONNECT response must not include Content-Length",
    ))
  }
  self.body_forbidden = if connect_tunnel {
    false
  } else {
    self.head || status == 204 || status == 205 || status == 304
  }
  // Content-Length is still validated for bodyless responses so a malformed
  // field cannot be silently accepted just because no body follows it.
  let declared = match response_content_length(regular) {
    Ok(value) => value
    Err(_) => return Err(ProtocolError("Invalid HTTP/2 Content-Length"))
  }
  // HTTP semantics forbid Content-Length on 204 responses entirely; a 205
  // response may only advertise a zero-length body (RFC 9110 §8.6/§15.3.6).
  if status == 204 && regular.contains("content-length") {
    return Err(ProtocolError("HTTP/2 204 response must not include Content-Length"))
  }
  if status == 205 && declared is Some(length) && length != 0 {
    return Err(ProtocolError(
      "HTTP/2 205 response must not have a non-zero Content-Length",
    ))
  }
  if connect_tunnel {
    self.content_length = None
  } else if !self.body_forbidden {
    match declared {
      Some(length) => {
        // The declared length is checked against the configured cap while
        // DATA is consumed. A streaming caller may raise that cap through
        // `Response::read_body_with_limit` after the response head arrives, so
        // rejecting solely from the head would make the explicit limit
        // override unusable for Content-Length responses.
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
    if offset + 6 > payload.length() {
      return Err(ProtocolError("Invalid HTTP/2 SETTINGS length"))
    }
    let identifier = (payload[offset].to_int() << 8) | payload[offset + 1].to_int()
    // RFC 9113 §6.5: settings are processed in order and each parameter
    // replaces any previous value, so a repeated identifier is legal and the
    // last value wins. Unknown identifiers are ignored.
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
    } else if identifier == H2_SETTINGS_ENABLE_CONNECT_PROTOCOL {
      if (value_high & 0x80) != 0 || value > 1 {
        return Err(ProtocolError("Invalid HTTP/2 enable connect protocol"))
      }
      flow.peer_enable_connect_protocol = value == 1
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
          if !self.is_tunnel() &&
            payload.length() > self.max_body_bytes - self.body_received {
            return Err(ProtocolError("HTTP/2 response body too large"))
          }
          if self.content_length is Some(length) &&
            payload.length() > length - self.body_received {
            return Err(ProtocolError("HTTP/2 response body does not match Content-Length"))
          }
          self.body.write_bytes(payload)
          self.body_received = self.body_received + payload.length()
        }
        if (frame.flags & H2_FLAG_END_STREAM) != 0 {
          if !self.body_forbidden && self.content_length is Some(length) &&
            self.body_received != length {
            return Err(ProtocolError("HTTP/2 response body does not match Content-Length"))
          }
          self.ended = true
        }
      } else if frame.stream_id < self.stream_id {
        if !h2_is_client_stream(frame.stream_id) {
          return Err(ProtocolError("HTTP/2 DATA on a server-push stream"))
        }
        // The stream was reset or finished earlier (for example after an early
        // response). Frames that arrive late are harmless; discard the payload
        // but still account for it in the connection-level flow-control window.
      } else {
        // Server push is disabled, so no other stream can carry a response.
        return Err(ProtocolError("HTTP/2 DATA on unknown stream"))
      }
      // The connection-level receive window is replenished as bytes arrive,
      // including DATA for an already closed stream.
      if frame.stream_id <= self.stream_id && frame.payload.length() > 0 {
        match h2_send_window_update(stream, 0, frame.payload.length()) {
          Ok(_) => ()
          Err(err) => return Err(err)
        }
      }
      // Padding consumes the stream's flow-control window even though it is
      // not part of the response body. Replenish the active stream as well so
      // a peer that pads heavily cannot exhaust the window and stall while the
      // client waits for more body bytes.
      if frame.stream_id == self.stream_id && !self.ended &&
        frame.payload.length() > 0 {
        match h2_send_window_update(stream, self.stream_id, frame.payload.length()) {
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
      let block = match h2_header_block_payload_for_connection(frame) {
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
        Err(err) => {
          if frame.stream_id != 0 &&
            err == ProtocolError("Invalid HTTP/2 WINDOW_UPDATE increment") {
            if frame.stream_id == self.stream_id {
              if self.ended {
                // The stream is already closed. RFC 9113 §6.9 only makes a
                // zero increment an error for streams that can still send, so
                // a late update must not tear down a reusable connection.
                return Ok(())
              }
              // A zero increment is a stream error on a non-zero stream. Reset
              // only that stream so the connection can carry later requests.
              let _ = h2_write_frame(
                stream,
                H2_FRAME_RST_STREAM,
                0,
                frame.stream_id,
                b"\x00\x00\x00\x01",
              )
              let _ = stream.flush()
              return Err(ProtocolError("HTTP/2 stream WINDOW_UPDATE increment is zero"))
            } else if frame.stream_id < self.stream_id {
              if !h2_is_client_stream(frame.stream_id) {
                // Server-push streams are never valid here because push is
                // disabled. Do not silently ignore a malformed update for one,
                // even when its increment is zero.
                return Err(ProtocolError(
                  "HTTP/2 WINDOW_UPDATE on a server-push stream",
                ))
              }
              // The stream has already ended; the update has no effect.
              return Ok(())
            }
          }
          return Err(err)
        }
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
      } else if !h2_is_client_stream(frame.stream_id) {
        return Err(ProtocolError("HTTP/2 WINDOW_UPDATE on a server-push stream"))
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
        // REFUSED_STREAM only guarantees that the server did not process the
        // request when no response head was received. Seeing response headers
        // first means a retry could duplicate side effects, so surface it as a
        // generic reset instead of the safely-retryable refusal marker.
        if error_code == 7 && !self.status_seen {
          Err(ProtocolError("HTTP/2 stream refused"))
        } else {
          Err(ProtocolError("HTTP/2 stream reset by server"))
        }
      } else if frame.stream_id > self.stream_id {
        Err(ProtocolError("HTTP/2 RST_STREAM on idle stream"))
      } else if !h2_is_client_stream(frame.stream_id) {
        Err(ProtocolError("HTTP/2 RST_STREAM on a server-push stream"))
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
      // A graceful GOAWAY may be sent before the server has finished the
      // streams it already accepted. Those responses are still valid; only
      // streams newer than the advertised id must fail.
      if last_stream_id < self.stream_id {
        if !self.status_seen {
          // The advertised id excludes our stream, so the request was not
          // processed. Use the marker that the client recognizes as safe to
          // retry, even when the GOAWAY also carries a non-zero error code.
          return Err(ProtocolError("HTTP/2 connection closed by GOAWAY"))
        }
        // The server already sent response headers for this stream, so it did
        // process the request despite the contradictory GOAWAY id. Retrying
        // could duplicate side effects.
        return Err(
          ProtocolError("HTTP/2 connection closed by GOAWAY after response headers"),
        )
      }
      if error_code != 0 {
        return Err(
          ProtocolError("HTTP/2 GOAWAY error " + error_code.to_string()),
        )
      }
      Ok(())
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

/// The first protocol token offered by a request's `Upgrade` field, if the
/// request also nominated `upgrade` in its `Connection` field.
fn h2_upgrade_protocol(request : Request) -> String? {
  if !headers_have_token(request.headers, "Connection", "upgrade") {
    return None
  }
  for value in request.headers.get_all("Upgrade") {
    for part in split_header_list(value) {
      let token = part.trim().to_owned().to_lower()
      if token.length() > 0 && h2_valid_field_name(token) {
        return Some(token)
      }
    }
  }
  None
}

#warnings("-unused_value")
fn h2_request_headers(request : Request) -> Result[Array[(String, String)], HttpError] {
  h2_request_headers_with_protocol(request, None)
}

/// Build the HTTP/2 field list for a request. When `extended_protocol` is set,
/// the request is an RFC 8441 extended CONNECT: the wire method is CONNECT and
/// `:protocol` names the upgraded protocol, while `:scheme` and `:path` remain
/// present so the peer can route the original resource.
fn h2_request_headers_with_protocol(
  request : Request,
  extended_protocol : String?,
) -> Result[Array[(String, String)], HttpError] {
  if !valid_url_path_chars(request.url.path) ||
    !valid_url_query_chars(request.url.query) {
    return Err(InvalidUrl("Invalid request target"))
  }
  // HTTP/2 carries upgrades through extended CONNECT. A caller-supplied
  // Upgrade field without the HTTP/1 Connection nomination is malformed and
  // must not be silently dropped as if it were an ordinary header.
  if request.headers.contains("Upgrade") &&
    h2_upgrade_protocol(request) is None {
    return Err(InvalidHeader("Upgrade"))
  }
  let resolved_method = canonical_http_method(request.method)
  let extended_connect = extended_protocol is Some(_)
  if extended_connect && resolved_method != GET && resolved_method != CONNECT {
    return Err(ProtocolError(
      "Extended CONNECT requires a GET or CONNECT request",
    ))
  }
  let is_connect = resolved_method == CONNECT && !extended_connect
  if is_connect &&
    (request.url.path != "/" || request.url.query.length() > 0) {
    return Err(InvalidUrl("CONNECT requires an authority-form target"))
  }
  let authority = if is_connect {
    request.url.connect_authority()
  } else {
    request.url.authority()
  }
  if !valid_host(authority) {
    return Err(InvalidUrl("Invalid host"))
  }
  let asterisk_form = request.url.path == "*"
  if asterisk_form && resolved_method != OPTIONS {
    return Err(InvalidUrl("Asterisk-form is only valid for OPTIONS"))
  }
  if asterisk_form && request.url.query.length() > 0 {
    return Err(InvalidUrl("Asterisk-form cannot include a query"))
  }
  if asterisk_form && extended_connect {
    return Err(InvalidUrl("Asterisk-form cannot be an extended CONNECT target"))
  }
  let request_target = if is_connect {
    authority
  } else if asterisk_form {
    "*"
  } else {
    request.url.request_target()
  }
  let connection_nominated = h2_connection_nominated_names(request.headers)
  let content_length_nominated = h2_name_in_array(
    connection_nominated,
    "content-length",
  )
  let body_length = match request.body {
    Some(body) => body.length()
    None => 0
  }
  // RFC 9110 §9.3.8: a client MUST NOT generate content in a TRACE request.
  if resolved_method == TRACE &&
    (body_length > 0 || request.trailers.length() > 0) {
    return Err(InvalidHeader("TRACE request content is not allowed"))
  }
  // CONNECT establishes a tunnel; request content would be ambiguous with the
  // first tunnelled bytes, so it is not generated here. Extended CONNECT has
  // the same framing rule because the 2xx response switches to the protocol.
  if (is_connect || extended_connect) &&
    (request.body is Some(_) || request.trailers.length() > 0) {
    return Err(InvalidHeader("CONNECT request content is not allowed"))
  }
  let content_lengths = request.headers.get_all("Content-Length")
  // A field nominated by Connection is removed before the request is sent, so
  // it must not be validated as part of the HTTP/2 header list.
  let content_length = if content_length_nominated {
    None
  } else {
    match request_content_length(request.headers) {
      Ok(value) => value
      Err(_) => return Err(InvalidHeader("Content-Length"))
    }
  }
  match content_length {
    Some(declared) => if declared != body_length {
      return Err(InvalidHeader("Content-Length"))
    }
    None => ()
  }
  if (is_connect || extended_connect) && content_length is Some(_) {
    return Err(InvalidHeader("CONNECT request content is not allowed"))
  }
  let verb = resolved_method.to_string()
  // The public `Custom` variant can be built without `HttpMethod::custom`, so
  // reject invalid tokens at the HTTP/2 wire boundary too.
  if !valid_header_name(verb) {
    return Err(InvalidMethod(verb))
  }
  // CONNECT uses authority-form and has no :scheme or :path (RFC 9113 §8.5).
  let headers : Array[(String, String)] = if is_connect {
    [(":method", verb), (":authority", authority)]
  } else if extended_connect {
    let protocol = match extended_protocol {
      Some(value) => value
      None => ""
    }
    [
      (":method", "CONNECT"),
      (":scheme", request.url.scheme.to_lower()),
      (":authority", authority),
      (":path", request_target),
      (":protocol", protocol),
    ]
  } else {
    [
      (":method", verb),
      (":scheme", request.url.scheme.to_lower()),
      (":authority", authority),
      (":path", request_target),
    ]
  }
  if (request.body is Some(_) || method_defines_body(resolved_method)) &&
    content_lengths.length() == 0 && !content_length_nominated {
    headers.push(("content-length", body_length.to_string()))
  }
  if request.trailers.length() > 0 && !request.headers.contains("Trailer") &&
    !h2_name_in_array(connection_nominated, "trailer") {
    headers.push(("trailer", h2_trailer_names(request.trailers)))
  }
  if !request.headers.contains("User-Agent") &&
    !h2_name_in_array(connection_nominated, "user-agent") {
    headers.push(("user-agent", "Feather/0.1.0"))
  }
  // RFC 9113 §8.2.3 allows a Cookie field to be split into multiple field
  // lines, but recipients must concatenate the fragments with "; ". Send one
  // field to peers that only look at a single Cookie header, keeping the
  // caller's fragment order.
  let cookie_values : Array[String] = []
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
    if name == "cookie" {
      cookie_values.push(header.value)
      continue
    }
    headers.push((name, header.value))
  }
  if cookie_values.length() > 0 {
    headers.push(("cookie", cookie_values.join("; ")))
  }
  Ok(headers)
}

fn h2_body_stream(data : Bytes) -> H2BodyStream {
  H2BodyStream::{ data, offset: 0, is_open: true }
}

struct H2BodyStream {
  data : Bytes
  mut offset : Int
  mut is_open : Bool
}

pub impl Stream for H2BodyStream with fn read(self : H2BodyStream, buf : Buffer) -> Result[Int, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  let remaining = self.data.length() - self.offset
  if remaining <= 0 {
    return Ok(0)
  }
  let take = if remaining < 4096 { remaining } else { 4096 }
  buf.write_bytes(self.data.exact_view(start=self.offset, end=self.offset + take))
  self.offset = self.offset + take
  Ok(take)
}

pub impl Stream for H2BodyStream with fn read_ready(
  self : H2BodyStream,
) -> Bool {
  // Buffered bodies never block: an exhausted stream reads as EOF.
  self.is_open
}

pub impl Stream for H2BodyStream with fn wait_readable(
  self : H2BodyStream,
  timeout_ms : Int,
) -> Result[Bool, NetError] {
  let _ = timeout_ms
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Ok(true)
}

pub impl Stream for H2BodyStream with fn write(self : H2BodyStream, buf : Buffer) -> Result[Int, NetError] {
  let _ = buf
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Err(NetError::WriteError("HTTP/2 response body is read-only"))
}

pub impl Stream for H2BodyStream with fn flush(self : H2BodyStream) -> Result[Unit, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Ok(())
}

pub impl Stream for H2BodyStream with fn close(self : H2BodyStream) -> Result[Unit, NetError] {
  self.is_open = false
  Ok(())
}

pub impl Stream for H2BodyStream with fn set_timeout(self : H2BodyStream, timeout_ms : Int) -> Result[Unit, NetError] {
  let _ = timeout_ms
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Ok(())
}

pub impl Stream for H2BodyStream with fn peer_addr(self : H2BodyStream) -> Result[String, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Err(NetError::InvalidAddress("HTTP/2 response body has no peer"))
}

pub impl Stream for H2BodyStream with fn local_addr(self : H2BodyStream) -> Result[String, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
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
    (H2_SETTINGS_ENABLE_CONNECT_PROTOCOL, 1),
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
  // A lazy response body owns the connection until it reaches END_STREAM or is
  // closed. While true, starting another exchange would interleave frames.
  mut streaming_busy : Bool
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
    streaming_busy: false,
  }
  match connection.send_preface() {
    Ok(_) => Ok(connection)
    Err(err) => Err(err)
  }
}

/// Whether this connection can still be used for another request.
fn H2ClientConnection::is_open(self : H2ClientConnection) -> Bool {
  !self.closed && !self.streaming_busy && self.stream.is_alive()
}

/// Close the underlying stream. Closing an already closed connection is a
/// no-op.
pub fn H2ClientConnection::close(self : H2ClientConnection) -> Unit {
  self.closed = true
  let _ = self.stream.close()
}

/// Lazily-read response body for `request_streaming`. It owns the connection
/// exchange until the peer ends the stream or the caller closes the body.
struct H2LiveBodyStream {
  connection : H2ClientConnection
  state : H2ResponseState
  flow : H2FlowState
  trailers : @ref.Ref[Headers]
  mut pending : Bytes
  mut pending_offset : Int
  mut is_open : Bool
  mut completed : Bool
  // Set when the completed body handed its connection back to the pool. At
  // that point the stream must not retimeout or query the pooled transport,
  // just like a released HTTP/1.1 response stream.
  mut released_to_pool : Bool
  mut error : HttpError?
  on_complete : ((Bool) -> Unit)?
}

fn H2LiveBodyStream::finish(self : H2LiveBodyStream, reusable : Bool) -> Unit {
  if self.completed {
    return
  }
  let mut keep = reusable
  // Once the response has ended, consume any complete connection frames that
  // were already buffered with it. This acknowledges PING/SETTINGS and notices
  // a GOAWAY before the session is offered to the pool, matching the buffered
  // response path.
  if keep && self.state.ended {
    match self.connection.drain_buffered_connection_frames(self.state, self.flow) {
      Ok(_) => ()
      Err(_) => self.connection.closed = true
    }
    if self.connection.closed {
      keep = false
    }
  }
  self.completed = true
  self.released_to_pool = keep && self.on_complete is Some(_)
  if self.state.ended {
    self.trailers.val = self.state.trailers
    // A graceful GOAWAY after this stream was accepted still forbids opening
    // another stream on the connection. Do not let the lease pool it.
    if self.state.goaway_last_stream_id is Some(_) {
      self.connection.closed = true
      keep = false
    }
  }
  match self.on_complete {
    Some(callback) => callback(keep)
    None => ()
  }
  if !keep {
    self.connection.close()
  }
}

fn h2_live_body_net_error(err : HttpError) -> NetError {
  match err {
    NetworkError(net) => net
    Timeout => Timeout
    ConnectionClosed => Closed
    _ => NetError::ReadError(@debug.to_string(err))
  }
}

fn H2LiveBodyStream::fail(self : H2LiveBodyStream, err : HttpError) -> NetError {
  self.error = Some(err)
  self.finish(false)
  h2_live_body_net_error(err)
}

/// Read frames until at least one body byte is available or the stream ends.
/// SETTINGS/PING/WINDOW_UPDATE frames are handled and skipped.
fn H2LiveBodyStream::pull(self : H2LiveBodyStream) -> Result[Unit, NetError] {
  while true {
    if self.state.ended {
      self.pending = self.state.take_body()
      self.pending_offset = 0
      return Ok(())
    }
    let frame = match h2_read_connection_frame(self.connection.reader) {
      Ok(frame) => frame
      Err(err) => return Err(self.fail(err))
    }
    match self.state.handle_frame(
      frame,
      self.flow,
      self.connection.stream,
    ) {
      Ok(_) => ()
      Err(err) => {
        if h2_error_is_stream_reset(err) {
          // The peer reset only this stream. Consume its already-buffered
          // frames so they cannot be mistaken for a later response, then
          // release the session as reusable instead of tearing it down.
          self.connection
            .discard_buffered_stream_frames(self.state, self.flow, self.state.stream_id)
          self.error = Some(err)
          self.finish(true)
          return Err(h2_live_body_net_error(err))
        }
        self.connection.closed = true
        return Err(self.fail(err))
      }
    }
    self.pending = self.state.take_body()
    self.pending_offset = 0
    if self.state.ended {
      self.trailers.val = self.state.trailers
    }
    if self.pending.length() > 0 || self.state.ended {
      return Ok(())
    }
  }
  Ok(())
}

pub impl Stream for H2LiveBodyStream with fn read(
  self : H2LiveBodyStream,
  buf : Buffer,
) -> Result[Int, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  match self.error {
    // Errors set by `fail` have already completed and closed the body; map
    // the stored error again without repeating that teardown. A stream-reset
    // error also leaves the connection reusable.
    Some(err) => return Err(h2_live_body_net_error(err))
    None => ()
  }
  while self.pending_offset >= self.pending.length() {
    if self.state.ended {
      self.finish(true)
      return Ok(0)
    }
    match self.pull() {
      Ok(_) => ()
      Err(err) => return Err(err)
    }
  }
  let available = self.pending.length() - self.pending_offset
  let take = if available < 8192 { available } else { 8192 }
  buf.write_bytes(self.pending.exact_view(
    start=self.pending_offset,
    end=self.pending_offset + take,
  ))
  self.pending_offset = self.pending_offset + take
  if self.state.ended && self.pending_offset >= self.pending.length() {
    self.finish(true)
  }
  Ok(take)
}

pub impl Stream for H2LiveBodyStream with fn set_body_limit(
  self : H2LiveBodyStream,
  max_body_bytes : Int,
) -> Unit {
  let limit = if max_body_bytes < 0 { 0 } else { max_body_bytes }
  if limit > self.state.max_body_bytes {
    self.state.max_body_bytes = limit
  }
}

pub impl Stream for H2LiveBodyStream with fn read_ready(
  self : H2LiveBodyStream,
) -> Bool {
  if !self.is_open || self.released_to_pool {
    return false
  }
  self.error is Some(_) ||
  self.pending_offset < self.pending.length() ||
  self.state.ended ||
  // A partial frame in the shared reader is not enough for a read to make
  // progress; the frame header and payload must both be buffered.
  h2_frame_is_buffered(self.connection.reader) ||
  self.connection.stream.read_ready()
}

pub impl Stream for H2LiveBodyStream with fn wait_readable(
  self : H2LiveBodyStream,
  timeout_ms : Int,
) -> Result[Bool, NetError] {
  if !self.is_open || self.released_to_pool {
    return Err(NetError::Closed)
  }
  if self.read_ready() {
    return Ok(true)
  }
  self.connection.stream.wait_readable(timeout_ms)
}

pub impl Stream for H2LiveBodyStream with fn write(
  self : H2LiveBodyStream,
  buf : Buffer,
) -> Result[Int, NetError] {
  let _ = buf
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Err(NetError::WriteError("HTTP/2 response body is read-only"))
}

pub impl Stream for H2LiveBodyStream with fn flush(
  self : H2LiveBodyStream,
) -> Result[Unit, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Ok(())
}

pub impl Stream for H2LiveBodyStream with fn close(
  self : H2LiveBodyStream,
) -> Result[Unit, NetError] {
  if !self.is_open {
    return Ok(())
  }
  self.is_open = false
  if !self.completed {
    let reusable = self.state.ended
    self.finish(reusable)
    if !reusable {
      self.connection.close()
    }
  }
  Ok(())
}

pub impl Stream for H2LiveBodyStream with fn set_timeout(
  self : H2LiveBodyStream,
  timeout_ms : Int,
) -> Result[Unit, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  if self.released_to_pool {
    return Ok(())
  }
  self.connection.stream.set_timeout(timeout_ms)
}

pub impl Stream for H2LiveBodyStream with fn peer_addr(
  self : H2LiveBodyStream,
) -> Result[String, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  if self.released_to_pool {
    return Err(NetError::Closed)
  }
  self.connection.stream.peer_addr()
}

pub impl Stream for H2LiveBodyStream with fn local_addr(
  self : H2LiveBodyStream,
) -> Result[String, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  if self.released_to_pool {
    return Err(NetError::Closed)
  }
  self.connection.stream.local_addr()
}

fn h2_tunnel_read_error(err : HttpError) -> NetError {
  match err {
    NetworkError(net) => net
    Timeout => Timeout
    ConnectionClosed => Closed
    ProtocolError(message) => NetError::ReadError(message)
    _ => NetError::IoError(@debug.to_string(err))
  }
}

/// Write failures on a tunnel must surface as write errors, even when the
/// underlying HTTP/2 framing layer reports a protocol problem (for example a
/// frame that cannot be encoded). Read and write directions share the same
/// transport but callers rely on the error direction to decide whether the
/// tunnel is still usable for reading.
fn h2_tunnel_write_error(err : HttpError) -> NetError {
  match err {
    NetworkError(net) => net
    Timeout => Timeout
    ConnectionClosed => Closed
    ProtocolError(message) => NetError::WriteError(message)
    _ => NetError::IoError(@debug.to_string(err))
  }
}

/// Streaming body for a successful HTTP/2 CONNECT tunnel. A tunnel's
/// END_STREAM may only arrive when the tunnelled peer closes, so the response
/// must be returned as soon as its headers are complete and further DATA
/// frames read on demand.
struct H2TunnelBody {
  connection : H2ClientConnection
  state : H2ResponseState
  flow : H2FlowState
  trailers : @ref.Ref[Headers]
  mut is_open : Bool
  mut on_close : (() -> Unit)?
  mut notified : Bool
}

fn H2TunnelBody::finish(self : H2TunnelBody) -> Unit {
  if self.notified {
    return
  }
  self.notified = true
  self.connection.streaming_busy = false
  let callback = self.on_close
  self.on_close = None
  match callback {
    Some(callback) => callback()
    None => ()
  }
  // A CONNECT stream is opaque, so the session cannot safely be reused for
  // another request even after the tunnel ends.
  self.connection.close()
}

fn H2TunnelBody::sync_trailers(self : H2TunnelBody) -> Unit {
  self.trailers.val = self.state.trailers
}

fn H2TunnelBody::advance(self : H2TunnelBody) -> Result[Unit, NetError] {
  let frame = match h2_read_connection_frame(self.connection.reader) {
    Ok(frame) => frame
    Err(err) => {
      self.finish()
      self.is_open = false
      return Err(h2_tunnel_read_error(err))
    }
  }
  match self.state.handle_frame(frame, self.flow, self.connection.stream) {
    Ok(_) => ()
    Err(err) => {
      self.finish()
      self.is_open = false
      return Err(h2_tunnel_read_error(err))
    }
  }
  self.sync_trailers()
  Ok(())
}

fn H2TunnelBody::drain_buffered(self : H2TunnelBody, buf : Buffer) -> Int {
  let data = self.state.body.to_bytes()
  if data.length() == 0 {
    return 0
  }
  let take = if data.length() < 8192 { data.length() } else { 8192 }
  buf.write_bytes(data.exact_view(start=0, end=take))
  let remaining = data.exact_view(start=take, end=data.length()).to_owned()
  let next = Buffer(size_hint=remaining.length())
  next.write_bytes(remaining)
  self.state.body = next
  if self.state.body.length() == 0 && self.state.ended {
    self.finish()
  }
  take
}

pub impl Stream for H2TunnelBody with fn read(
  self : H2TunnelBody,
  buf : Buffer,
) -> Result[Int, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  if self.state.body.length() > 0 {
    return Ok(self.drain_buffered(buf))
  }
  if self.state.ended {
    self.finish()
    return Ok(0)
  }
  while true {
    match self.advance() {
      Ok(_) => ()
      Err(err) => return Err(err)
    }
    if self.state.body.length() > 0 {
      return Ok(self.drain_buffered(buf))
    }
    if self.state.ended {
      self.finish()
      return Ok(0)
    }
  }
  Err(NetError::ReadError("HTTP/2 tunnel read did not converge"))
}

pub impl Stream for H2TunnelBody with fn read_ready(
  self : H2TunnelBody,
) -> Bool {
  if !self.is_open {
    return false
  }
  self.state.body.length() > 0 ||
  self.state.ended ||
  // Wait for a complete frame; consuming a partial one would block.
  h2_frame_is_buffered(self.connection.reader) ||
  self.connection.stream.read_ready()
}

pub impl Stream for H2TunnelBody with fn wait_readable(
  self : H2TunnelBody,
  timeout_ms : Int,
) -> Result[Bool, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  if self.read_ready() {
    return Ok(true)
  }
  self.connection.stream.wait_readable(timeout_ms)
}

pub impl Stream for H2TunnelBody with fn write(
  self : H2TunnelBody,
  buf : Buffer,
) -> Result[Int, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  if self.state.ended {
    self.finish()
    return Err(NetError::Closed)
  }
  let data = buf.to_bytes()
  if data.length() == 0 {
    return Ok(0)
  }
  let mut sent = 0
  while sent < data.length() {
    if self.state.ended {
      self.finish()
      return if sent > 0 { Ok(sent) } else { Err(NetError::Closed) }
    }
    let available = if self.flow.connection_send_window < self.flow.stream_send_window {
      self.flow.connection_send_window
    } else {
      self.flow.stream_send_window
    }
    if available <= 0 {
      match self.advance() {
        Ok(_) => ()
        Err(err) => return if sent > 0 { Ok(sent) } else { Err(err) }
      }
      continue
    }
    let remaining = data.length() - sent
    let frame_limit = h2_outbound_frame_limit(self.flow.peer_max_frame_size)
    let wanted = if remaining < available { remaining } else { available }
    let take = if wanted < frame_limit { wanted } else { frame_limit }
    match h2_write_frame(
      self.connection.stream,
      H2_FRAME_DATA,
      0,
      self.state.stream_id,
      data.exact_view(start=sent, end=sent + take).to_owned(),
    ) {
      Ok(_) => ()
      Err(err) => {
        self.finish()
        self.is_open = false
        return if sent > 0 { Ok(sent) } else { Err(h2_tunnel_write_error(err)) }
      }
    }
    match self.connection.stream.flush() {
      Ok(_) => ()
      Err(err) => {
        self.finish()
        self.is_open = false
        let mapped = h2_tunnel_write_error(http_error_from_net(err))
        return if sent > 0 { Ok(sent) } else { Err(mapped) }
      }
    }
    sent = sent + take
    self.flow.connection_send_window = self.flow.connection_send_window - take
    self.flow.stream_send_window = self.flow.stream_send_window - take
  }
  Ok(sent)
}

pub impl Stream for H2TunnelBody with fn flush(
  self : H2TunnelBody,
) -> Result[Unit, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  Ok(())
}

pub impl Stream for H2TunnelBody with fn close(
  self : H2TunnelBody,
) -> Result[Unit, NetError] {
  if !self.is_open {
    return Ok(())
  }
  self.is_open = false
  self.finish()
  Ok(())
}

pub impl Stream for H2TunnelBody with fn set_timeout(
  self : H2TunnelBody,
  timeout_ms : Int,
) -> Result[Unit, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  self.connection.stream.set_timeout(timeout_ms)
}

pub impl Stream for H2TunnelBody with fn peer_addr(
  self : H2TunnelBody,
) -> Result[String, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  self.connection.stream.peer_addr()
}

pub impl Stream for H2TunnelBody with fn local_addr(
  self : H2TunnelBody,
) -> Result[String, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  self.connection.stream.local_addr()
}

fn h2_make_tunnel_response(
  connection : H2ClientConnection,
  state : H2ResponseState,
  flow : H2FlowState,
  on_close : (() -> Unit)?,
) -> Response {
  let trailers = @ref.Ref(state.trailers)
  let body = H2TunnelBody::{
    connection,
    state,
    flow,
    trailers,
    is_open: true,
    on_close,
    notified: false,
  }
  let stream : &Stream = body
  Response::new_with_version(
    "HTTP/2",
    state.status,
    state.headers,
    stream,
  ).with_trailers(trailers).with_max_body_bytes(TUNNEL_BODY_LIMIT)
}

/// Consume connection-level frames that were already buffered when the
/// response ended. A GOAWAY or malformed trailing frame makes the session
/// unusable for another request; SETTINGS and PING are acknowledged.
fn H2ClientConnection::drain_buffered_connection_frames(
  self : H2ClientConnection,
  state : H2ResponseState,
  flow : H2FlowState,
) -> Result[Unit, HttpError] {
  while h2_frame_is_buffered(self.reader) {
    let header = self.reader.pending_offset
    let frame_length = (self.reader.pending[header].to_int() << 16) |
      (self.reader.pending[header + 1].to_int() << 8) |
      self.reader.pending[header + 2].to_int()
    // h2_frame_is_buffered treats an oversized header as available so the
    // error is noticed now. Reject it before the DATA/stream-id fast paths,
    // which could otherwise leave a future-stream frame buffered for reuse.
    if frame_length > H2_MAX_FRAME_SIZE {
      self.closed = true
      return Ok(())
    }
    let frame_type = self.reader.pending[self.reader.pending_offset + 3].to_int()
    match frame_type {
      H2_FRAME_SETTINGS
      | H2_FRAME_PING
      | H2_FRAME_WINDOW_UPDATE
      | H2_FRAME_GOAWAY
      | H2_FRAME_PRIORITY => ()
      H2_FRAME_RST_STREAM => {
        let offset = self.reader.pending_offset
        let frame_stream_id = ((self.reader.pending[offset + 5].to_int() & 0x7f) << 24) |
          (self.reader.pending[offset + 6].to_int() << 16) |
          (self.reader.pending[offset + 7].to_int() << 8) |
          self.reader.pending[offset + 8].to_int()
        match h2_read_connection_frame(self.reader) {
          Ok(_) => ()
          Err(_) => {
            self.closed = true
            return Ok(())
          }
        }
        // After END_STREAM, the peer may still have a RST_STREAM in flight
        // before it processes the end of the response (RFC 9113 §5.1). Ignore
        // it for a client stream we already completed. An RST_STREAM for an
        // idle future stream, or for a server-push stream, is a protocol error.
        if h2_is_client_stream(frame_stream_id) &&
          frame_stream_id <= state.stream_id {
          continue
        }
        self.closed = true
        return Ok(())
      }
      H2_FRAME_DATA => {
        let offset = self.reader.pending_offset
        let frame_stream_id = ((self.reader.pending[offset + 5].to_int() & 0x7f) << 24) |
          (self.reader.pending[offset + 6].to_int() << 16) |
          (self.reader.pending[offset + 7].to_int() << 8) |
          self.reader.pending[offset + 8].to_int()
        if !h2_is_client_stream(frame_stream_id) {
          // Push was disabled, so even stream identifiers cannot belong to a
          // legitimate response, past or future.
          self.closed = true
          return Ok(())
        }
        if frame_stream_id > state.stream_id {
          // Leave a frame for a future stream buffered for the next request.
          return Ok(())
        }
        let frame = match h2_read_connection_frame(self.reader) {
          Ok(frame) => frame
          Err(_) => {
            self.closed = true
            return Ok(())
          }
        }
        match h2_data_payload(frame) {
          Ok(_) => ()
          Err(err) => {
            self.closed = true
            return Err(err)
          }
        }
        // The stream has already ended (or was reset); discard its payload
        // but keep the connection-level receive window open.
        if frame.payload.length() > 0 {
          match h2_send_window_update(self.stream, 0, frame.payload.length()) {
            Ok(_) => ()
            Err(_) => {
              self.closed = true
              return Ok(())
            }
          }
        }
        continue
      }
      _ => {
        // Unknown extension frame types must be ignored and discarded
        // (RFC 9113 §4.1); they carry no stream state we need to preserve.
        if frame_type > H2_FRAME_CONTINUATION {
          match h2_read_connection_frame(self.reader) {
            Ok(_) => ()
            Err(_) => {
              self.closed = true
              return Ok(())
            }
          }
          continue
        }
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
        return Ok(())
      }
    }
    let frame = match h2_read_connection_frame(self.reader) {
      Ok(frame) => frame
      Err(_) => {
        self.closed = true
        return Ok(())
      }
    }
    match frame.frame_type {
      H2_FRAME_SETTINGS | H2_FRAME_PING | H2_FRAME_WINDOW_UPDATE =>
        match state.handle_frame(frame, flow, self.stream) {
          Ok(_) => ()
          Err(_) => {
            self.closed = true
            return Ok(())
          }
        }
      H2_FRAME_GOAWAY => {
        match h2_parse_goaway(frame.payload) {
          Ok((last_stream_id, _)) => state.goaway_last_stream_id = Some(last_stream_id)
          Err(_) => ()
        }
        self.closed = true
        return Ok(())
      }
      H2_FRAME_PRIORITY => ()
      _ => {
        self.closed = true
        return Ok(())
      }
    }
  }
  Ok(())
}

/// After resetting one stream, consume already-buffered frames that belong to
/// it so they cannot be mistaken for the next stream's response. Feeding them
/// through the response state keeps the HPACK dynamic table synchronized.
fn H2ClientConnection::discard_buffered_stream_frames(
  self : H2ClientConnection,
  state : H2ResponseState,
  flow : H2FlowState,
  stream_id : Int,
) -> Unit {
  while h2_frame_is_buffered(self.reader) {
    let offset = self.reader.pending_offset
    let frame_type = self.reader.pending[offset + 3].to_int()
    let frame_stream_id = ((self.reader.pending[offset + 5].to_int() & 0x7f) << 24) |
      (self.reader.pending[offset + 6].to_int() << 16) |
      (self.reader.pending[offset + 7].to_int() << 8) |
      self.reader.pending[offset + 8].to_int()
    if frame_stream_id != stream_id {
      return
    }
    let frame = match h2_read_connection_frame(self.reader) {
      Ok(frame) => frame
      Err(_) => {
        self.closed = true
        return
      }
    }
    match state.handle_frame(frame, flow, self.stream) {
      Ok(_) => ()
      Err(_) => {
        // Header blocks that fail to decode can leave HPACK state unusable.
        if frame.frame_type == H2_FRAME_HEADERS ||
          frame.frame_type == H2_FRAME_CONTINUATION {
          self.closed = true
          return
        }
      }
    }
    let _ = frame_type
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
    let frame = match h2_read_connection_frame(self.reader) {
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
    // A received GOAWAY forbids opening any further stream on this connection
    // (RFC 9113 §6.8), regardless of the last-stream-id it advertises. Let the
    // frame be consumed below so the request fails and can be retried on a
    // fresh connection instead of writing HEADERS onto a closing session.
    match frame_type {
      H2_FRAME_SETTINGS
      | H2_FRAME_PING
      | H2_FRAME_PRIORITY
      | H2_FRAME_GOAWAY
      | H2_FRAME_WINDOW_UPDATE => ()
      _ => return Ok(())
    }
    let frame = match h2_read_connection_frame(self.reader) {
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
            if frame.stream_id != 0 &&
              err == ProtocolError("Invalid HTTP/2 WINDOW_UPDATE increment") {
              if frame.stream_id == self.next_stream_id {
                // The offending stream has not been opened yet. Treat this as
                // a stream error for that id, skip it, and keep the session
                // usable for the next stream.
                let skipped = H2ResponseState::new(
                  frame.stream_id,
                  self.decoder,
                  0,
                  false,
                  false,
                )
                self.discard_buffered_stream_frames(skipped, flow, frame.stream_id)
                self.next_stream_id = self.next_stream_id + 2
                // Any WINDOW_UPDATE credit buffered for the skipped stream
                // belonged to that stream, not to the next id. Carrying it
                // forward would let the next stream exceed the peer's window.
                flow.pending_stream_window = 0
                return Err(ProtocolError("HTTP/2 stream WINDOW_UPDATE increment is zero"))
              } else if frame.stream_id < self.next_stream_id {
                // The stream has already ended; the update has no effect.
                continue
              }
            }
            self.closed = true
            return Err(err)
          }
        }
        // A connection update applies immediately. An update for the stream
        // that is about to be opened must be remembered until its window is
        // initialized; other idle-stream updates are protocol errors. Updates
        // for already-closed streams are harmless.
        if frame.stream_id == 0 {
          if flow.connection_send_window > H2_MAX_WINDOW_SIZE - increment {
            self.closed = true
            return Err(ProtocolError("HTTP/2 connection window overflow"))
          }
          flow.connection_send_window = flow.connection_send_window + increment
        } else if frame.stream_id == self.next_stream_id {
          if flow.pending_stream_window > H2_MAX_WINDOW_SIZE - increment {
            self.closed = true
            return Err(ProtocolError("HTTP/2 stream window overflow"))
          }
          flow.pending_stream_window = flow.pending_stream_window + increment
        } else if frame.stream_id > self.next_stream_id {
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
          // No stream has been opened yet, so the request is guaranteed not to
          // have been processed. Keep the code in the message for diagnostics,
          // but use wording the client can recognise as safe to retry.
          return Err(ProtocolError(
            "HTTP/2 connection closed by GOAWAY before opening a stream (error " +
            error_code.to_string() +
            ")",
          ))
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
  self.request_with_limit_and_callback(request, max_body_bytes, None)
}

/// Start an HTTP/2 exchange whose response body is read lazily from the
/// connection instead of being buffered before `request` returns.
///
/// Requests that need to send content, trailers, CONNECT, or an extended
/// CONNECT keep the fully buffered behavior: those exchanges already have to
/// read response frames while uploading, so returning a lazy body would make
/// the ownership rules ambiguous. For ordinary bodyless requests (the common
/// download path) the response head is returned as soon as it arrives and
/// DATA frames are consumed only as the caller reads the body.
pub fn H2ClientConnection::request_streaming(
  self : H2ClientConnection,
  request : Request,
) -> Result[Response, HttpError] {
  self.request_streaming_with_limit(request, DEFAULT_MAX_BODY_BYTES)
}

/// Like `request_streaming`, but bound the response body at `max_body_bytes`.
pub fn H2ClientConnection::request_streaming_with_limit(
  self : H2ClientConnection,
  request : Request,
  max_body_bytes : Int,
) -> Result[Response, HttpError] {
  self.request_streaming_with_callback(request, max_body_bytes, None)
}

fn H2ClientConnection::request_streaming_with_callback(
  self : H2ClientConnection,
  request : Request,
  max_body_bytes : Int,
  on_complete : ((Bool) -> Unit)?,
) -> Result[Response, HttpError] {
  if self.streaming_busy {
    return Err(ProtocolError("HTTP/2 connection has an outstanding streaming body"))
  }
  if !self.is_open() {
    return Err(ConnectionClosed)
  }
  let resolved_method = canonical_http_method(request.method)
  let body_length = match request.body {
    Some(body) => body.length()
    None => 0
  }
  // Content uploads and tunnels interleave request and response frames. Keep
  // the well-tested buffered exchange for those cases.
  if body_length > 0 || request.trailers.length() > 0 ||
    resolved_method == CONNECT || request_requests_upgrade(request.headers) {
    let tunnel = resolved_method == CONNECT ||
      request_requests_upgrade(request.headers)
    if tunnel {
      let tunnel_completion : (() -> Unit)? = match on_complete {
        Some(callback) => Some(fn() { callback(false) })
        None => None
      }
      return self.request_with_limit_and_callback(
        request,
        max_body_bytes,
        tunnel_completion,
      )
    }
    // A buffered exchange is complete when it returns, so hand ownership back
    // before the caller sees the response.
    return match self.request_with_limit_and_callback(
      request,
      max_body_bytes,
      None,
    ) {
      Ok(response) => {
        match on_complete {
          Some(callback) => callback(true)
          None => ()
        }
        Ok(response)
      }
      Err(err) => Err(err)
    }
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
  // A request with an `Upgrade` field but no offer is still validated by the
  // normal header builder below. An actual upgrade was routed to the buffered
  // path above.
  if headers_have_token(request.headers, "Connection", "upgrade") &&
    request.headers.contains("Upgrade") {
    return Err(InvalidHeader("Upgrade"))
  }
  let headers = match h2_request_headers_with_protocol(request, None) {
    Ok(headers) => headers
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
  if self.flow.peer_initial_window >
    H2_MAX_WINDOW_SIZE - self.flow.pending_stream_window {
    self.closed = true
    return Err(ProtocolError("HTTP/2 stream window overflow"))
  }
  self.flow.stream_send_window = self.flow.peer_initial_window +
    self.flow.pending_stream_window
  self.flow.pending_stream_window = 0
  let block = hpack_encode(headers)
  match h2_write_header_block(self.stream, stream_id, block, true) {
    Ok(_) => ()
    Err(err) => {
      self.closed = true
      return Err(err)
    }
  }
  self.next_stream_id = stream_id + 2
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
    resolved_method == HEAD,
    false,
  )
  // Read only until the final response head is available. Any DATA frames the
  // peer already sent stay buffered by the lazily-read body stream.
  while !state.status_seen && !state.ended {
    let frame = match h2_read_connection_frame(self.reader) {
      Ok(frame) => frame
      Err(err) => {
        self.closed = true
        return Err(err)
      }
    }
    match state.handle_frame(frame, self.flow, self.stream) {
      Ok(_) => ()
      Err(err) => {
        if h2_error_is_stream_reset(err) {
          self.discard_buffered_stream_frames(state, self.flow, state.stream_id)
        } else {
          self.closed = true
        }
        return Err(err)
      }
    }
  }
  if !state.status_seen {
    self.closed = true
    return Err(ProtocolError("HTTP/2 response ended before a status"))
  }
  let trailers = @ref.Ref(state.trailers)
  self.streaming_busy = true
  let external_completion = on_complete
  let completion : ((Bool) -> Unit)? = Some(fn(reusable) {
    self.streaming_busy = false
    match external_completion {
      Some(callback) => callback(reusable)
      None => ()
    }
  })
  // A bodyless response (HEAD, 204, or an empty END_STREAM after the final
  // headers) has nothing left to read. Complete it immediately so the
  // session is not left marked streaming until the caller happens to read or
  // close the empty body; the returned stream still reads as EOF.
  let bodyless = state.ended && state.body.length() == 0
  let body = H2LiveBodyStream::{
    connection: self,
    state,
    flow: self.flow,
    trailers,
    pending: b"",
    pending_offset: 0,
    is_open: true,
    completed: false,
    released_to_pool: false,
    error: None,
    on_complete: completion,
  }
  if bodyless {
    body.finish(true)
  }
  let response = Response::new_with_version(
    "HTTP/2",
    state.status,
    state.headers,
    body,
  )
  Ok(
    response
    .with_trailers(trailers)
    .with_max_body_bytes(state.max_body_bytes),
  )
}

/// Like `request_with_limit`, but a successful CONNECT tunnel owns the
/// connection until its streaming body is exhausted or closed. `on_close` is
/// invoked exactly once when that happens.
fn H2ClientConnection::request_with_limit_and_callback(
  self : H2ClientConnection,
  request : Request,
  max_body_bytes : Int,
  connect_completion : (() -> Unit)?,
) -> Result[Response, HttpError] {
  if self.streaming_busy {
    return Err(ProtocolError("HTTP/2 connection has an outstanding streaming body"))
  }
  if !self.is_open() {
    return Err(ConnectionClosed)
  }
  let trailer_fields = match h2_request_trailer_fields(request.trailers) {
    Ok(fields) => fields
    Err(err) => return Err(err)
  }
  let has_trailers = trailer_fields.length() > 0
  // The peer's SETTINGS decide whether an Upgrade request can be expressed as
  // an extended CONNECT, so they must be applied before the field list is
  // built.
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
  let upgrade_protocol = h2_upgrade_protocol(request)
  if upgrade_protocol is None &&
    headers_have_token(request.headers, "Connection", "upgrade") &&
    request.headers.contains("Upgrade") {
    // HTTP/2 cannot forward the HTTP/1 Upgrade field and silently dropping an
    // unexpressible protocol would change the request semantics. Match the
    // HTTP/1 wire-boundary validation instead.
    return Err(InvalidHeader("Upgrade"))
  }
  let extended_protocol = match upgrade_protocol {
    Some(protocol) => {
      if !self.flow.peer_enable_connect_protocol {
        return Err(
          ProtocolError("HTTP/2 server did not enable extended CONNECT"),
        )
      }
      Some(protocol)
    }
    None => None
  }
  let resolved_method = canonical_http_method(request.method)
  let tunnel = resolved_method == CONNECT || extended_protocol is Some(_)
  let headers = match h2_request_headers_with_protocol(request, extended_protocol) {
    Ok(headers) => headers
    Err(err) => return Err(err)
  }
  if self.flow.peer_max_concurrent_streams < 1 {
    return Err(ProtocolError("HTTP/2 max concurrent streams is zero"))
  }
  if h2_header_list_size(headers) > self.flow.peer_max_header_list_size {
    return Err(ProtocolError("HTTP/2 request header list too large"))
  }
  if has_trailers &&
    h2_header_list_size(trailer_fields) > self.flow.peer_max_header_list_size {
    return Err(ProtocolError("HTTP/2 request trailer list too large"))
  }
  let stream_id = self.next_stream_id
  if stream_id < 1 || stream_id > H2_MAX_WINDOW_SIZE {
    self.closed = true
    return Err(ProtocolError("HTTP/2 stream id exhausted"))
  }
  let block = hpack_encode(headers)
  let trailer_block = if has_trailers {
    hpack_encode(trailer_fields)
  } else {
    b""
  }
  let body = match request.body {
    Some(body) => body
    None => b""
  }
  // A request with trailers must leave the stream open until the trailing
  // HEADERS frame is written, even when the body itself is empty. A CONNECT
  // request (including an RFC 8441 extended CONNECT) is different: after a 2xx
  // response the same stream carries the tunnelled bytes, so its request side
  // must stay open for later DATA frames even when there is no initial body.
  // Sending END_STREAM on the CONNECT HEADERS would make every subsequent
  // tunnel write a stream error.
  let end_stream = body.length() == 0 && !has_trailers && !tunnel
  // A new stream starts with the peer's current initial window plus any
  // WINDOW_UPDATE that arrived before the stream was opened.
  if self.flow.peer_initial_window >
    H2_MAX_WINDOW_SIZE - self.flow.pending_stream_window {
    self.closed = true
    return Err(ProtocolError("HTTP/2 stream window overflow"))
  }
  self.flow.stream_send_window = self.flow.peer_initial_window +
    self.flow.pending_stream_window
  self.flow.pending_stream_window = 0
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
    resolved_method == HEAD,
    tunnel,
  )
  let flow = self.flow
  let mut sent = 0
  let mut trailers_sent = !has_trailers
  while sent < body.length() && !state.ended {
    let available = if flow.connection_send_window < flow.stream_send_window {
      flow.connection_send_window
    } else {
      flow.stream_send_window
    }
    if available <= 0 {
      let frame = match h2_read_connection_frame(self.reader) {
        Ok(frame) => frame
        Err(err) => {
          self.closed = true
          return Err(err)
        }
      }
      match state.handle_frame(frame, flow, self.stream) {
        Ok(_) => ()
        Err(err) => {
          if h2_error_is_stream_reset(err) {
            self.discard_buffered_stream_frames(state, flow, state.stream_id)
          } else {
            self.closed = true
          }
          return Err(err)
        }
      }
      continue
    }
    let remaining = body.length() - sent
    let wanted = if available < remaining { available } else { remaining }
    let frame_limit = h2_outbound_frame_limit(flow.peer_max_frame_size)
    let take = if wanted < frame_limit { wanted } else { frame_limit }
    let last = sent + take == body.length()
    let flags = if last && !has_trailers { H2_FLAG_END_STREAM } else { 0 }
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

  if has_trailers && !state.ended {
    match h2_write_header_block(self.stream, stream_id, trailer_block, true) {
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
    trailers_sent = true
  }

  while !state.ended {
    let frame = match h2_read_connection_frame(self.reader) {
      Ok(frame) => frame
      Err(err) => {
        self.closed = true
        return Err(err)
      }
    }
    match state.handle_frame(frame, flow, self.stream) {
      Ok(_) => ()
      Err(err) => {
        if h2_error_is_stream_reset(err) {
          self.discard_buffered_stream_frames(state, flow, state.stream_id)
        } else {
          self.closed = true
        }
        return Err(err)
      }
    }
    if state.connect && state.status_seen &&
      state.status >= 200 && state.status < 300 {
      break
    }
  }
  if state.connect && state.status_seen &&
    state.status >= 200 && state.status < 300 {
    // A successful CONNECT response ends the HTTP exchange but not the
    // tunnel. Return as soon as the response head is complete so the caller
    // can exchange tunnelled bytes while the stream remains open. The tunnel
    // owns the connection until its body is closed or reaches EOF, so reject
    // overlapping exchanges instead of letting them consume tunnel DATA.
    self.streaming_busy = true
    return Ok(h2_make_tunnel_response(self, state, flow, connect_completion))
  }
  match self.drain_buffered_connection_frames(state, flow) {
    Ok(_) => ()
    Err(err) => {
      self.closed = true
      return Err(err)
    }
  }
  // An early final response (for example 413 or 401) leaves the request side
  // of this stream half-open. Reset the stream instead of returning the
  // connection to the pool with an unfinished upload. A failed CONNECT or
  // extended CONNECT is the same case: its request side was deliberately left
  // open for tunnel DATA, but no tunnel was established.
  let request_finished = sent == body.length() && trailers_sent && !tunnel
  if !request_finished && !self.closed {
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
  h2_request_with_limit_and_callback(stream, request, max_body_bytes, None)
}

fn h2_request_with_limit_and_callback(
  stream : &Stream,
  request : Request,
  max_body_bytes : Int,
  connect_completion : (() -> Unit)?,
) -> Result[Response, HttpError] {
  let connection = match H2ClientConnection::new(stream) {
    Ok(connection) => connection
    Err(err) => return Err(err)
  }
  connection.request_with_limit_and_callback(
    request,
    max_body_bytes,
    connect_completion,
  )
}

fn h2_request_streaming_with_callback(
  stream : &Stream,
  request : Request,
  max_body_bytes : Int,
  on_complete : ((Bool) -> Unit)?,
) -> Result[Response, HttpError] {
  let connection = match H2ClientConnection::new(stream) {
    Ok(connection) => connection
    Err(err) => return Err(err)
  }
  connection.request_streaming_with_callback(
    request,
    max_body_bytes,
    on_complete,
  )
}

/// Run HTTP/2 exchanges on this persistent connection through the common
/// `HttpClient` interface. Unlike the inherent `request` method, this keeps the
/// connection object so later requests can reuse its preface and HPACK state.
pub impl HttpClient for H2ClientConnection with fn request(
  self : H2ClientConnection,
  request : Request,
) -> Result[Response, HttpError] {
  self.request_with_limit(request, DEFAULT_MAX_BODY_BYTES)
}

/// Perform one HTTP/2 request over an ALPN-negotiated stream. The connection
/// must already have negotiated the `h2` protocol; the caller owns closing it.
pub fn h2_request(stream : &Stream, request : Request) -> Result[Response, HttpError] {
  h2_request_with_limit(stream, request, DEFAULT_MAX_BODY_BYTES)
}

/// Perform one HTTP/2 request whose response body is read lazily from `stream`.
/// This is the one-shot counterpart to `H2ClientConnection::request_streaming`
/// for callers that provide their own ALPN-negotiated stream. The returned
/// body owns the connection; close it when the body is no longer needed.
pub fn h2_request_streaming(
  stream : &Stream,
  request : Request,
) -> Result[Response, HttpError] {
  h2_request_streaming_with_limit(stream, request, DEFAULT_MAX_BODY_BYTES)
}

/// Like `h2_request_streaming`, but bound the lazily-read response body at
/// `max_body_bytes`. An explicit larger limit can still be authorized through
/// `Response::read_body_with_limit` before the first body byte is consumed.
pub fn h2_request_streaming_with_limit(
  stream : &Stream,
  request : Request,
  max_body_bytes : Int,
) -> Result[Response, HttpError] {
  let connection = match H2ClientConnection::new(stream) {
    Ok(connection) => connection
    Err(err) => return Err(err)
  }
  // This helper owns the connection. Close it once the body is finished or
  // discarded, including the buffered fallback used for uploads, and also when
  // the exchange fails before a body is returned.
  let completion : ((Bool) -> Unit)? = Some(fn(_reusable) {
    connection.close()
  })
  match connection.request_streaming_with_callback(
    request,
    max_body_bytes,
    completion,
  ) {
    Ok(response) => Ok(response)
    Err(err) => {
      connection.close()
      Err(err)
    }
  }
}
