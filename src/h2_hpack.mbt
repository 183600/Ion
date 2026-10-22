/// HPACK (RFC 7541) header compression used by HTTP/2.
///
/// The decoder implements the full header block grammar, dynamic table
/// updates, and Huffman-coded string literals. The encoder deliberately uses
/// only static-table references and literal representations without indexing,
/// which is valid for every peer and keeps per-connection encoder state small.

const HPACK_STATIC_SIZE : Int = 61
const HPACK_DEFAULT_TABLE_SIZE : Int = 4096
const HPACK_MAX_STRING_BYTES : Int = 65536
const HPACK_MAX_HEADER_LIST_BYTES : Int = 1048576
const HPACK_MAX_HEADERS : Int = 1000

let hpack_static : Array[(String, String)] = [
  (":authority", ""),
  (":method", "GET"),
  (":method", "POST"),
  (":path", "/"),
  (":path", "/index.html"),
  (":scheme", "http"),
  (":scheme", "https"),
  (":status", "200"),
  (":status", "204"),
  (":status", "206"),
  (":status", "304"),
  (":status", "400"),
  (":status", "404"),
  (":status", "500"),
  ("accept-charset", ""),
  ("accept-encoding", "gzip, deflate"),
  ("accept-language", ""),
  ("accept-ranges", ""),
  ("accept", ""),
  ("access-control-allow-origin", ""),
  ("age", ""),
  ("allow", ""),
  ("authorization", ""),
  ("cache-control", ""),
  ("content-disposition", ""),
  ("content-encoding", ""),
  ("content-language", ""),
  ("content-length", ""),
  ("content-location", ""),
  ("content-range", ""),
  ("content-type", ""),
  ("cookie", ""),
  ("date", ""),
  ("etag", ""),
  ("expect", ""),
  ("expires", ""),
  ("from", ""),
  ("host", ""),
  ("if-match", ""),
  ("if-modified-since", ""),
  ("if-none-match", ""),
  ("if-range", ""),
  ("if-unmodified-since", ""),
  ("last-modified", ""),
  ("link", ""),
  ("location", ""),
  ("max-forwards", ""),
  ("proxy-authenticate", ""),
  ("proxy-authorization", ""),
  ("range", ""),
  ("referer", ""),
  ("refresh", ""),
  ("retry-after", ""),
  ("server", ""),
  ("set-cookie", ""),
  ("strict-transport-security", ""),
  ("transfer-encoding", ""),
  ("user-agent", ""),
  ("vary", ""),
  ("via", ""),
  ("www-authenticate", ""),
]

let hpack_huffman_codes : Array[Int] = [
  8184, 8388568, 268435426, 268435427, 268435428, 268435429, 268435430, 268435431, 268435432, 16777194, 1073741820, 268435433,
  268435434, 1073741821, 268435435, 268435436, 268435437, 268435438, 268435439, 268435440, 268435441, 268435442, 1073741822, 268435443,
  268435444, 268435445, 268435446, 268435447, 268435448, 268435449, 268435450, 268435451, 20, 1016, 1017, 4090,
  8185, 21, 248, 2042, 1018, 1019, 249, 2043, 250, 22, 23, 24,
  0, 1, 2, 25, 26, 27, 28, 29, 30, 31, 92, 251,
  32764, 32, 4091, 1020, 8186, 33, 93, 94, 95, 96, 97, 98,
  99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110,
  111, 112, 113, 114, 252, 115, 253, 8187, 524272, 8188, 16380, 34,
  32765, 3, 35, 4, 36, 5, 37, 38, 39, 6, 116, 117,
  40, 41, 42, 7, 43, 118, 44, 8, 9, 45, 119, 120,
  121, 122, 123, 32766, 2044, 16381, 8189, 268435452, 1048550, 4194258, 1048551, 1048552,
  4194259, 4194260, 4194261, 8388569, 4194262, 8388570, 8388571, 8388572, 8388573, 8388574, 16777195, 8388575,
  16777196, 16777197, 4194263, 8388576, 16777198, 8388577, 8388578, 8388579, 8388580, 2097116, 4194264, 8388581,
  4194265, 8388582, 8388583, 16777199, 4194266, 2097117, 1048553, 4194267, 4194268, 8388584, 8388585, 2097118,
  8388586, 4194269, 4194270, 16777200, 2097119, 4194271, 8388587, 8388588, 2097120, 2097121, 4194272, 2097122,
  8388589, 4194273, 8388590, 8388591, 1048554, 4194274, 4194275, 4194276, 8388592, 4194277, 4194278, 8388593,
  67108832, 67108833, 1048555, 524273, 4194279, 8388594, 4194280, 33554412, 67108834, 67108835, 67108836, 134217694,
  134217695, 67108837, 16777201, 33554413, 524274, 2097123, 67108838, 134217696, 134217697, 67108839, 134217698, 16777202,
  2097124, 2097125, 67108840, 67108841, 268435453, 134217699, 134217700, 134217701, 1048556, 16777203, 1048557, 2097126,
  4194281, 2097127, 2097128, 8388595, 4194282, 4194283, 33554414, 33554415, 16777204, 16777205, 67108842, 8388596,
  67108843, 134217702, 67108844, 67108845, 134217703, 134217704, 134217705, 134217706, 134217707, 268435454, 134217708, 134217709,
  134217710, 134217711, 134217712, 67108846,
]

let hpack_huffman_lengths : Array[Int] = [
  13, 23, 28, 28, 28, 28, 28, 28, 28, 24, 30, 28,
  28, 30, 28, 28, 28, 28, 28, 28, 28, 28, 30, 28,
  28, 28, 28, 28, 28, 28, 28, 28, 6, 10, 10, 12,
  13, 6, 8, 11, 10, 10, 8, 11, 8, 6, 6, 6,
  5, 5, 5, 6, 6, 6, 6, 6, 6, 6, 7, 8,
  15, 6, 12, 10, 13, 6, 7, 7, 7, 7, 7, 7,
  7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
  7, 7, 7, 7, 8, 7, 8, 13, 19, 13, 14, 6,
  15, 5, 6, 5, 6, 5, 6, 6, 6, 5, 7, 7,
  6, 6, 6, 5, 6, 7, 6, 5, 5, 6, 7, 7,
  7, 7, 7, 15, 11, 14, 13, 28, 20, 22, 20, 20,
  22, 22, 22, 23, 22, 23, 23, 23, 23, 23, 24, 23,
  24, 24, 22, 23, 24, 23, 23, 23, 23, 21, 22, 23,
  22, 23, 23, 24, 22, 21, 20, 22, 22, 23, 23, 21,
  23, 22, 22, 24, 21, 22, 23, 23, 21, 21, 22, 21,
  23, 22, 23, 23, 20, 22, 22, 22, 23, 22, 22, 23,
  26, 26, 20, 19, 22, 23, 22, 25, 26, 26, 26, 27,
  27, 26, 24, 25, 19, 21, 26, 27, 27, 26, 27, 24,
  21, 21, 26, 26, 28, 27, 27, 27, 20, 24, 20, 21,
  22, 21, 21, 23, 22, 22, 25, 25, 24, 24, 26, 23,
  26, 27, 26, 26, 27, 27, 27, 27, 27, 28, 27, 27,
  27, 27, 27, 26,
]

fn hpack_static_exact(name : String, value : String) -> Int? {
  let mut index = 1
  for entry in hpack_static {
    let (entry_name, entry_value) = entry
    if entry_name == name && entry_value == value {
      return Some(index)
    }
    index = index + 1
  }
  None
}

fn hpack_static_name(name : String) -> Int? {
  let mut index = 1
  for entry in hpack_static {
    let (entry_name, _) = entry
    if entry_name == name {
      return Some(index)
    }
    index = index + 1
  }
  None
}

fn hpack_huffman_table() -> (Array[Array[Int]], Array[Int]) {
  let children : Array[Array[Int]] = [Array::make(256, -1)]
  let symbols : Array[Int] = [-1]
  let mut symbol = 0
  while symbol < 256 {
    let code = hpack_huffman_codes[symbol]
    let length = hpack_huffman_lengths[symbol]
    let mut node = 0
    let mut bit = length - 1
    while bit >= 0 {
      let direction = (code >> bit) & 1
      let mut next = children[node][direction]
      if next < 0 {
        next = children.length()
        children.push(Array::make(256, -1))
        symbols.push(-1)
        children[node][direction] = next
      }
      node = next
      bit = bit - 1
    }
    symbols[node] = symbol
    symbol = symbol + 1
  }
  (children, symbols)
}

fn hpack_huffman_decode(data : BytesView) -> Result[String, HttpError] {
  let (children, symbols) = hpack_huffman_table()
  let output = Buffer(size_hint=data.length() * 2)
  let mut node = 0
  let mut bits_since_symbol = 0
  let mut padding_ones = true
  for byte in data {
    let value = byte.to_int()
    let mut bit = 7
    while bit >= 0 {
      let direction = (value >> bit) & 1
      let next = children[node][direction]
      if next < 0 {
        return Err(ProtocolError("Invalid HPACK Huffman code"))
      }
      node = next
      if symbols[node] >= 0 {
        if output.length() >= HPACK_MAX_STRING_BYTES {
          return Err(ProtocolError("HPACK header string too large"))
        }
        output.write_byte(symbols[node].to_byte())
        node = 0
        bits_since_symbol = 0
        padding_ones = true
      } else {
        bits_since_symbol = bits_since_symbol + 1
        if direction != 1 {
          padding_ones = false
        }
      }
      bit = bit - 1
    }
  }
  if node != 0 {
    if bits_since_symbol > 7 || !padding_ones {
      return Err(ProtocolError("Invalid HPACK Huffman padding"))
    }
  }
  Ok(@utf8.decode_lossy(output.to_bytes()[:]))
}

fn hpack_read_integer(
  data : Bytes,
  offset : Int,
  prefix_bits : Int,
) -> Result[(Int, Int), HttpError] {
  if offset < 0 || offset >= data.length() {
    return Err(ProtocolError("Truncated HPACK integer"))
  }
  let mask = (1 << prefix_bits) - 1
  let first = data[offset].to_int()
  let mut value = first & mask
  let mut index = offset + 1
  if value < mask {
    return Ok((value, index))
  }
  let mut shift = 0
  while true {
    if index >= data.length() {
      return Err(ProtocolError("Truncated HPACK integer"))
    }
    let byte = data[index].to_int()
    index = index + 1
    if shift > 28 {
      return Err(ProtocolError("HPACK integer too large"))
    }
    value = value + ((byte & 0x7f) << shift)
    if (byte & 0x80) == 0 {
      break
    }
    shift = shift + 7
  }
  Ok((value, index))
}

fn hpack_read_string(data : Bytes, offset : Int) -> Result[(String, Int), HttpError] {
  if offset < 0 || offset >= data.length() {
    return Err(ProtocolError("Truncated HPACK string"))
  }
  let huffman = (data[offset].to_int() & 0x80) != 0
  let (length, start) = match hpack_read_integer(data, offset, 7) {
    Ok(value) => value
    Err(err) => return Err(err)
  }
  if length < 0 || length > data.length() - start {
    return Err(ProtocolError("Truncated HPACK string"))
  }
  let end = start + length
  if length > HPACK_MAX_STRING_BYTES {
    return Err(ProtocolError("HPACK header string too large"))
  }
  let raw = data.exact_view(start=start, end=end)
  if huffman {
    match hpack_huffman_decode(raw) {
      Ok(value) => Ok((value, end))
      Err(err) => Err(err)
    }
  } else {
    Ok((@utf8.decode_lossy(raw), end))
  }
}

/// Incremental HPACK decoder with a per-connection dynamic table.
pub struct HpackDecoder {
  mut dynamic : Array[(String, String)]
  mut size : Int
  mut max_size : Int
  allowed_max_size : Int
}

pub fn HpackDecoder::new() -> HpackDecoder {
  HpackDecoder::with_max_size(HPACK_DEFAULT_TABLE_SIZE)
}

pub fn HpackDecoder::with_max_size(max_size : Int) -> HpackDecoder {
  let max_size = if max_size < 0 { 0 } else { max_size }
  HpackDecoder::{
    dynamic: [],
    size: 0,
    max_size,
    allowed_max_size: max_size,
  }
}

fn HpackDecoder::find(self : HpackDecoder, index : Int) -> Result[(String, String), HttpError] {
  if index <= 0 {
    return Err(ProtocolError("Invalid HPACK index"))
  }
  if index <= HPACK_STATIC_SIZE {
    return Ok(hpack_static[index - 1])
  }
  let dynamic_index = index - HPACK_STATIC_SIZE - 1
  if dynamic_index < 0 || dynamic_index >= self.dynamic.length() {
    return Err(ProtocolError("Invalid HPACK dynamic index"))
  }
  Ok(self.dynamic[dynamic_index])
}

fn HpackDecoder::evict(self : HpackDecoder) -> Unit {
  while self.size > self.max_size && self.dynamic.length() > 0 {
    let last = self.dynamic[self.dynamic.length() - 1]
    let (name, value) = last
    self.size = self.size - hpack_entry_size(name, value)
    let _ = self.dynamic.pop()
  }
}

/// RFC 7541 §4.1 sizes a dynamic-table entry by the number of octets in the
/// UTF-8 encoding of its name and value. `String::length` counts UTF-16 code
/// units, which under-counts non-ASCII text and would let the table exceed
/// the peer's advertised size.
fn hpack_entry_size(name : String, value : String) -> Int {
  @utf8.encode(name).length() + @utf8.encode(value).length() + 32
}

fn HpackDecoder::add(self : HpackDecoder, name : String, value : String) -> Unit {
  let entry_size = hpack_entry_size(name, value)
  if entry_size > self.max_size {
    self.dynamic = []
    self.size = 0
    return
  }
  let updated : Array[(String, String)] = [(name, value)]
  for entry in self.dynamic {
    updated.push(entry)
  }
  self.dynamic = updated
  self.size = self.size + entry_size
  self.evict()
}

fn HpackDecoder::set_max_size(self : HpackDecoder, max_size : Int) -> Result[Unit, HttpError] {
  if max_size < 0 || max_size > self.allowed_max_size {
    return Err(ProtocolError("Invalid HPACK dynamic table size"))
  }
  self.max_size = max_size
  self.evict()
  Ok(())
}

/// Decode a complete HPACK header block. The decoder's dynamic table is
/// updated, so one instance must be kept per HTTP/2 connection.
pub fn HpackDecoder::decode(self : HpackDecoder, block : Bytes) -> Result[Array[(String, String)], HttpError] {
  let headers : Array[(String, String)] = []
  let mut offset = 0
  let mut total_size = 0
  let mut saw_field = false
  while offset < block.length() {
    let first = block[offset].to_int()
    if (first & 0x80) != 0 {
      let (index, next) = match hpack_read_integer(block, offset, 7) {
        Ok(value) => value
        Err(err) => return Err(err)
      }
      offset = next
      let (name, value) = match self.find(index) {
        Ok(entry) => entry
        Err(err) => return Err(err)
      }
      headers.push((name, value))
      total_size = total_size + hpack_entry_size(name, value)
      saw_field = true
    } else if (first & 0xc0) == 0x40 {
      let (name_index, next) = match hpack_read_integer(block, offset, 6) {
        Ok(value) => value
        Err(err) => return Err(err)
      }
      offset = next
      let name = if name_index == 0 {
        let (value, next) = match hpack_read_string(block, offset) {
          Ok(value) => value
          Err(err) => return Err(err)
        }
        offset = next
        value
      } else {
        let (value, _) = match self.find(name_index) {
          Ok(entry) => entry
          Err(err) => return Err(err)
        }
        value
      }
      let (value, next) = match hpack_read_string(block, offset) {
        Ok(value) => value
        Err(err) => return Err(err)
      }
      offset = next
      headers.push((name, value))
      total_size = total_size + hpack_entry_size(name, value)
      saw_field = true
      self.add(name, value)
    } else if (first & 0xf0) == 0x00 || (first & 0xf0) == 0x10 {
      let (name_index, next) = match hpack_read_integer(block, offset, 4) {
        Ok(value) => value
        Err(err) => return Err(err)
      }
      offset = next
      let name = if name_index == 0 {
        let (value, next) = match hpack_read_string(block, offset) {
          Ok(value) => value
          Err(err) => return Err(err)
        }
        offset = next
        value
      } else {
        let (value, _) = match self.find(name_index) {
          Ok(entry) => entry
          Err(err) => return Err(err)
        }
        value
      }
      let (value, next) = match hpack_read_string(block, offset) {
        Ok(value) => value
        Err(err) => return Err(err)
      }
      offset = next
      headers.push((name, value))
      total_size = total_size + hpack_entry_size(name, value)
      saw_field = true
    } else if (first & 0xe0) == 0x20 {
      if saw_field {
        return Err(ProtocolError("HPACK table size update after header field"))
      }
      let (size, next) = match hpack_read_integer(block, offset, 5) {
        Ok(value) => value
        Err(err) => return Err(err)
      }
      offset = next
      match self.set_max_size(size) {
        Ok(_) => ()
        Err(err) => return Err(err)
      }
    } else {
      return Err(ProtocolError("Invalid HPACK representation"))
    }
    if headers.length() > HPACK_MAX_HEADERS {
      return Err(ProtocolError("Too many HTTP/2 headers"))
    }
    if total_size > HPACK_MAX_HEADER_LIST_BYTES {
      return Err(ProtocolError("HTTP/2 header list too large"))
    }
  }
  Ok(headers)
}

fn hpack_write_integer(
  output : Buffer,
  prefix : Int,
  prefix_bits : Int,
  value : Int,
) -> Unit {
  let mask = (1 << prefix_bits) - 1
  if value < 0 {
    return
  }
  if value < mask {
    output.write_byte((prefix | value).to_byte())
    return
  }
  output.write_byte((prefix | mask).to_byte())
  let mut remaining = value - mask
  while remaining >= 128 {
    output.write_byte((0x80 | (remaining & 0x7f)).to_byte())
    remaining = remaining >> 7
  }
  output.write_byte(remaining.to_byte())
}

fn hpack_write_string(output : Buffer, value : String) -> Unit {
  let encoded = @utf8.encode(value)
  hpack_write_integer(output, 0, 7, encoded.length())
  output.write_bytes(encoded)
}

/// Encode one header field without adding it to a dynamic table.
pub fn hpack_encode_header(output : Buffer, name : String, value : String) -> Unit {
  let name = name.to_lower()
  match hpack_static_exact(name, value) {
    Some(index) => hpack_write_integer(output, 0x80, 7, index)
    None =>
      match hpack_static_name(name) {
        Some(index) => {
          hpack_write_integer(output, 0x00, 4, index)
          hpack_write_string(output, value)
        }
        None => {
          hpack_write_integer(output, 0x00, 4, 0)
          hpack_write_string(output, name)
          hpack_write_string(output, value)
        }
      }
  }
}

/// Encode a list of header fields into one HPACK header block.
pub fn hpack_encode(headers : Array[(String, String)]) -> Bytes {
  let output = Buffer(size_hint=256)
  for header in headers {
    let (name, value) = header
    hpack_encode_header(output, name, value)
  }
  output.to_bytes()
}
