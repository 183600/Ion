fn idna_needs_conversion(value : String) -> Bool {
  for ch in value {
    if ch.to_int() > 0x7f {
      return true
    }
  }
  false
}

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

fn idna_forbidden_unicode(code : Int) -> Bool {
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

fn idna_ascii_label_char(code : Int) -> Bool {
  (code >= 'a'.to_int() && code <= 'z'.to_int()) ||
  (code >= '0'.to_int() && code <= '9'.to_int()) ||
  code == '-'.to_int() ||
  code == '_'.to_int()
}

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

fn punycode_adapt(delta : Int, points : Int, first : Bool) -> Int {
  let mut delta = if first { delta / 700 } else { delta / 2 }
  delta = delta + delta / points
  let mut bias = 0
  while delta > ((36 - 1) * 26) / 2 {
    delta = delta / 36
    bias = bias + 36
  }
  bias + (36 * delta) / (delta + 38)
}

fn punycode_digit(value : Int) -> Int {
  if value < 26 {
    'a'.to_int() + value
  } else {
    '0'.to_int() + value - 26
  }
}

fn punycode_encode(input : String) -> String? {
  let code_points : Array[Int] = []
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
          let threshold = if k <= bias {
            1
          } else if k >= bias + 26 {
            26
          } else {
            k - bias
          }
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
        bias = punycode_adapt(delta, handled + 1, handled == 0)
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
      if ch.is_control() || ch.is_whitespace() || idna_forbidden_unicode(code) {
        return None
      }
    } else if !idna_ascii_label_char(code) {
      return None
    }
  }
  if !needs_conversion {
    if idna_valid_ascii_label(label) {
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
