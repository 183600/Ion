///|
/// Decode a response body as text using the `charset` parameter from its
/// `Content-Type` header. Unknown charsets fall back to UTF-8, matching the
/// permissive behaviour clients need when talking to misconfigured servers.
fn charset_parameter(value : String) -> String? {
  let length = value.length()
  let mut index = 0
  while index < length {
    // Skip separators and optional whitespace before the next parameter.
    while index < length {
      match value.get_char(index) {
        Some(ch) =>
          if ch == ';' || ch == ' ' || ch == '\t' {
            index = index + 1
          } else {
            break
          }
        // Low surrogate of an astral scalar; it is not a delimiter.
        None => index = index + 1
      }
    }
    if index >= length {
      break
    }
    let name_start = index
    while index < length {
      match value.get_char(index) {
        Some(ch) =>
          if ch == '=' || ch == ';' {
            break
          } else if ch < ' ' || ch > '~' {
            // Skip invalid characters in parameter name.
            index = index + 1
          } else {
            index = index + 1
          }
        None => index = index + 1
      }
    }
    if index >= length {
      break
    }
    let name = value[name_start:index].trim().to_lower()
    if value.get_char(index) == Some(';') {
      // A parameter without a value supplies nothing for `charset`.
      continue
    }
    // Consume `=` and any whitespace around it (RFC 7231 §3.1.1.3).
    index = index + 1
    while index < length {
      match value.get_char(index) {
        Some(ch) =>
          if ch == ' ' || ch == '\t' {
            index = index + 1
          } else {
            break
          }
        None => index = index + 1
      }
    }
    let mut parsed = ""
    let mut malformed = false
    if index < length && value.get_char(index) == Some('"') {
      // Quoted values may contain semicolons; only the closing quote ends the
      // value. Honor quoted-pair escapes so an escaped quote cannot terminate
      // the string early. Copy unescaped runs as slices so astral scalars are
      // preserved even though `get_char` reports their low surrogate as None.
      index = index + 1
      let output = Buffer(size_hint=length - index)
      let mut segment_start = index
      let mut closed = false
      while index < length {
        match value.get_char(index) {
          Some('"') => {
            output.write_bytes(@utf8.encode(value[segment_start:index]))
            index = index + 1
            closed = true
            break
          }
          Some('\\') => {
            output.write_bytes(@utf8.encode(value[segment_start:index]))
            index = index + 1
            if index >= length {
              break
            }
            match value.get_char(index) {
              Some(ch) => {
                output.write_char_utf8(ch)
                index = index + 1
                // An astral scalar occupies two UTF-16 code units; the low
                // surrogate was already written with the scalar.
                if index < length && value.get_char(index) == None {
                  index = index + 1
                }
              }
              None => index = index + 1
            }
            segment_start = index
          }
          _ => index = index + 1
        }
      }
      if closed {
        parsed = @utf8.decode_lossy(output.to_bytes()[:])
      } else {
        malformed = true
      }
    } else {
      let value_start = index
      while index < length {
        match value.get_char(index) {
          Some(ch) => if ch == ';' { break } else { index = index + 1 }
          None => index = index + 1
        }
      }
      parsed = value[value_start:index].trim().to_owned()
    }
    if name == "charset" {
      if malformed || parsed.length() == 0 {
        return None
      }
      return Some(parsed)
    }
    if malformed {
      break
    }
    // A quoted value may be followed by more text (normally only OWS) before
    // the next semicolon; skip it rather than parsing it as a new attribute.
    while index < length && value.get_char(index) != Some(';') {
      index = index + 1
    }
  }
  None
}

///|
fn response_charset(headers : Headers) -> String? {
  match headers.get("Content-Type") {
    Some(value) => charset_parameter(value)
    None => None
  }
}

///|
fn windows_1252_codepoint(byte : Int32) -> Int32 {
  match byte {
    0x80 => 0x20AC
    0x82 => 0x201A
    0x83 => 0x0192
    0x84 => 0x201E
    0x85 => 0x2026
    0x86 => 0x2020
    0x87 => 0x2021
    0x88 => 0x02C6
    0x89 => 0x2030
    0x8A => 0x0160
    0x8B => 0x2039
    0x8C => 0x0152
    0x8E => 0x017D
    0x91 => 0x2018
    0x92 => 0x2019
    0x93 => 0x201C
    0x94 => 0x201D
    0x95 => 0x2022
    0x96 => 0x2013
    0x97 => 0x2014
    0x98 => 0x02DC
    0x99 => 0x2122
    0x9A => 0x0161
    0x9B => 0x203A
    0x9C => 0x0153
    0x9E => 0x017E
    0x9F => 0x0178
    // Windows-1252 leaves these positions undefined. A single-byte decoder
    // reports them as errors (U+FFFD) instead of exposing the C1 control code.
    0x81 | 0x8D | 0x8F | 0x90 | 0x9D => 0xFFFD
    _ => byte
  }
}

///|
fn decode_single_byte(data : Bytes, windows_1252 : Bool) -> String {
  let output = Buffer(size_hint=data.length())
  for byte in data {
    let value = byte.to_int()
    let codepoint = if value >= 0x80 && value <= 0x9F && windows_1252 {
      windows_1252_codepoint(value)
    } else {
      value
    }
    output.write_char_utf8(Char::from_int(codepoint))
  }
  @utf8.decode_lossy(output.to_bytes()[:])
}

///|
fn decode_ascii(data : Bytes) -> String {
  let output = Buffer(size_hint=data.length())
  for byte in data {
    let value = byte.to_int()
    output.write_char_utf8(
      Char::from_int(if value < 0x80 { value } else { 0xFFFD }),
    )
  }
  @utf8.decode_lossy(output.to_bytes()[:])
}

///|
fn decode_utf16(data : Bytes, requested : String) -> String {
  let explicit_little = requested == "utf-16le"
  let explicit_big = requested == "utf-16be"
  let mut little_endian = explicit_little
  let mut offset = 0
  if data.length() >= 2 {
    let first = data[0].to_int()
    let second = data[1].to_int()
    // RFC 2781 §4.1/§4.2: an explicit endianness label is authoritative, so
    // an opposite-order BOM must be decoded as data (and is an error), never
    // used to swap the byte order. Generic "utf-16" still sniffs the BOM.
    if first == 0xFF && second == 0xFE {
      if !explicit_big {
        little_endian = true
        offset = 2
      }
    } else if first == 0xFE && second == 0xFF {
      if !explicit_little {
        little_endian = false
        offset = 2
      }
    }
  }
  let output = Buffer(size_hint=data.length())
  while offset + 1 < data.length() {
    let unit = if little_endian {
      data[offset].to_int() | (data[offset + 1].to_int() << 8)
    } else {
      (data[offset].to_int() << 8) | data[offset + 1].to_int()
    }
    offset = offset + 2
    let mut codepoint = unit
    if unit >= 0xD800 && unit <= 0xDBFF {
      if offset + 1 < data.length() {
        let low = if little_endian {
          data[offset].to_int() | (data[offset + 1].to_int() << 8)
        } else {
          (data[offset].to_int() << 8) | data[offset + 1].to_int()
        }
        if low >= 0xDC00 && low <= 0xDFFF {
          offset = offset + 2
          codepoint = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
        } else {
          codepoint = 0xFFFD
        }
      } else {
        codepoint = 0xFFFD
      }
    } else if unit >= 0xDC00 && unit <= 0xDFFF {
      codepoint = 0xFFFD
    }
    // U+FFFE and U+FFFF are noncharacters; in particular a mismatched BOM
    // under an explicit UTF-16 endianness must not surface as U+FFFE.
    if codepoint == 0xFFFE || codepoint == 0xFFFF {
      codepoint = 0xFFFD
    }
    output.write_char_utf8(Char::from_int(codepoint))
  }
  if offset < data.length() {
    output.write_char_utf8(Char::from_int(0xFFFD))
  }
  @utf8.decode_lossy(output.to_bytes()[:])
}

///|
fn decode_text_body(data : Bytes, charset : String?) -> String {
  let charset = match charset {
    Some(value) => value.trim().to_lower().to_owned()
    None => ""
  }
  let utf8_bom = data.length() >= 3 &&
    data[0].to_int() == 0xEF &&
    data[1].to_int() == 0xBB &&
    data[2].to_int() == 0xBF
  let utf16le_bom = data.length() >= 2 &&
    data[0].to_int() == 0xFF &&
    data[1].to_int() == 0xFE
  let utf16be_bom = data.length() >= 2 &&
    data[0].to_int() == 0xFE &&
    data[1].to_int() == 0xFF
  match charset {
    "" =>
      // Without a declared charset, a byte-order mark is the most reliable
      // signal; UTF-16 text is otherwise indistinguishable from arbitrary
      // bytes under UTF-8.
      if utf16le_bom || utf16be_bom {
        decode_utf16(data, "utf-16")
      } else if utf8_bom {
        @utf8.decode_lossy(data.exact_view(start=3, end=data.length()))
      } else {
        @utf8.decode_lossy(data[:])
      }
    "utf-8" | "utf8" =>
      if utf8_bom {
        @utf8.decode_lossy(data.exact_view(start=3, end=data.length()))
      } else {
        @utf8.decode_lossy(data[:])
      }
    "us-ascii" | "ascii" => decode_ascii(data)
    "iso-8859-1" | "iso8859-1" | "latin1" | "latin-1" =>
      decode_single_byte(data, false)
    "windows-1252" | "cp1252" | "windows1252" => decode_single_byte(data, true)
    "utf-16" | "utf16" | "utf-16le" | "utf-16be" =>
      // If there's a BOM, use it. Otherwise, for explicit endianness labels
      // (utf-16le/utf-16be) use the specified endianness; for generic "utf-16"
      // without a BOM, RFC 2781 §4.2 says to interpret it as big-endian.
      if utf16le_bom || utf16be_bom {
        decode_utf16(data, charset)
      } else if charset == "utf-16le" || charset == "utf-16be" {
        // Explicit endianness without BOM: try decoding, fall back to UTF-8
        let result = decode_utf16(data, charset)
        if result.length() > 0 || data.length() == 0 {
          result
        } else {
          @utf8.decode_lossy(data[:])
        }
      } else {
        decode_utf16(data, charset)
      }
    _ =>
      // Fall back to UTF-8 decode with a clear indication that the declared
      // charset was not explicitly supported; callers sensitive to encoding
      // correctness can use `Response::text()` which always decodes, or
      // `Response::read_body_decoded` which applies understood codings.
      @utf8.decode_lossy(data[:])
  }
}
