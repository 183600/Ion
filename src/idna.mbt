///|
fn idna_needs_conversion(value : String) -> Bool {
  for ch in value {
    if ch.to_int() > 0x7f {
      return true
    }
  }
  false
}

///|
fn idna_map_host(host : String) -> String {
  let output = StringBuilder(size_hint=host.length())
  for ch in host {
    let code = ch.to_int()
    if code == 0x3002 || code == 0xFF0E || code == 0xFF61 {
      output.write_char('.')
    } else if code == 0x3000 {
      output.write_char(' ')
    } else if code >= 0xFF01 && code <= 0xFF5E {
      output.write_char(Char::from_int(code - 0xFEE0))
    } else {
      output.write_char(ch)
    }
  }
  idna_lowercase(output.to_string())
}

///|
fn idna_forbidden_unicode(code : Int32) -> Bool {
  if (code >= 0x200B && code <= 0x200F) ||
    (code >= 0x202A && code <= 0x202E) ||
    (code >= 0x2060 && code <= 0x2069) ||
    code == 0xFEFF ||
    (code >= 0xFDD0 && code <= 0xFDEF) {
    return true
  }
  let plane_tail = code % 0x10000
  if plane_tail == 0xFFFE || plane_tail == 0xFFFF {
    return true
  }
  (code >= 0xE000 && code <= 0xF8FF) ||
  (code >= 0xF0000 && code <= 0xFFFFD) ||
  (code >= 0x100000 && code <= 0x10FFFD)
}

///|
fn idna_ascii_label_char(code : Int32) -> Bool {
  (code >= 'a'.to_int() && code <= 'z'.to_int()) ||
  (code >= '0'.to_int() && code <= '9'.to_int()) ||
  code == '-'.to_int() ||
  code == '_'.to_int()
}

///|
fn idna_valid_ascii_label(label : String) -> Bool {
  if label.length() == 0 || label.length() > 63 {
    return false
  }
  if label.has_prefix("-") || label.has_suffix("-") {
    return false
  }
  for ch in label {
    if !idna_ascii_label_char(ch.to_int()) {
      return false
    }
  }
  true
}

///|
fn punycode_adapt(delta : Int32, points : Int32, first : Bool) -> Int32 {
  let mut delta = if first { delta / 700 } else { delta / 2 }
  delta = delta + delta / points
  let mut bias = 0
  while delta > (36 - 1) * 26 / 2 {
    delta = delta / (36 - 1)
    bias = bias + 36
  }
  bias + 36 * delta / (delta + 38)
}

///|
fn punycode_digit(value : Int32) -> Int32 {
  if value < 26 {
    'a'.to_int() + value
  } else {
    '0'.to_int() + value - 26
  }
}

///|
fn punycode_digit_value(code : Int32) -> Int32 {
  if code >= 'a'.to_int() && code <= 'z'.to_int() {
    code - 'a'.to_int()
  } else if code >= 'A'.to_int() && code <= 'Z'.to_int() {
    code - 'A'.to_int()
  } else if code >= '0'.to_int() && code <= '9'.to_int() {
    code - '0'.to_int() + 26
  } else {
    -1
  }
}

///|
fn punycode_threshold(k : Int32, bias : Int32) -> Int32 {
  if k <= bias {
    1
  } else if k >= bias + 26 {
    26
  } else {
    k - bias
  }
}

///|
/// Decode one Punycode label payload (RFC 3492) without the `xn--` prefix.
/// The result is rejected when the input is malformed, overflows, contains a
/// surrogate, or would not round-trip through the encoder. The round-trip
/// check also rejects non-canonical spellings of the same A-label.
fn punycode_decode(input : String) -> String? {
  let encoded : Array[Int32] = []
  for ch in input {
    let code = ch.to_int()
    if code >= 0x80 || (punycode_digit_value(code) < 0 && code != '-'.to_int()) {
      return None
    }
    encoded.push(code)
  }
  if encoded.length() == 0 {
    return None
  }
  let output : Array[Int32] = []
  let mut last_delimiter = -1
  let mut index = 0
  while index < encoded.length() {
    if encoded[index] == '-'.to_int() {
      last_delimiter = index
    }
    index = index + 1
  }
  if last_delimiter >= 0 {
    index = 0
    while index < last_delimiter {
      output.push(encoded[index])
      index = index + 1
    }
    index = last_delimiter + 1
  } else {
    index = 0
  }

  let mut n = 0x80
  let mut i = 0
  let mut bias = 72
  while index < encoded.length() {
    let old_i = i
    let mut weight = 1
    let mut k = 36
    while true {
      if index >= encoded.length() {
        return None
      }
      let digit = punycode_digit_value(encoded[index])
      index = index + 1
      if digit < 0 {
        return None
      }
      if digit > 0 && weight > (0x7FFFFFFF - i) / digit {
        return None
      }
      i = i + digit * weight
      let threshold = punycode_threshold(k, bias)
      if digit < threshold {
        break
      }
      let base_minus_threshold = 36 - threshold
      if weight > 0x7FFFFFFF / base_minus_threshold {
        return None
      }
      weight = weight * base_minus_threshold
      if k > 0x7FFFFFFF - 36 {
        return None
      }
      k = k + 36
    }
    let output_length = output.length() + 1
    let delta = i - old_i
    if delta < 0 {
      return None
    }
    bias = punycode_adapt(delta, output_length, old_i == 0)
    let quotient = i / output_length
    if quotient > 0x10FFFF - n {
      return None
    }
    n = n + quotient
    if n > 0x10FFFF || (n >= 0xD800 && n <= 0xDFFF) {
      return None
    }
    i = i % output_length
    let _ = output.insert(i, n)
    i = i + 1
  }
  if output.length() == 0 || output.length() > 63 {
    return None
  }
  let decoded = StringBuilder(size_hint=output.length())
  for code in output {
    decoded.write_char(Char::from_int(code))
  }
  Some(decoded.to_string())
}

///|
fn idna_valid_decoded_label(label : String) -> Bool {
  let mut points = 0
  let mut has_non_ascii = false
  for ch in label {
    let code = ch.to_int()
    points = points + 1
    if points > 63 {
      return false
    }
    if code > 0x7f {
      has_non_ascii = true
      if !ch.is_printable() ||
        ch.is_whitespace() ||
        idna_forbidden_unicode(code) {
        return false
      }
    } else if !idna_ascii_label_char(code) {
      return false
    }
  }
  has_non_ascii && !label.has_prefix("-") && !label.has_suffix("-")
}

///|
fn idna_valid_alabel(label : String) -> Bool {
  if !label.has_prefix("xn--") {
    return true
  }
  if label.length() > 63 {
    return false
  }
  let payload = label[4:].to_owned()
  let decoded = match punycode_decode(payload) {
    Some(decoded) => decoded
    None => return false
  }
  if !idna_valid_decoded_label(decoded) {
    return false
  }
  match punycode_encode(decoded) {
    Some(encoded) => encoded == payload
    None => false
  }
}

///|
fn idna_valid_ascii_host(host : String) -> Bool {
  let parts = host.split(".").collect()
  let total = parts.length()
  let mut index = 0
  for part in parts {
    let label = part.to_owned()
    let is_last = index == total - 1
    index = index + 1
    if label.length() == 0 {
      if is_last && index > 1 {
        continue
      }
      return false
    }
    let lower = label.to_lower()
    if lower.has_prefix("xn--") && !idna_valid_alabel(lower) {
      return false
    }
  }
  true
}

///|
fn punycode_encode(input : String) -> String? {
  let code_points : Array[Int32] = []
  for ch in input {
    code_points.push(ch.to_int())
    if code_points.length() > 63 {
      return None
    }
  }
  if code_points.length() == 0 {
    return None
  }
  let output = Buffer(size_hint=64)
  let mut basic = 0
  for code in code_points {
    if code < 0x80 {
      output.write_byte(code.to_byte())
      basic = basic + 1
    }
  }
  let mut handled = basic
  if basic > 0 {
    output.write_byte('-'.to_int().to_byte())
  }
  let mut n = 0x80
  let mut delta = 0
  let mut bias = 72
  while handled < code_points.length() {
    let mut next = 0x110000
    for code in code_points {
      if code >= n && code < next {
        next = code
      }
    }
    let increment = (next - n) * (handled + 1)
    if delta > 0x7FFFFFFF - increment {
      return None
    }
    delta = delta + increment
    n = next
    for code in code_points {
      if code < n {
        delta = delta + 1
      } else if code == n {
        let mut q = delta
        let mut k = 36
        while true {
          // Reuse the same threshold rule as the decoder so encoder and
          // decoder cannot drift apart on bias handling.
          let threshold = punycode_threshold(k, bias)
          if q < threshold {
            break
          }
          output.write_byte(
            punycode_digit(threshold + (q - threshold) % (36 - threshold)).to_byte(),
          )
          q = (q - threshold) / (36 - threshold)
          k = k + 36
        }
        output.write_byte(punycode_digit(q).to_byte())
        bias = punycode_adapt(delta, handled + 1, handled == basic)
        delta = 0
        handled = handled + 1
      }
    }
    delta = delta + 1
    n = n + 1
  }
  if output.length() > 63 {
    return None
  }
  Some(@utf8.decode_lossy(output.to_bytes()[:]))
}

///|
fn idna_convert_label(label : String) -> String? {
  if label.length() == 0 || label.has_prefix("-") || label.has_suffix("-") {
    return None
  }
  let mut needs_conversion = false
  let mut points = 0
  for ch in label {
    let code = ch.to_int()
    points = points + 1
    if points > 63 {
      return None
    }
    if code > 0x7f {
      needs_conversion = true
      if !ch.is_printable() ||
        ch.is_whitespace() ||
        idna_forbidden_unicode(code) {
        return None
      }
    } else if !idna_ascii_label_char(code) {
      return None
    }
  }
  if !needs_conversion {
    if idna_valid_ascii_label(label) && idna_valid_alabel(label) {
      return Some(label)
    }
    return None
  }
  match punycode_encode(label) {
    Some(encoded) =>
      if encoded.length() + 4 <= 63 {
        Some("xn--" + encoded)
      } else {
        None
      }
    None => None
  }
}

///|
fn idna_host_to_ascii(host : String) -> String? {
  if host.length() == 0 {
    return None
  }
  let mapped = idna_map_host(host)
  let parts = mapped.split(".").collect()
  if parts.length() == 0 {
    return None
  }
  let total = parts.length()
  let output = StringBuilder(size_hint=mapped.length() + 8)
  let mut index = 0
  let mut wrote_label = false
  for part in parts {
    let label = part.to_owned()
    let is_last = index == total - 1
    index = index + 1
    if label.length() == 0 {
      if is_last && wrote_label {
        output.write_char('.')
        continue
      }
      return None
    }
    let converted = match idna_convert_label(label) {
      Some(label) => label
      None => return None
    }
    if wrote_label {
      output.write_char('.')
    }
    output.write_string(converted)
    wrote_label = true
  }
  let result = output.to_string()
  let name = if result.length() > 1 && result.has_suffix(".") {
    result[0:result.length() - 1].to_owned()
  } else {
    result
  }
  if name.length() == 0 || name.length() > 253 {
    return None
  }
  Some(result)
}
