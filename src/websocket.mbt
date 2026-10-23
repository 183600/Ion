/// RFC 6455 WebSocket framing on top of a switched protocol stream.
///
/// The HTTP handshake is intentionally composable: `websocket_handshake_request`
/// builds the upgrade request (HTTP/1.1 `Upgrade` or RFC 8441 extended CONNECT),
/// and `websocket_connect` validates the resulting 101/2xx response. The
/// resulting `WebSocket` only owns the byte stream, so it works with direct
/// HTTP/1.1 upgrades, HTTP/2 extended CONNECT, and custom transports alike.

const WS_OPCODE_CONTINUATION : Int = 0
const WS_OPCODE_TEXT : Int = 1
const WS_OPCODE_BINARY : Int = 2
const WS_OPCODE_CLOSE : Int = 8
const WS_OPCODE_PING : Int = 9
const WS_OPCODE_PONG : Int = 10

const WS_DEFAULT_MAX_FRAME_BYTES : Int = 16777216
const WS_DEFAULT_MAX_MESSAGE_BYTES : Int = 67108864

/// Which endpoint this side of the connection is. Client frames are masked on
/// the wire; server frames must not be.
pub enum WebSocketRole {
  Client
  Server
} derive(Eq, Debug)

/// One decoded WebSocket message or control frame.
pub enum WebSocketMessage {
  Text(String)
  Binary(Bytes)
  Ping(Bytes)
  Pong(Bytes)
  /// Close status and UTF-8 reason. A close frame without a status code is
  /// represented as code 1005 and an empty reason.
  Close(Int, String)
} derive(Eq, Debug)

/// One WebSocket frame. `opcode` is the wire opcode (0, 1, 2, 8, 9, or 10).
pub struct WebSocketFrame {
  fin : Bool
  opcode : Int
  payload : Bytes
} derive(Eq, Debug)

pub fn WebSocketFrame::text(payload : String) -> WebSocketFrame {
  WebSocketFrame::{ fin: true, opcode: WS_OPCODE_TEXT, payload: @utf8.encode(payload) }
}

pub fn WebSocketFrame::binary(payload : Bytes) -> WebSocketFrame {
  WebSocketFrame::{ fin: true, opcode: WS_OPCODE_BINARY, payload }
}

pub fn WebSocketFrame::ping(payload : Bytes) -> WebSocketFrame {
  WebSocketFrame::{ fin: true, opcode: WS_OPCODE_PING, payload }
}

pub fn WebSocketFrame::pong(payload : Bytes) -> WebSocketFrame {
  WebSocketFrame::{ fin: true, opcode: WS_OPCODE_PONG, payload }
}

fn ws_is_control(opcode : Int) -> Bool {
  opcode >= WS_OPCODE_CLOSE
}

fn ws_valid_opcode(opcode : Int) -> Bool {
  opcode == WS_OPCODE_CONTINUATION || opcode == WS_OPCODE_TEXT ||
  opcode == WS_OPCODE_BINARY || opcode == WS_OPCODE_CLOSE ||
  opcode == WS_OPCODE_PING || opcode == WS_OPCODE_PONG
}

fn ws_valid_close_code(code : Int) -> Bool {
  (code >= 1000 && code <= 1003) ||
  (code >= 1007 && code <= 1014) ||
  (code >= 3000 && code <= 4999)
}

fn ws_rotl(value : Int64, bits : Int) -> Int64 {
  ((value << bits) | (value >> (32 - bits))) & 0xFFFFFFFFL
}

/// SHA-1 of the UTF-8 octets of `value`, returned as 20 bytes.
///
/// WebSocket's `Sec-WebSocket-Accept` value needs SHA-1, not a general-purpose
/// hash; keeping it here avoids a dependency on a native crypto library and
/// works on every MoonBit target.
fn ws_sha1(value : String) -> Bytes {
  let data = @utf8.encode(value)
  let padded = Buffer(size_hint=data.length() + 72)
  padded.write_bytes(data)
  padded.write_byte(b'\x80')
  while padded.length() % 64 != 56 {
    padded.write_byte(0)
  }
  let bit_length = data.length().to_int64() * 8L
  let mut shift = 56
  while shift >= 0 {
    padded.write_byte(((bit_length >> shift) & 0xFFL).to_int().to_byte())
    shift = shift - 8
  }

  let mut h0 = 0x67452301L
  let mut h1 = 0xEFCDAB89L
  let mut h2 = 0x98BADCFEL
  let mut h3 = 0x10325476L
  let mut h4 = 0xC3D2E1F0L
  let bytes = padded.to_bytes()
  let words = Array::make(80, 0L)
  let mut offset = 0
  while offset < bytes.length() {
    let mut index = 0
    while index < 16 {
      let position = offset + index * 4
      words[index] = (bytes[position].to_int().to_int64() << 24) |
        (bytes[position + 1].to_int().to_int64() << 16) |
        (bytes[position + 2].to_int().to_int64() << 8) |
        bytes[position + 3].to_int().to_int64()
      index = index + 1
    }
    index = 16
    while index < 80 {
      words[index] = ws_rotl(
        words[index - 3] ^ words[index - 8] ^ words[index - 14] ^
        words[index - 16],
        1,
      )
      index = index + 1
    }
    let mut a = h0
    let mut b = h1
    let mut c = h2
    let mut d = h3
    let mut e = h4
    index = 0
    while index < 80 {
      let (f, k) = if index < 20 {
        ((b & c) | ((b ^ 0xFFFFFFFFL) & d), 0x5A827999L)
      } else if index < 40 {
        (b ^ c ^ d, 0x6ED9EBA1L)
      } else if index < 60 {
        ((b & c) | (b & d) | (c & d), 0x8F1BBCDCL)
      } else {
        (b ^ c ^ d, 0xCA62C1D6L)
      }
      let temp = (ws_rotl(a, 5) + f + e + k + words[index]) & 0xFFFFFFFFL
      e = d
      d = c
      c = ws_rotl(b, 30)
      b = a
      a = temp
      index = index + 1
    }
    h0 = (h0 + a) & 0xFFFFFFFFL
    h1 = (h1 + b) & 0xFFFFFFFFL
    h2 = (h2 + c) & 0xFFFFFFFFL
    h3 = (h3 + d) & 0xFFFFFFFFL
    h4 = (h4 + e) & 0xFFFFFFFFL
    offset = offset + 64
  }

  let output = Buffer(size_hint=20)
  for word in [h0, h1, h2, h3, h4] {
    let mut shift = 24
    while shift >= 0 {
      output.write_byte(((word >> shift) & 0xFFL).to_int().to_byte())
      shift = shift - 8
    }
  }
  output.to_bytes()
}

/// Compute the `Sec-WebSocket-Accept` value for a client key.
pub fn websocket_accept_key(key : String) -> String {
  @base64.encode(ws_sha1(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
}

fn valid_websocket_key(key : String) -> Bool {
  // RFC 6455 only requires a non-empty base64 value. Keep the check at the
  // wire boundary so an empty key cannot produce a predictable accept value.
  key.length() > 0
}

/// Build the HTTP request that starts a WebSocket handshake. `url` must use
/// `ws`, `wss`, `http`, or `https`; the latter two are accepted so the same
/// function works with a `UnifiedClient` that already parsed the target.
pub fn websocket_handshake_request(
  url : String,
  key : String,
  protocols : Array[String],
) -> Result[Request, HttpError] {
  if !valid_websocket_key(key) {
    return Err(InvalidHeader("Sec-WebSocket-Key"))
  }
  let url = normalize_websocket_url(url)
  let url = match url {
    Ok(url) => url
    Err(err) => return Err(err)
  }
  let mut request = Request::new(GET, url)
    .with_upgrade("websocket")
    .with_header("Sec-WebSocket-Version", "13")
    .with_header("Sec-WebSocket-Key", key)
  if protocols.length() > 0 {
    request = request.with_header("Sec-WebSocket-Protocol", protocols.join(", "))
  }
  Ok(request)
}

fn normalize_websocket_url(value : String) -> Result[Url, HttpError] {
  let lower = value.to_lower()
  if lower.has_prefix("ws://") {
    return Url::parse("http://" + value[5:].to_owned())
  }
  if lower.has_prefix("wss://") {
    return Url::parse("https://" + value[6:].to_owned())
  }
  if lower.has_prefix("http://") || lower.has_prefix("https://") {
    return Url::parse(value)
  }
  Err(InvalidUrl("WebSocket URL must use ws, wss, http, or https"))
}

fn websocket_header_has_token(headers : Headers, name : String, token : String) -> Bool {
  let target = token.to_lower()
  for value in headers.get_all(name) {
    for part in split_header_list(value) {
      if part.trim().to_lower() == target {
        return true
      }
    }
  }
  false
}

/// Perform a WebSocket handshake through any `HttpClient` and return the
/// switched byte stream as a client-side `WebSocket`.
///
/// `key` must be a fresh, unpredictable base64 nonce (16 random bytes encoded
/// with standard base64) chosen by the caller. Keeping randomness out of this
/// library avoids silently using a weak in-process RNG for a value that peers
/// expect to be unpredictable.
pub fn websocket_connect(
  client : &HttpClient,
  url : String,
  key : String,
  protocols : Array[String],
) -> Result[WebSocket, HttpError] {
  let request = match websocket_handshake_request(url, key, protocols) {
    Ok(request) => request
    Err(err) => return Err(err)
  }
  let response = match client.request(request) {
    Ok(response) => response
    Err(err) => return Err(err)
  }
  let h1 = response.version.has_prefix("HTTP/1.")
  let status_ok = if h1 {
    response.status == 101
  } else {
    response.status >= 200 && response.status < 300
  }
  // HTTP/1.1 upgrades prove acceptance with Sec-WebSocket-Accept. RFC 8441
  // extended CONNECT on HTTP/2 does not use the key/accept exchange at all;
  // the successful 2xx status and the extended CONNECT itself are the proof.
  let accept_ok = if h1 {
    response.get_header("Sec-WebSocket-Accept") == Some(websocket_accept_key(key))
  } else {
    true
  }
  let upgrade_ok = !h1 ||
    (websocket_header_has_token(response.headers, "Upgrade", "websocket") &&
      websocket_header_has_token(response.headers, "Connection", "upgrade"))
  let selected = response.get_header("Sec-WebSocket-Protocol")
  // A server may decline to select a subprotocol, but anything it does select
  // must have been offered by the client (RFC 6455 section 4.2.2).
  let protocol_ok = match selected {
    Some(protocol) => protocols.contains(protocol)
    None => true
  }
  if !status_ok || !upgrade_ok || !accept_ok || !protocol_ok {
    response.close()
    return Err(ProtocolError("Invalid WebSocket handshake response"))
  }
  Ok(WebSocket::new(response.body, Client))
}

/// One WebSocket connection over an already-switched stream.
pub struct WebSocket {
  priv stream : &Stream
  priv role : WebSocketRole
  priv mut max_frame_bytes : Int
  priv mut max_message_bytes : Int
  priv mut pending : Bytes
  priv mut pending_offset : Int
  priv mut fragments : Buffer
  priv mut fragment_opcode : Int
  priv mut fragment_active : Bool
  priv mut mask_state : UInt64
  priv mut is_open : Bool
  priv mut close_sent : Bool
}

/// Wrap a switched stream. The caller is responsible for completing the HTTP
/// handshake first; `websocket_connect` does that when a `HttpClient` is used.
pub fn WebSocket::new(stream : &Stream, role : WebSocketRole) -> WebSocket {
  WebSocket::{
    stream,
    role,
    max_frame_bytes: WS_DEFAULT_MAX_FRAME_BYTES,
    max_message_bytes: WS_DEFAULT_MAX_MESSAGE_BYTES,
    pending: b"",
    pending_offset: 0,
    fragments: Buffer(size_hint=256),
    fragment_opcode: WS_OPCODE_TEXT,
    fragment_active: false,
    // Mix the clock into the initial mask state; the xorshift below keeps
    // successive masks distinct. Masking prevents cache poisoning rather than
    // providing confidentiality, so this does not depend on a CSPRNG.
    mask_state: @env.now(),
    is_open: true,
    close_sent: false,
  }
}

/// Wrap a stream as the client endpoint.
pub fn WebSocket::client(stream : &Stream) -> WebSocket {
  WebSocket::new(stream, Client)
}

/// Wrap a stream as the server endpoint (for tests, proxies, or server-side
/// MoonBit applications).
pub fn WebSocket::server(stream : &Stream) -> WebSocket {
  WebSocket::new(stream, Server)
}

pub fn WebSocket::with_max_frame_bytes(
  self : WebSocket,
  max_frame_bytes : Int,
) -> WebSocket {
  self.max_frame_bytes = if max_frame_bytes < 1 { 1 } else { max_frame_bytes }
  self
}

pub fn WebSocket::with_max_message_bytes(
  self : WebSocket,
  max_message_bytes : Int,
) -> WebSocket {
  self.max_message_bytes = if max_message_bytes < 1 { 1 } else { max_message_bytes }
  self
}

pub fn WebSocket::role(self : WebSocket) -> WebSocketRole {
  self.role
}

pub fn WebSocket::is_open(self : WebSocket) -> Bool {
  self.is_open
}

fn WebSocket::read_exact(
  self : WebSocket,
  length : Int,
) -> Result[Bytes, HttpError] {
  if length < 0 {
    return Err(ProtocolError("Invalid WebSocket read length"))
  }
  let output = Buffer(size_hint=length)
  while output.length() < length {
    if self.pending_offset < self.pending.length() {
      let available = self.pending.length() - self.pending_offset
      let remaining = length - output.length()
      let take = if available < remaining { available } else { remaining }
      output.write_bytes(self.pending.exact_view(
        start=self.pending_offset,
        end=self.pending_offset + take,
      ))
      self.pending_offset = self.pending_offset + take
      continue
    }
    self.pending = b""
    self.pending_offset = 0
    let chunk = Buffer(size_hint=4096)
    let count = match self.stream.read(chunk) {
      Ok(count) => count
      Err(err) => return Err(http_error_from_net(err))
    }
    if count < 0 {
      return Err(NetworkError(ReadError("invalid WebSocket read count")))
    }
    if count == 0 {
      return Err(ConnectionClosed)
    }
    let bytes = chunk.to_bytes()
    if bytes.length() == 0 {
      return Err(NetworkError(ReadError("WebSocket stream returned no data")))
    }
    self.pending = bytes
  }
  Ok(output.to_bytes())
}

fn WebSocket::next_mask(self : WebSocket) -> Bytes {
  let mut value = self.mask_state
  if value == 0UL {
    value = 0x9E3779B97F4A7C15UL
  }
  value = value ^ (value << 13)
  value = value ^ (value >> 7)
  value = value ^ (value << 17)
  self.mask_state = value
  let bytes = Buffer(size_hint=4)
  bytes.write_byte(((value >> 24) & 0xFFUL).to_int().to_byte())
  bytes.write_byte(((value >> 16) & 0xFFUL).to_int().to_byte())
  bytes.write_byte(((value >> 8) & 0xFFUL).to_int().to_byte())
  bytes.write_byte((value & 0xFFUL).to_int().to_byte())
  bytes.to_bytes()
}

fn ws_apply_mask(payload : Bytes, mask : Bytes) -> Bytes {
  let output = Buffer(size_hint=payload.length())
  let mut index = 0
  while index < payload.length() {
    output.write_byte(
      (payload[index].to_int() ^ mask[index % 4].to_int()).to_byte(),
    )
    index = index + 1
  }
  output.to_bytes()
}

fn ws_write_all(stream : &Stream, data : Bytes) -> Result[Unit, HttpError] {
  match write_all(stream, data) {
    Ok(_) => Ok(())
    Err(err) => Err(http_error_from_net(err))
  }
}

/// Encode and send one frame. Client frames are masked automatically.
pub fn WebSocket::send_frame(
  self : WebSocket,
  frame : WebSocketFrame,
) -> Result[Unit, HttpError] {
  if !self.is_open {
    return Err(ConnectionClosed)
  }
  // Once a Close frame has been sent, no further frames may be emitted on the
  // connection (RFC 6455 section 5.5.1). The peer's Close can still be read.
  if self.close_sent {
    return Err(ConnectionClosed)
  }
  if !ws_valid_opcode(frame.opcode) {
    return Err(InvalidHeader("WebSocket opcode"))
  }
  if ws_is_control(frame.opcode) &&
    (!frame.fin || frame.payload.length() > 125) {
    return Err(InvalidHeader("Invalid WebSocket control frame"))
  }
  if frame.payload.length() > self.max_frame_bytes {
    return Err(ProtocolError("WebSocket frame too large"))
  }
  let masked = self.role == Client
  let mask = if masked {
    self.next_mask()
  } else {
    b""
  }
  let payload = if masked {
    ws_apply_mask(frame.payload, mask)
  } else {
    frame.payload
  }
  let header = Buffer(size_hint=14)
  header.write_byte(
    ((if frame.fin { 0x80 } else { 0x00 }) | frame.opcode).to_byte(),
  )
  let length = payload.length()
  let mask_bit = if masked { 0x80 } else { 0x00 }
  if length <= 125 {
    header.write_byte((mask_bit | length).to_byte())
  } else if length <= 65535 {
    header.write_byte((mask_bit | 126).to_byte())
    header.write_byte(((length >> 8) & 0xFF).to_byte())
    header.write_byte((length & 0xFF).to_byte())
  } else {
    header.write_byte((mask_bit | 127).to_byte())
    let mut shift = 56
    while shift >= 0 {
      header.write_byte(((length.to_int64() >> shift) & 0xFFL).to_int().to_byte())
      shift = shift - 8
    }
  }
  if masked {
    header.write_bytes(mask)
  }
  let head = header.to_bytes()
  match ws_write_all(self.stream, head) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  if payload.length() > 0 {
    match ws_write_all(self.stream, payload) {
      Ok(_) => ()
      Err(err) => return Err(err)
    }
  }
  match self.stream.flush() {
    Ok(_) => Ok(())
    Err(err) => Err(http_error_from_net(err))
  }
}

pub fn WebSocket::send_text(
  self : WebSocket,
  text : String,
) -> Result[Unit, HttpError] {
  let payload = @utf8.encode(text)
  if payload.length() > self.max_message_bytes {
    return Err(ProtocolError("WebSocket message too large"))
  }
  self.send_frame(WebSocketFrame::{
    fin: true,
    opcode: WS_OPCODE_TEXT,
    payload,
  })
}

pub fn WebSocket::send_binary(
  self : WebSocket,
  data : Bytes,
) -> Result[Unit, HttpError] {
  if data.length() > self.max_message_bytes {
    return Err(ProtocolError("WebSocket message too large"))
  }
  self.send_frame(WebSocketFrame::binary(data))
}

pub fn WebSocket::send_ping(
  self : WebSocket,
  payload : Bytes,
) -> Result[Unit, HttpError] {
  if payload.length() > 125 {
    return Err(InvalidHeader("WebSocket ping payload too large"))
  }
  self.send_frame(WebSocketFrame::ping(payload))
}

pub fn WebSocket::send_pong(
  self : WebSocket,
  payload : Bytes,
) -> Result[Unit, HttpError] {
  if payload.length() > 125 {
    return Err(InvalidHeader("WebSocket pong payload too large"))
  }
  self.send_frame(WebSocketFrame::pong(payload))
}

/// Send a close frame. The reason is UTF-8 and, together with the two status
/// bytes, must fit in a control frame.
pub fn WebSocket::send_close(
  self : WebSocket,
  code : Int,
  reason : String,
) -> Result[Unit, HttpError] {
  if !ws_valid_close_code(code) {
    return Err(InvalidHeader("Invalid WebSocket close code"))
  }
  let reason_bytes = @utf8.encode(reason)
  if reason_bytes.length() > 123 {
    return Err(InvalidHeader("WebSocket close reason too long"))
  }
  let payload = Buffer(size_hint=2 + reason_bytes.length())
  payload.write_byte(((code >> 8) & 0xFF).to_byte())
  payload.write_byte((code & 0xFF).to_byte())
  payload.write_bytes(reason_bytes)
  match self.send_frame(WebSocketFrame::{
    fin: true,
    opcode: WS_OPCODE_CLOSE,
    payload: payload.to_bytes(),
  }) {
    Ok(_) => {
      self.close_sent = true
      Ok(())
    }
    Err(err) => Err(err)
  }
}

fn WebSocket::read_frame_unchecked(
  self : WebSocket,
) -> Result[WebSocketFrame, HttpError] {
  let head = match self.read_exact(2) {
    Ok(bytes) => bytes
    Err(err) => return Err(err)
  }
  let first = head[0].to_int()
  let second = head[1].to_int()
  let fin = (first & 0x80) != 0
  let opcode = first & 0x0F
  if (first & 0x70) != 0 {
    return Err(ProtocolError("WebSocket reserved bits are not supported"))
  }
  if !ws_valid_opcode(opcode) {
    return Err(ProtocolError("Invalid WebSocket opcode"))
  }
  let masked = (second & 0x80) != 0
  let length_marker = second & 0x7F
  let length : Int = if length_marker <= 125 {
    length_marker
  } else if length_marker == 126 {
    let extended = match self.read_exact(2) {
      Ok(bytes) => bytes
      Err(err) => return Err(err)
    }
    (extended[0].to_int() << 8) | extended[1].to_int()
  } else {
    let extended = match self.read_exact(8) {
      Ok(bytes) => bytes
      Err(err) => return Err(err)
    }
    if (extended[0].to_int() & 0x80) != 0 {
      return Err(ProtocolError("Invalid WebSocket frame length"))
    }
    let mut value : Int64 = 0L
    let mut index = 0
    while index < 8 {
      value = (value << 8) | extended[index].to_int().to_int64()
      index = index + 1
    }
    if value > self.max_frame_bytes.to_int64() {
      return Err(ProtocolError("WebSocket frame too large"))
    }
    value.to_int()
  }
  if length > self.max_frame_bytes {
    return Err(ProtocolError("WebSocket frame too large"))
  }
  if ws_is_control(opcode) && (!fin || length > 125) {
    return Err(ProtocolError("Invalid WebSocket control frame"))
  }
  let mask = if masked {
    match self.read_exact(4) {
      Ok(bytes) => bytes
      Err(err) => return Err(err)
    }
  } else {
    b""
  }
  let payload = if length == 0 {
    b""
  } else {
    match self.read_exact(length) {
      Ok(bytes) => bytes
      Err(err) => return Err(err)
    }
  }
  match self.role {
    Client =>
      if masked {
        return Err(ProtocolError("Server WebSocket frame must not be masked"))
      }
    Server =>
      if !masked {
        return Err(ProtocolError("Client WebSocket frame must be masked"))
      }
  }
  let payload = if masked {
    ws_apply_mask(payload, mask)
  } else {
    payload
  }
  Ok(WebSocketFrame::{ fin, opcode, payload })
}

/// Read one frame without interpreting fragmentation. Most callers should use
/// `read_message`, which assembles fragmented text/binary messages.
pub fn WebSocket::read_frame(
  self : WebSocket,
) -> Result[WebSocketFrame, HttpError] {
  if !self.is_open {
    return Err(ConnectionClosed)
  }
  self.read_frame_unchecked()
}

fn decode_websocket_message(
  opcode : Int,
  payload : Bytes,
) -> Result[WebSocketMessage, HttpError] {
  match opcode {
    WS_OPCODE_TEXT => {
      let text = try {
        @utf8.decode(payload[:])
      } catch {
        _ => return Err(ProtocolError("Invalid UTF-8 in WebSocket text message"))
      }
      Ok(Text(text))
    }
    WS_OPCODE_BINARY => Ok(Binary(payload))
    _ => Err(ProtocolError("Invalid WebSocket data opcode"))
  }
}

fn decode_close_message(payload : Bytes) -> Result[WebSocketMessage, HttpError] {
  if payload.length() == 0 {
    return Ok(Close(1005, ""))
  }
  if payload.length() == 1 {
    return Err(ProtocolError("Invalid WebSocket close payload"))
  }
  let code = (payload[0].to_int() << 8) | payload[1].to_int()
  if !ws_valid_close_code(code) {
    return Err(ProtocolError("Invalid WebSocket close code"))
  }
  let reason = try {
    @utf8.decode(payload.exact_view(start=2, end=payload.length()))
  } catch {
    _ => return Err(ProtocolError("Invalid UTF-8 in WebSocket close reason"))
  }
  Ok(Close(code, reason))
}

/// Read the next complete data message, returning control frames as they
/// arrive. Fragmented messages are reassembled; a Ping/Pong/Close received
/// between fragments is returned without discarding the partial message.
pub fn WebSocket::read_message(
  self : WebSocket,
) -> Result[WebSocketMessage, HttpError] {
  while true {
    let frame = match self.read_frame() {
      Ok(frame) => frame
      Err(err) => return Err(err)
    }
    match frame.opcode {
      WS_OPCODE_CONTINUATION =>
        if !self.fragment_active {
          return Err(ProtocolError("Unexpected WebSocket continuation"))
        } else {
          if frame.payload.length() >
            self.max_message_bytes - self.fragments.length() {
            return Err(ProtocolError("WebSocket message too large"))
          }
          self.fragments.write_bytes(frame.payload)
          if frame.fin {
            let opcode = self.fragment_opcode
            let payload = self.fragments.to_bytes()
            self.fragments = Buffer(size_hint=256)
            self.fragment_active = false
            return decode_websocket_message(opcode, payload)
          }
        }
      WS_OPCODE_TEXT | WS_OPCODE_BINARY =>
        if self.fragment_active {
          return Err(ProtocolError("Interleaved WebSocket data frames"))
        } else if frame.fin {
          if frame.payload.length() > self.max_message_bytes {
            return Err(ProtocolError("WebSocket message too large"))
          }
          return decode_websocket_message(frame.opcode, frame.payload)
        } else {
          if frame.payload.length() > self.max_message_bytes {
            return Err(ProtocolError("WebSocket message too large"))
          }
          self.fragments = Buffer(size_hint=frame.payload.length() + 64)
          self.fragments.write_bytes(frame.payload)
          self.fragment_opcode = frame.opcode
          self.fragment_active = true
        }
      WS_OPCODE_CLOSE => {
        let message = match decode_close_message(frame.payload) {
          Ok(message) => message
          Err(err) => return Err(err)
        }
        // Echo the peer's close (when we have not already sent one) and close
        // the transport. This completes the closing handshake without leaving
        // the socket open for later frames.
        if !self.close_sent {
          let _ = match self.send_frame(WebSocketFrame::{
            fin: true,
            opcode: WS_OPCODE_CLOSE,
            payload: frame.payload,
          }) {
            Ok(_) => Ok(())
            Err(err) => Err(err)
          }
          self.close_sent = true
        }
        self.is_open = false
        let _ = self.stream.close()
        return Ok(message)
      }
      WS_OPCODE_PING => return Ok(Ping(frame.payload))
      WS_OPCODE_PONG => return Ok(Pong(frame.payload))
      _ => return Err(ProtocolError("Invalid WebSocket opcode"))
    }
  }
  Err(ProtocolError("WebSocket read did not converge"))
}

/// Send a close frame (when one has not been sent yet) and close the
/// underlying stream. A close frame without a status is used because 1005 is
/// reserved and must never appear on the wire.
pub fn WebSocket::close(self : WebSocket) -> Result[Unit, HttpError] {
  if !self.is_open {
    return Ok(())
  }
  if !self.close_sent {
    let _ = self.send_frame(WebSocketFrame::{
      fin: true,
      opcode: WS_OPCODE_CLOSE,
      payload: b"",
    })
    self.close_sent = true
  }
  self.is_open = false
  match self.stream.close() {
    Ok(_) => Ok(())
    Err(err) => Err(http_error_from_net(err))
  }
}
