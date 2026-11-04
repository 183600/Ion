///|
/// Minimal DEFLATE compressor used for RFC 7692 WebSocket messages.
///
/// The encoder emits one fixed-Huffman block with greedy LZ77 matches, followed
/// by the empty sync-flush block required by `permessage-deflate` (the final
/// four marker bytes are stripped, so only the block header byte remains).
const DEFLATE_MAX_MATCH : Int32 = 258

///|
const DEFLATE_WINDOW : Int32 = 32768

///|
const DEFLATE_HASH_SIZE : Int32 = 4096

///|
let deflate_length_base : Array[Int32] = [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83,
  99, 115, 131, 163, 195, 227, 258,
]

///|
let deflate_length_extra : Array[Int32] = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5,
  5, 0,
]

///|
let deflate_distance_base : Array[Int32] = [
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769,
  1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
]

///|
let deflate_distance_extra : Array[Int32] = [
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11,
  12, 12, 13, 13,
]

///|
struct DeflateBitWriter {
  output : Buffer
  mut bits : Int32
  mut count : Int32
}

///|
fn DeflateBitWriter::new() -> DeflateBitWriter {
  DeflateBitWriter::{ output: Buffer(size_hint=256), bits: 0, count: 0, }
}

///|
fn DeflateBitWriter::flush_byte(self : DeflateBitWriter) -> Unit {
  if self.count > 0 {
    self.output.write_byte(self.bits.to_byte())
    self.bits = 0
    self.count = 0
  }
}

///|
fn DeflateBitWriter::write_bit(self : DeflateBitWriter, bit : Int32) -> Unit {
  self.bits = self.bits | ((bit & 1) << self.count)
  self.count = self.count + 1
  if self.count == 8 {
    self.flush_byte()
  }
}

///|
/// Write an extra-bits field least-significant bit first, as DEFLATE requires.
fn DeflateBitWriter::write_bits(
  self : DeflateBitWriter,
  value : Int32,
  count : Int32,
) -> Unit {
  let mut index = 0
  while index < count {
    self.write_bit((value >> index) & 1)
    index = index + 1
  }
}

///|
/// Write a Huffman code most-significant bit first.
fn DeflateBitWriter::write_code(
  self : DeflateBitWriter,
  code : Int32,
  length : Int32,
) -> Unit {
  let mut index = length - 1
  while index >= 0 {
    self.write_bit((code >> index) & 1)
    index = index - 1
  }
}

///|
fn DeflateBitWriter::finish(self : DeflateBitWriter) -> Bytes {
  // Start the empty stored block used for the RFC 7692 sync flush. Its LEN
  // and NLEN fields start on the next byte boundary; the peer appends the
  // matching 00 00 FF FF before inflating.
  self.write_bits(0, 3)
  self.flush_byte()
  self.output.to_bytes()
}

///|
fn deflate_fixed_code(symbol : Int32) -> (Int32, Int32) {
  if symbol <= 143 {
    (0x30 + symbol, 8)
  } else if symbol <= 255 {
    (0x190 + symbol - 144, 9)
  } else if symbol <= 279 {
    (symbol - 256, 7)
  } else {
    (0xC0 + symbol - 280, 8)
  }
}

///|
fn deflate_length_info(length : Int32) -> (Int32, Int32, Int32) {
  let mut index = deflate_length_base.length() - 1
  while index > 0 && length < deflate_length_base[index] {
    index = index - 1
  }
  (
    257 + index,
    deflate_length_extra[index],
    length - deflate_length_base[index],
  )
}

///|
fn deflate_distance_info(distance : Int32) -> (Int32, Int32, Int32) {
  let mut index = deflate_distance_base.length() - 1
  while index > 0 && distance < deflate_distance_base[index] {
    index = index - 1
  }
  (
    index,
    deflate_distance_extra[index],
    distance - deflate_distance_base[index],
  )
}

///|
fn deflate_hash(data : Bytes, position : Int32) -> Int32 {
  (
    (data[position].to_int() * 31 + data[position + 1].to_int()) * 31 +
    data[position + 2].to_int()
  ) &
  0xFFF
}

///|
/// Compress `data` into a raw DEFLATE stream. With `sync_flush` the output
/// ends after the empty stored-block header required by RFC 7692
/// `permessage-deflate` (the peer appends the matching `00 00 FF FF` marker
/// bytes); otherwise the block is marked final and byte-aligned, producing a
/// complete standalone DEFLATE stream.
fn deflate_compress_with(data : Bytes, sync_flush : Bool) -> Bytes {
  let writer = DeflateBitWriter::new()
  // BFINAL = 0 for sync flush, 1 for a final block; BTYPE = 01 (fixed Huffman).
  writer.write_bits(if sync_flush { 0 } else { 1 }, 1)
  writer.write_bits(1, 2)
  let length = data.length()
  let head = Array::make(DEFLATE_HASH_SIZE, -1)
  let mut position = 0
  while position < length {
    let mut match_length = 0
    let mut match_distance = 0
    if position + 2 < length {
      let candidate = head[deflate_hash(data, position)]
      if candidate >= 0 &&
        candidate < position &&
        position - candidate <= DEFLATE_WINDOW {
        let limit = if length - position < DEFLATE_MAX_MATCH {
          length - position
        } else {
          DEFLATE_MAX_MATCH
        }
        let mut matched = 0
        while matched < limit &&
              data[candidate + matched] == data[position + matched] {
          matched = matched + 1
        }
        if matched >= 3 {
          match_length = matched
          match_distance = position - candidate
        }
      }
    }
    if match_length >= 3 {
      let (symbol, extra_bits, extra_value) = deflate_length_info(match_length)
      let (code, code_length) = deflate_fixed_code(symbol)
      writer.write_code(code, code_length)
      writer.write_bits(extra_value, extra_bits)
      let (distance_code, distance_extra, distance_value) = deflate_distance_info(
        match_distance,
      )
      writer.write_code(distance_code, 5)
      writer.write_bits(distance_value, distance_extra)
      let mut inserted = 0
      while inserted < match_length {
        if position + inserted + 2 < length {
          head[deflate_hash(data, position + inserted)] = position + inserted
        }
        inserted = inserted + 1
      }
      position = position + match_length
    } else {
      let (code, code_length) = deflate_fixed_code(data[position].to_int())
      writer.write_code(code, code_length)
      if position + 2 < length {
        head[deflate_hash(data, position)] = position
      }
      position = position + 1
    }
  }
  let (end_code, end_length) = deflate_fixed_code(256)
  writer.write_code(end_code, end_length)
  if sync_flush {
    writer.finish()
  } else {
    // A final block needs no sync-flush marker; just pad to a byte boundary.
    writer.flush_byte()
    writer.output.to_bytes()
  }
}

///|
/// Compress `data` into a complete raw DEFLATE stream (RFC 1951). The output
/// is standalone and can be embedded in zlib (RFC 1950) or gzip (RFC 1952)
/// wrappers, or decoded with `inflate_deflate`.
pub fn deflate_compress_raw(data : Bytes) -> Bytes {
  deflate_compress_with(data, false)
}

///|
/// Compress `data` for WebSocket `permessage-deflate`: a raw DEFLATE stream
/// whose trailing `00 00 FF FF` sync-flush marker bytes are omitted (they are
/// implicit for the extension).
fn deflate_compress(data : Bytes) -> Bytes {
  deflate_compress_with(data, true)
}

///|
/// Compress `data` into a zlib stream (RFC 1950): a zlib header, a raw
/// DEFLATE body, and an Adler-32 trailer over the uncompressed data. Decode
/// the result with `inflate` (or any zlib decoder).
pub fn zlib_compress(data : Bytes) -> Bytes {
  let output = Buffer(size_hint=data.length() / 2 + 64)
  output.write_byte(0x78) // CMF: deflate, 32K window
  output.write_byte(0x9c) // FLG: FLEVEL=2, no dictionary, header check valid
  output.write_bytes(deflate_compress_raw(data))
  let checksum = adler32(data)
  // The zlib Adler-32 trailer is stored big-endian (RFC 1950 §2.2).
  output.write_byte(((checksum >> 24) & 0xFF).to_byte())
  output.write_byte(((checksum >> 16) & 0xFF).to_byte())
  output.write_byte(((checksum >> 8) & 0xFF).to_byte())
  output.write_byte((checksum & 0xFF).to_byte())
  output.to_bytes()
}

///|
/// Compress `data` into a gzip stream (RFC 1952): a minimal header without
/// optional fields, a raw DEFLATE body, and a CRC-32 / ISIZE trailer over the
/// uncompressed data. Decode the result with `gunzip` (or any gzip decoder).
pub fn gzip_compress(data : Bytes) -> Bytes {
  let output = Buffer(size_hint=data.length() / 2 + 64)
  output.write_byte(0x1f)
  output.write_byte(0x8b)
  output.write_byte(0x08) // CM = deflate
  output.write_byte(0x00) // FLG: no FEXTRA/FNAME/FCOMMENT/FHCRC
  output.write_byte(0x00) // MTIME = 0 (4 bytes, no timestamp)
  output.write_byte(0x00)
  output.write_byte(0x00)
  output.write_byte(0x00)
  output.write_byte(0x00) // XFL
  output.write_byte(0xff) // OS = unknown
  output.write_bytes(deflate_compress_raw(data))
  let checksum = crc32(data)
  // The gzip CRC-32 and ISIZE trailer fields are little-endian (RFC 1952 §2.3.1).
  output.write_byte((checksum & 0xFF).to_byte())
  output.write_byte(((checksum >> 8) & 0xFF).to_byte())
  output.write_byte(((checksum >> 16) & 0xFF).to_byte())
  output.write_byte(((checksum >> 24) & 0xFF).to_byte())
  let length = data.length() & 0xFFFFFFFF
  output.write_byte((length & 0xFF).to_byte())
  output.write_byte(((length >> 8) & 0xFF).to_byte())
  output.write_byte(((length >> 16) & 0xFF).to_byte())
  output.write_byte(((length >> 24) & 0xFF).to_byte())
  output.to_bytes()
}
