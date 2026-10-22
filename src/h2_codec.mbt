/// HTTP/2 framing (RFC 9113) shared by the client connection implementation.

const H2_FRAME_DATA : Int = 0
const H2_FRAME_HEADERS : Int = 1
const H2_FRAME_PRIORITY : Int = 2
const H2_FRAME_RST_STREAM : Int = 3
const H2_FRAME_SETTINGS : Int = 4
const H2_FRAME_PUSH_PROMISE : Int = 5
const H2_FRAME_PING : Int = 6
const H2_FRAME_GOAWAY : Int = 7
const H2_FRAME_WINDOW_UPDATE : Int = 8
const H2_FRAME_CONTINUATION : Int = 9

const H2_FLAG_END_STREAM : Int = 0x1
const H2_FLAG_ACK : Int = 0x1
const H2_FLAG_END_HEADERS : Int = 0x4
const H2_FLAG_PADDED : Int = 0x8
const H2_FLAG_PRIORITY : Int = 0x20

const H2_SETTINGS_ENABLE_PUSH : Int = 0x2
const H2_SETTINGS_INITIAL_WINDOW_SIZE : Int = 0x4
const H2_SETTINGS_MAX_FRAME_SIZE : Int = 0x5
const H2_SETTINGS_MAX_HEADER_LIST_SIZE : Int = 0x6

const H2_MAX_FRAME_SIZE : Int = 16384
const H2_MAX_FRAME_SIZE_LIMIT : Int = 16777215
const H2_DEFAULT_WINDOW_SIZE : Int = 65535
const H2_MAX_WINDOW_SIZE : Int = 2147483647
const H2_PREFACE : String = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

let h2_preface_bytes : Bytes = @utf8.encode(H2_PREFACE)

struct H2Frame {
  frame_type : Int
  flags : Int
  stream_id : Int
  payload : Bytes
}

fn h2_priority_dependency(payload : Bytes, offset : Int) -> Int {
  ((payload[offset].to_int() & 0x7f) << 24) |
  (payload[offset + 1].to_int() << 16) |
  (payload[offset + 2].to_int() << 8) |
  payload[offset + 3].to_int()
}

fn h2_parse_window_update(payload : Bytes) -> Result[Int, HttpError] {
  if payload.length() != 4 {
    return Err(ProtocolError("Invalid HTTP/2 WINDOW_UPDATE length"))
  }
  let increment = ((payload[0].to_int() & 0x7f) << 24) |
    (payload[1].to_int() << 16) |
    (payload[2].to_int() << 8) |
    payload[3].to_int()
  if increment <= 0 {
    return Err(ProtocolError("Invalid HTTP/2 WINDOW_UPDATE increment"))
  }
  Ok(increment)
}

/// Whether a whole frame is already buffered by the reader. Draining only
/// complete frames lets a completed response consume trailing connection
/// frames without blocking for more network input.
fn h2_frame_is_buffered(reader : StreamReader) -> Bool {
  let available = reader.pending.length() - reader.pending_offset
  if available < 9 {
    return false
  }
  let offset = reader.pending_offset
  let length = (reader.pending[offset].to_int() << 16) |
    (reader.pending[offset + 1].to_int() << 8) |
    reader.pending[offset + 2].to_int()
  available >= 9 + length
}

fn h2_read_frame(reader : StreamReader) -> Result[H2Frame, HttpError] {
  let header : Array[Byte] = []
  match reader.read_exact(9, header) {
    Ok(_) => ()
    Err(err) => return Err(http_error_from_net(err))
  }
  let length = (header[0].to_int() << 16) |
    (header[1].to_int() << 8) |
    header[2].to_int()
  if length > H2_MAX_FRAME_SIZE {
    return Err(ProtocolError("HTTP/2 frame exceeds advertised maximum"))
  }
  let frame_type = header[3].to_int()
  let flags = header[4].to_int()
  let stream_id = ((header[5].to_int() & 0x7f) << 24) |
    (header[6].to_int() << 16) |
    (header[7].to_int() << 8) |
    header[8].to_int()
  let payload_bytes : Array[Byte] = []
  match reader.read_exact(length, payload_bytes) {
    Ok(_) => ()
    Err(err) => return Err(http_error_from_net(err))
  }
  let payload = Bytes::from_array(payload_bytes[:])
  if frame_type == H2_FRAME_DATA && stream_id == 0 {
    return Err(ProtocolError("HTTP/2 DATA on stream 0"))
  }
  if (frame_type == H2_FRAME_HEADERS ||
    frame_type == H2_FRAME_PRIORITY ||
    frame_type == H2_FRAME_RST_STREAM ||
    frame_type == H2_FRAME_PUSH_PROMISE ||
    frame_type == H2_FRAME_CONTINUATION) && stream_id == 0 {
    return Err(ProtocolError("HTTP/2 stream frame on stream 0"))
  }
  if (frame_type == H2_FRAME_SETTINGS ||
    frame_type == H2_FRAME_PING ||
    frame_type == H2_FRAME_GOAWAY) && stream_id != 0 {
    return Err(ProtocolError("HTTP/2 connection frame on a stream"))
  }
  if frame_type == H2_FRAME_SETTINGS {
    if (flags & H2_FLAG_ACK) != 0 {
      if length != 0 {
        return Err(ProtocolError("Invalid HTTP/2 SETTINGS ACK length"))
      }
    } else if length % 6 != 0 {
      return Err(ProtocolError("Invalid HTTP/2 SETTINGS length"))
    }
  }
  if frame_type == H2_FRAME_PING && length != 8 {
    return Err(ProtocolError("Invalid HTTP/2 PING length"))
  }
  if frame_type == H2_FRAME_RST_STREAM && length != 4 {
    return Err(ProtocolError("Invalid HTTP/2 RST_STREAM length"))
  }
  if frame_type == H2_FRAME_WINDOW_UPDATE && length != 4 {
    return Err(ProtocolError("Invalid HTTP/2 WINDOW_UPDATE length"))
  }
  if frame_type == H2_FRAME_PRIORITY {
    if length != 5 {
      return Err(ProtocolError("Invalid HTTP/2 PRIORITY length"))
    }
    if h2_priority_dependency(payload, 0) == stream_id {
      return Err(ProtocolError("HTTP/2 stream cannot depend on itself"))
    }
  }
  if frame_type == H2_FRAME_GOAWAY && length < 8 {
    return Err(ProtocolError("Invalid HTTP/2 GOAWAY length"))
  }
  Ok(H2Frame::{ frame_type, flags, stream_id, payload })
}

fn h2_frame_bytes(
  frame_type : Int,
  flags : Int,
  stream_id : Int,
  payload : Bytes,
) -> Bytes {
  let output = Buffer(size_hint=9 + payload.length())
  let length = payload.length()
  output.write_byte(((length >> 16) & 0xff).to_byte())
  output.write_byte(((length >> 8) & 0xff).to_byte())
  output.write_byte((length & 0xff).to_byte())
  output.write_byte(frame_type.to_byte())
  output.write_byte(flags.to_byte())
  output.write_byte(((stream_id >> 24) & 0x7f).to_byte())
  output.write_byte(((stream_id >> 16) & 0xff).to_byte())
  output.write_byte(((stream_id >> 8) & 0xff).to_byte())
  output.write_byte((stream_id & 0xff).to_byte())
  output.write_bytes(payload)
  output.to_bytes()
}

fn h2_write_frame(
  stream : &Stream,
  frame_type : Int,
  flags : Int,
  stream_id : Int,
  payload : Bytes,
) -> Result[Unit, HttpError] {
  if payload.length() > H2_MAX_FRAME_SIZE {
    return Err(ProtocolError("HTTP/2 payload exceeds maximum frame size"))
  }
  match write_all(stream, h2_frame_bytes(frame_type, flags, stream_id, payload)) {
    Ok(_) => Ok(())
    Err(err) => Err(http_error_from_net(err))
  }
}

fn h2_settings_payload(entries : Array[(Int, Int)]) -> Bytes {
  let payload = Buffer(size_hint=entries.length() * 6)
  for entry in entries {
    let (identifier, value) = entry
    payload.write_byte(((identifier >> 8) & 0xff).to_byte())
    payload.write_byte((identifier & 0xff).to_byte())
    payload.write_byte(((value >> 24) & 0xff).to_byte())
    payload.write_byte(((value >> 16) & 0xff).to_byte())
    payload.write_byte(((value >> 8) & 0xff).to_byte())
    payload.write_byte((value & 0xff).to_byte())
  }
  payload.to_bytes()
}

fn h2_header_block_payload(frame : H2Frame) -> Result[Bytes, HttpError] {
  let mut start = 0
  let mut end = frame.payload.length()
  if (frame.flags & H2_FLAG_PADDED) != 0 {
    if frame.payload.length() == 0 {
      return Err(ProtocolError("Truncated padded HTTP/2 frame"))
    }
    let pad = frame.payload[0].to_int()
    if pad + 1 > frame.payload.length() {
      return Err(ProtocolError("Invalid HTTP/2 padding"))
    }
    start = 1
    end = end - pad
  }
  if (frame.flags & H2_FLAG_PRIORITY) != 0 {
    if start + 5 > end {
      return Err(ProtocolError("Truncated HTTP/2 priority fields"))
    }
    if h2_priority_dependency(frame.payload, start) == frame.stream_id {
      return Err(ProtocolError("HTTP/2 stream cannot depend on itself"))
    }
    start = start + 5
  }
  Ok(frame.payload.exact_view(start=start, end=end).to_owned())
}

fn h2_data_payload(frame : H2Frame) -> Result[Bytes, HttpError] {
  if (frame.flags & H2_FLAG_PADDED) == 0 {
    return Ok(frame.payload)
  }
  if frame.payload.length() == 0 {
    return Err(ProtocolError("Truncated padded HTTP/2 DATA frame"))
  }
  let pad = frame.payload[0].to_int()
  if pad + 1 > frame.payload.length() {
    return Err(ProtocolError("Invalid HTTP/2 DATA padding"))
  }
  Ok(
    frame.payload
    .exact_view(start=1, end=frame.payload.length() - pad)
    .to_owned(),
  )
}
