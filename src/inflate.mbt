/// Pure MoonBit DEFLATE (RFC 1951), zlib (RFC 1950) and gzip (RFC 1952)
/// decompression. Used to decode HTTP responses with a `Content-Encoding`
/// of `gzip` or `deflate` without pulling in a native zlib dependency.
///
/// This is a straightforward, allocation-light `inflate` implementation: it
/// handles stored, fixed-Huffman and dynamic-Huffman blocks, LZ77
/// back-references and the standard window size.

const INFLATE_MAX_BITS : Int = 15
const INFLATE_MAX_LIT_CODES : Int = 288
const INFLATE_MAX_DIST_CODES : Int = 32
const INFLATE_MAX_CL_CODES : Int = 19

let inflate_length_base : Array[Int] = [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67,
  83, 99, 115, 131, 163, 195, 227, 258,
]

let inflate_length_extra : Array[Int] = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5,
  5, 5, 0,
]

let inflate_dist_base : Array[Int] = [
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769,
  1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
]

let inflate_dist_extra : Array[Int] = [
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11,
  11, 12, 12, 13, 13,
]

let inflate_cl_order : Array[Int] = [
  16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
]

fn inflate_error(message : String) -> HttpError {
  ProtocolError("deflate: " + message)
}

struct BitReader {
  data : Bytes
  mut pos : Int
  mut bit_buf : Int
  mut bit_count : Int
}

fn BitReader::new(data : Bytes) -> BitReader {
  BitReader::{ data, pos: 0, bit_buf: 0, bit_count: 0 }
}

fn BitReader::bits(self : BitReader, count : Int) -> Result[Int, HttpError] {
  if count == 0 {
    return Ok(0)
  }
  while self.bit_count < count {
    if self.pos >= self.data.length() {
      return Err(inflate_error("unexpected end of input"))
    }
    self.bit_buf = self.bit_buf | (self.data[self.pos].to_int() << self.bit_count)
    self.pos = self.pos + 1
    self.bit_count = self.bit_count + 8
  }
  let value = self.bit_buf & ((1 << count) - 1)
  self.bit_buf = self.bit_buf >> count
  self.bit_count = self.bit_count - count
  Ok(value)
}

fn BitReader::align_byte(self : BitReader) -> Unit {
  let drop = self.bit_count % 8
  self.bit_buf = self.bit_buf >> drop
  self.bit_count = self.bit_count - drop
}

struct Huffman {
  counts : Array[Int]
  symbols : Array[Int]
  left : Int
  max_len : Int
}

/// Build a canonical Huffman decoding table from a list of code lengths.
fn Huffman::build(lengths : Array[Int], max_symbols : Int) -> Result[Huffman, HttpError] {
  let counts = Array::make(INFLATE_MAX_BITS + 1, 0)
  let mut i = 0
  while i < lengths.length() {
    let len = lengths[i]
    if len < 0 || len > INFLATE_MAX_BITS {
      return Err(inflate_error("invalid code length"))
    }
    counts[len] = counts[len] + 1
    i = i + 1
  }
  if counts[0] == lengths.length() {
    // No codes at all: only valid for the distance tree of a literal-only block.
    let symbols = Array::make(max_symbols, 0)
    return Ok(Huffman::{ counts, symbols, left: 0, max_len: 0 })
  }
  // Check for an over-subscribed or incomplete set of lengths. `left` is
  // reported to the caller so it can apply the DEFLATE rules for incomplete
  // literal/length, distance, and code-length trees.
  let mut left = 1
  let mut len = 1
  let mut max_len = 0
  while len <= INFLATE_MAX_BITS {
    if counts[len] > 0 {
      max_len = len
    }
    left = left << 1
    left = left - counts[len]
    if left < 0 {
      return Err(inflate_error("over-subscribed Huffman code"))
    }
    len = len + 1
  }
  // Generate offsets into symbol table for each length for sorting.
  let offsets = Array::make(INFLATE_MAX_BITS + 1, 0)
  let mut index = 0
  len = 1
  while len <= INFLATE_MAX_BITS {
    offsets[len] = index
    index = index + counts[len]
    len = len + 1
  }
  let symbols = Array::make(index, 0)
  i = 0
  while i < lengths.length() {
    let l = lengths[i]
    if l != 0 {
      symbols[offsets[l]] = i
      offsets[l] = offsets[l] + 1
    }
    i = i + 1
  }
  Ok(Huffman::{ counts, symbols, left, max_len })
}

/// Decode one symbol using the canonical code table (puff-style walk).
fn Huffman::decode(self : Huffman, br : BitReader) -> Result[Int, HttpError] {
  let mut code = 0
  let mut first = 0
  let mut index = 0
  let mut len = 1
  while len <= INFLATE_MAX_BITS {
    match br.bits(1) {
      Ok(bit) => code = code | bit
      Err(err) => return Err(err)
    }
    let count = self.counts[len]
    if code - count < first {
      return Ok(self.symbols[index + (code - first)])
    }
    index = index + count
    first = first + count
    first = first << 1
    code = code << 1
    len = len + 1
  }
  Err(inflate_error("invalid Huffman code"))
}

fn fixed_literal_table() -> Result[Huffman, HttpError] {
  let lengths = Array::make(INFLATE_MAX_LIT_CODES, 0)
  let mut i = 0
  while i < 144 {
    lengths[i] = 8
    i = i + 1
  }
  while i < 256 {
    lengths[i] = 9
    i = i + 1
  }
  while i < 280 {
    lengths[i] = 7
    i = i + 1
  }
  while i < INFLATE_MAX_LIT_CODES {
    lengths[i] = 8
    i = i + 1
  }
  Huffman::build(lengths, INFLATE_MAX_LIT_CODES)
}

fn fixed_distance_table() -> Result[Huffman, HttpError] {
  let lengths = Array::make(INFLATE_MAX_DIST_CODES, 5)
  Huffman::build(lengths, INFLATE_MAX_DIST_CODES)
}

fn read_dynamic_tables(
  br : BitReader,
) -> Result[(Huffman, Huffman), HttpError] {
  let hlit = match br.bits(5) {
    Ok(v) => v + 257
    Err(err) => return Err(err)
  }
  let hdist = match br.bits(5) {
    Ok(v) => v + 1
    Err(err) => return Err(err)
  }
  let hclen = match br.bits(4) {
    Ok(v) => v + 4
    Err(err) => return Err(err)
  }
  if hlit > INFLATE_MAX_LIT_CODES || hdist > INFLATE_MAX_DIST_CODES {
    return Err(inflate_error("invalid dynamic block header"))
  }
  let cl_lengths = Array::make(INFLATE_MAX_CL_CODES, 0)
  let mut i = 0
  while i < hclen {
    let code = match br.bits(3) {
      Ok(v) => v
      Err(err) => return Err(err)
    }
    cl_lengths[inflate_cl_order[i]] = code
    i = i + 1
  }
  let cl_table = match Huffman::build(cl_lengths, INFLATE_MAX_CL_CODES) {
    Ok(table) => table
    Err(err) => return Err(err)
  }
  // The code-length alphabet must be complete; an incomplete tree leaves some
  // bit patterns undecodable and is rejected by conforming inflaters.
  if cl_table.max_len == 0 || cl_table.left > 0 {
    return Err(inflate_error("incomplete code length Huffman code"))
  }
  let lengths = Array::make(hlit + hdist, 0)
  let mut index = 0
  while index < lengths.length() {
    let symbol = match cl_table.decode(br) {
      Ok(sym) => sym
      Err(err) => return Err(err)
    }
    if symbol < 16 {
      lengths[index] = symbol
      index = index + 1
    } else if symbol == 16 {
      if index == 0 {
        return Err(inflate_error("repeat with no previous length"))
      }
      let prev = lengths[index - 1]
      let repeat = match br.bits(2) {
        Ok(v) => v + 3
        Err(err) => return Err(err)
      }
      let mut n = 0
      while n < repeat {
        if index >= lengths.length() {
          return Err(inflate_error("code length repeat overflow"))
        }
        lengths[index] = prev
        index = index + 1
        n = n + 1
      }
    } else if symbol == 17 {
      let repeat = match br.bits(3) {
        Ok(v) => v + 3
        Err(err) => return Err(err)
      }
      let mut n = 0
      while n < repeat {
        if index >= lengths.length() {
          return Err(inflate_error("code length repeat overflow"))
        }
        lengths[index] = 0
        index = index + 1
        n = n + 1
      }
    } else {
      let repeat = match br.bits(7) {
        Ok(v) => v + 11
        Err(err) => return Err(err)
      }
      let mut n = 0
      while n < repeat {
        if index >= lengths.length() {
          return Err(inflate_error("code length repeat overflow"))
        }
        lengths[index] = 0
        index = index + 1
        n = n + 1
      }
    }
  }
  let lit_lengths = Array::make(hlit, 0)
  let mut j = 0
  while j < hlit {
    lit_lengths[j] = lengths[j]
    j = j + 1
  }
  let dist_lengths = Array::make(hdist, 0)
  j = 0
  while j < hdist {
    dist_lengths[j] = lengths[hlit + j]
    j = j + 1
  }
  let lit_table = match Huffman::build(lit_lengths, INFLATE_MAX_LIT_CODES) {
    Ok(table) => table
    Err(err) => return Err(err)
  }
  // A literal/length tree must contain at least the end-of-block symbol. An
  // incomplete tree is only legal when it consists of a single one-bit code
  // (RFC 1951 §3.2.7); otherwise some bit patterns have no valid symbol.
  if lit_table.max_len == 0 {
    return Err(inflate_error("missing literal/length Huffman codes"))
  }
  if lit_table.left > 0 && lit_table.max_len != 1 {
    return Err(inflate_error("incomplete literal/length Huffman code"))
  }
  let dist_table = match Huffman::build(dist_lengths, INFLATE_MAX_DIST_CODES) {
    Ok(table) => table
    Err(err) => return Err(err)
  }
  // No distance codes at all is fine for a literal-only block. A single
  // one-bit distance code is also allowed; any other incomplete distance tree
  // is invalid.
  if dist_table.left > 0 && dist_table.max_len != 1 {
    return Err(inflate_error("incomplete distance Huffman code"))
  }
  Ok((lit_table, dist_table))
}

fn inflate_codes(
  br : BitReader,
  out : Array[Byte],
  lit : Huffman,
  dist : Huffman,
  max_bytes : Int,
) -> Result[Unit, HttpError] {
  while true {
    let symbol = match lit.decode(br) {
      Ok(sym) => sym
      Err(err) => return Err(err)
    }
    if symbol < 256 {
      if out.length() >= max_bytes {
        return Err(inflate_error("output too large"))
      }
      out.push(symbol.to_byte())
    } else if symbol == 256 {
      return Ok(())
    } else {
      let length_index = symbol - 257
      if length_index >= inflate_length_base.length() {
        return Err(inflate_error("invalid length code"))
      }
      let length = inflate_length_base[length_index] +
        (match br.bits(inflate_length_extra[length_index]) {
          Ok(v) => v
          Err(err) => return Err(err)
        })
      let dist_symbol = match dist.decode(br) {
        Ok(sym) => sym
        Err(err) => return Err(err)
      }
      if dist_symbol >= inflate_dist_base.length() {
        return Err(inflate_error("invalid distance code"))
      }
      let distance = inflate_dist_base[dist_symbol] +
        (match br.bits(inflate_dist_extra[dist_symbol]) {
          Ok(v) => v
          Err(err) => return Err(err)
        })
      if distance <= 0 || distance > out.length() {
        return Err(inflate_error("distance too far back"))
      }
      if out.length() + length > max_bytes {
        return Err(inflate_error("output too large"))
      }
      let mut copied = 0
      while copied < length {
        let source = out.length() - distance
        let byte = out[source]
        out.push(byte)
        copied = copied + 1
      }
    }
  }
  Ok(())
}

fn inflate_stored(
  br : BitReader,
  out : Array[Byte],
  max_bytes : Int,
) -> Result[Unit, HttpError] {
  br.align_byte()
  let len = match br.bits(16) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let nlen = match br.bits(16) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  if (len ^ 0xFFFF) != nlen {
    return Err(inflate_error("stored length check failed"))
  }
  if out.length() + len > max_bytes {
    return Err(inflate_error("output too large"))
  }
  let mut i = 0
  while i < len {
    let byte = match br.bits(8) {
      Ok(v) => v
      Err(err) => return Err(err)
    }
    out.push(byte.to_byte())
    i = i + 1
  }
  Ok(())
}

/// Inflate a raw DEFLATE stream (no zlib/gzip wrapper) and report how many
/// input bytes were consumed. Decoding stops at the end of the final block, so
/// trailing bytes (e.g. the next gzip member) are left untouched.
fn inflate_raw_consume(data : Bytes, max_bytes : Int) -> Result[(Bytes, Int), HttpError] {
  let br = BitReader::new(data)
  let out = Array::make(0, b'\x00')
  let mut is_last = false
  while !is_last {
    let last = match br.bits(1) {
      Ok(v) => v
      Err(err) => return Err(err)
    }
    is_last = last == 1
    let block_type = match br.bits(2) {
      Ok(v) => v
      Err(err) => return Err(err)
    }
    if block_type == 0 {
      match inflate_stored(br, out, max_bytes) {
        Ok(_) => ()
        Err(err) => return Err(err)
      }
    } else if block_type == 1 {
      let lit = match fixed_literal_table() {
        Ok(table) => table
        Err(err) => return Err(err)
      }
      let dist = match fixed_distance_table() {
        Ok(table) => table
        Err(err) => return Err(err)
      }
      match inflate_codes(br, out, lit, dist, max_bytes) {
        Ok(_) => ()
        Err(err) => return Err(err)
      }
    } else if block_type == 2 {
      let (lit, dist) = match read_dynamic_tables(br) {
        Ok(tables) => tables
        Err(err) => return Err(err)
      }
      match inflate_codes(br, out, lit, dist, max_bytes) {
        Ok(_) => ()
        Err(err) => return Err(err)
      }
    } else {
      return Err(inflate_error("reserved block type"))
    }
  }
  // The stream ends on a byte boundary; any bits left in `bit_buf` are padding
  // within the last consumed byte, so `pos` is the first unread byte.
  Ok((@buffer.from_array(out[:]).to_bytes(), br.pos))
}

/// Inflate a raw DEFLATE stream (no zlib/gzip wrapper).
fn inflate_raw(data : Bytes, max_bytes : Int) -> Result[Bytes, HttpError] {
  match inflate_raw_consume(data, max_bytes) {
    Ok((bytes, _)) => Ok(bytes)
    Err(err) => Err(err)
  }
}

fn adler32(data : Bytes) -> Int {
  let mut a = 1
  let mut b = 0
  let mut i = 0
  while i < data.length() {
    a = (a + data[i].to_int()) % 65521
    b = (b + a) % 65521
    i = i + 1
  }
  (b << 16) | a
}

fn crc32(data : Bytes) -> Int {
  let mut crc = 0xFFFFFFFF
  let mut i = 0
  while i < data.length() {
    crc = crc ^ data[i].to_int()
    let mut bit = 0
    while bit < 8 {
      // Mask after shifting to emulate a logical (unsigned) right shift,
      // since `Int` is signed and `>>` sign-extends.
      if (crc & 1) == 1 {
        crc = ((crc >> 1) & 0x7FFFFFFF) ^ 0xEDB88320
      } else {
        crc = (crc >> 1) & 0x7FFFFFFF
      }
      bit = bit + 1
    }
    i = i + 1
  }
  crc ^ 0xFFFFFFFF
}

fn read_le32(data : Bytes, offset : Int) -> Int {
  let b0 = data[offset].to_int()
  let b1 = data[offset + 1].to_int()
  let b2 = data[offset + 2].to_int()
  let b3 = data[offset + 3].to_int()
  b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
}

fn read_be32(data : Bytes, offset : Int) -> Int {
  let b0 = data[offset].to_int()
  let b1 = data[offset + 1].to_int()
  let b2 = data[offset + 2].to_int()
  let b3 = data[offset + 3].to_int()
  (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
}

/// Decompress a zlib (RFC 1950) wrapped DEFLATE stream.
fn inflate_zlib(data : Bytes, max_bytes : Int) -> Result[Bytes, HttpError] {
  if data.length() < 2 {
    return Err(inflate_error("truncated zlib header"))
  }
  let cmf = data[0].to_int()
  let flg = data[1].to_int()
  if (cmf & 0x0F) != 8 {
    return Err(inflate_error("invalid zlib compression method"))
  }
  if (cmf >> 4) > 7 {
    return Err(inflate_error("invalid zlib window size"))
  }
  if ((cmf << 8) | flg) % 31 != 0 {
    return Err(inflate_error("invalid zlib header checksum"))
  }
  if (flg & 0x20) != 0 {
    return Err(inflate_error("preset dictionary is not supported"))
  }
  let body = data[2:].to_bytes()
  // The DEFLATE stream does not declare its length, so decode it and use the
  // number of consumed bytes to locate the 4-byte Adler-32 trailer. Reading it
  // from the end of the input would be wrong whenever trailing bytes follow the
  // zlib stream.
  let (inflated, consumed) = match inflate_raw_consume(body, max_bytes) {
    Ok(result) => result
    Err(err) => return Err(err)
  }
  let expected = adler32(inflated)
  if consumed + 4 > body.length() {
    return Err(inflate_error("missing zlib checksum"))
  }
  // The zlib Adler-32 trailer is stored big-endian (RFC 1950 §2.2).
  let stored = read_be32(body, consumed)
  if stored != expected {
    return Err(inflate_error("zlib checksum mismatch"))
  }
  Ok(inflated)
}

/// Decompress a gzip (RFC 1952) stream. A gzip payload may contain several
/// concatenated members (e.g. output of `cat a.gz b.gz`); each member is
/// verified against its own trailer and the decoded contents are concatenated.
fn inflate_gzip(data : Bytes, max_bytes : Int) -> Result[Bytes, HttpError] {
  let output = Array::make(0, b'\x00')
  let mut offset = 0
  let mut members = 0
  while offset < data.length() {
    if members > 0 && data[offset].to_int() == 0 {
      // Some producers pad the end of a gzip payload with zero bytes. Accept
      // all-zero padding, but never arbitrary non-zero trailing data.
      let mut padding = offset
      while padding < data.length() && data[padding].to_int() == 0 {
        padding = padding + 1
      }
      if padding == data.length() {
        offset = padding
        break
      }
    }
    if data.length() - offset < 18 {
      return Err(inflate_error("truncated gzip header"))
    }
    if data[offset].to_int() != 0x1F || data[offset + 1].to_int() != 0x8B {
      return Err(inflate_error("invalid gzip magic"))
    }
    if data[offset + 2].to_int() != 8 {
      return Err(inflate_error("unsupported gzip compression method"))
    }
    let flags = data[offset + 3].to_int()
    if (flags & 0xE0) != 0 {
      return Err(inflate_error("reserved gzip flags set"))
    }
    let header_start = offset
    let mut cursor = offset + 10
    if (flags & 0x04) != 0 {
      // FEXTRA
      if cursor + 2 > data.length() {
        return Err(inflate_error("truncated gzip extra field"))
      }
      let xlen = data[cursor].to_int() | (data[cursor + 1].to_int() << 8)
      cursor = cursor + 2 + xlen
    }
    if (flags & 0x08) != 0 {
      // FNAME
      cursor = skip_cstring(data, cursor)
    }
    if (flags & 0x10) != 0 {
      // FCOMMENT
      cursor = skip_cstring(data, cursor)
    }
    if (flags & 0x02) != 0 {
      // FHCRC
      if cursor + 2 > data.length() {
        return Err(inflate_error("truncated gzip header CRC"))
      }
      let stored_header_crc = data[cursor].to_int() | (data[cursor + 1].to_int() << 8)
      let computed_header_crc = crc32(data[header_start:cursor].to_bytes()) & 0xFFFF
      if computed_header_crc != stored_header_crc {
        return Err(inflate_error("gzip header CRC mismatch"))
      }
      cursor = cursor + 2
    }
    if cursor >= data.length() || data.length() - cursor < 8 {
      return Err(inflate_error("truncated gzip body"))
    }
    // The DEFLATE stream does not declare its length, so decode it and use the
    // number of consumed bytes to locate this member's trailer.
    let (inflated, consumed) = match inflate_raw_consume(
      data[cursor:data.length()].to_bytes(),
      max_bytes,
    ) {
      Ok(result) => result
      Err(err) => return Err(err)
    }
    let trailer = cursor + consumed
    if trailer + 8 > data.length() {
      return Err(inflate_error("truncated gzip trailer"))
    }
    let stored_crc = read_le32(data, trailer)
    if crc32(inflated) != stored_crc {
      return Err(inflate_error("gzip CRC mismatch"))
    }
    let stored_size = read_le32(data, trailer + 4)
    if (inflated.length() & 0xFFFFFFFF) != stored_size {
      return Err(inflate_error("gzip length mismatch"))
    }
    if output.length() + inflated.length() > max_bytes {
      return Err(inflate_error("output too large"))
    }
    let mut index = 0
    while index < inflated.length() {
      output.push(inflated[index])
      index = index + 1
    }
    members = members + 1
    offset = trailer + 8
  }
  if members == 0 {
    return Err(inflate_error("truncated gzip header"))
  }
  Ok(@buffer.from_array(output[:]).to_bytes())
}

fn skip_cstring(data : Bytes, offset : Int) -> Int {
  let mut i = offset
  while i < data.length() && data[i].to_int() != 0 {
    i = i + 1
  }
  i + 1
}

/// Decompress a raw DEFLATE payload. Accepts an optional zlib wrapper: if a
/// valid zlib header is present it is validated and the Adler-32 trailer is
/// checked, otherwise the data is treated as a bare DEFLATE stream (some
/// servers send `Content-Encoding: deflate` without the zlib wrapper).
pub fn inflate(data : Bytes, max_bytes : Int) -> Result[Bytes, HttpError] {
  let limit = if max_bytes < 0 { 0 } else { max_bytes }
  if data.length() >= 2 {
    let cmf = data[0].to_int()
    let flg = data[1].to_int()
    if (cmf & 0x0F) == 8 && (cmf >> 4) <= 7 && ((cmf << 8) | flg) % 31 == 0 {
      let zlib_result = inflate_zlib(data, limit)
      match zlib_result {
        Ok(decoded) => return Ok(decoded)
        Err(zlib_error) => {
          // A preset dictionary is a declared zlib feature that this decoder
          // does not support; do not reinterpret the same bytes as raw DEFLATE.
          if (flg & 0x20) != 0 {
            return Err(zlib_error)
          }
          match inflate_raw(data, limit) {
            Ok(decoded) => return Ok(decoded)
            Err(_) => return Err(zlib_error)
          }
        }
      }
    }
  }
  inflate_raw(data, limit)
}

/// Decompress a gzip payload.
pub fn gunzip(data : Bytes, max_bytes : Int) -> Result[Bytes, HttpError] {
  let limit = if max_bytes < 0 { 0 } else { max_bytes }
  inflate_gzip(data, limit)
}

/// Decode a response body according to a single `Content-Encoding` value.
/// Unknown or unsupported encodings return an error; `identity` (or empty)
/// returns the payload unchanged.
pub fn decode_content_encoding(
  encoding : String,
  data : Bytes,
  max_bytes : Int,
) -> Result[Bytes, HttpError] {
  let normalized = encoding.trim().to_lower()
  let limit = if max_bytes < 0 { 0 } else { max_bytes }
  match normalized {
    "" | "identity" =>
      if data.length() > limit {
        Err(NetworkError(ReadError("response body too large")))
      } else {
        Ok(data)
      }
    "gzip" | "x-gzip" => gunzip(data, limit)
    "deflate" => inflate(data, limit)
    _ => Err(ProtocolError("unsupported Content-Encoding: " + encoding))
  }
}
