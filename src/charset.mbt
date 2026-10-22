/// Decode a response body as text using the `charset` parameter from its
/// `Content-Type` header. Unknown charsets fall back to UTF-8, matching the
/// permissive behaviour clients need when talking to misconfigured servers.

fn charset_parameter(value : String) -> String? {
  for part in value.split(";") {
    let part = part.trim()
    let equals = match part.find("=") {
      Some(index) => index
      None => continue
    }
    let name = part[0:equals].trim().to_lower()
    if name != "charset" {
      continue
    }
    let value = part[equals + 1:].trim()
    if value.length() == 0 {
      return None
    }
    if value.length() >= 2 && value.get_char(0) == Some('"') &&
      value.get_char(value.length() - 1) == Some('"') {
      return Some(value[1:value.length() - 1].to_owned())
    }
    return Some(value.to_owned())
  }
  None
}

fn response_charset(headers : Headers) -> String? {
  match headers.get("Content-Type") {
    Some(value) => charset_parameter(value)
    None => None
  }
}

fn windows_1252_codepoint(byte : Int) -> Int {
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
    _ => byte
  }
}

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

fn decode_ascii(data : Bytes) -> String {
  let output = Buffer(size_hint=data.length())
  for byte in data {
    let value = byte.to_int()
    output.write_char_utf8(Char::from_int(if value < 0x80 { value } else { 0xFFFD }))
  }
  @utf8.decode_lossy(output.to_bytes()[:])
}

fn decode_utf16(data : Bytes, requested : String) -> String {
  let mut little_endian = requested == "utf-16le"
  let mut offset = 0
  if data.length() >= 2 {
    let first = data[0].to_int()
    let second = data[1].to_int()
    if first == 0xFF && second == 0xFE {
      little_endian = true
      offset = 2
    } else if first == 0xFE && second == 0xFF {
      little_endian = false
      offset = 2
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
    output.write_char_utf8(Char::from_int(codepoint))
  }
  if offset < data.length() {
    output.write_char_utf8(Char::from_int(0xFFFD))
  }
  @utf8.decode_lossy(output.to_bytes()[:])
}

fn decode_text_body(data : Bytes, charset : String?) -> String {
  let charset = match charset {
    Some(value) => value.trim().to_lower().to_owned()
    None => ""
  }
  match charset {
    "" | "utf-8" | "utf8" => @utf8.decode_lossy(data[:])
    "us-ascii" | "ascii" => decode_ascii(data)
    "iso-8859-1" | "iso8859-1" | "latin1" | "latin-1" =>
      decode_single_byte(data, false)
    "windows-1252" | "cp1252" | "windows1252" =>
      decode_single_byte(data, true)
    "utf-16" | "utf16" | "utf-16le" | "utf-16be" =>
      decode_utf16(data, charset)
    _ => @utf8.decode_lossy(data[:])
  }
}
