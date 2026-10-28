/// Backwards-compatible name for the standard library list type.
pub type List[A] = @list.List[A]


fn is_decimal_digits(value : String) -> Bool {
  if value.length() == 0 {
    return false
  }
  for ch in value {
    if ch < '0' || ch > '9' {
      return false
    }
  }
  true
}

fn is_hex_digits(value : String) -> Bool {
  if value.length() == 0 {
    return false
  }
  for ch in value {
    if (ch < '0' || ch > '9') && (ch < 'a' || ch > 'f') && (ch < 'A' || ch > 'F') {
      return false
    }
  }
  true
}

fn is_unreserved_char(ch : Char) -> Bool {
  (ch >= 'a' && ch <= 'z') ||
  (ch >= 'A' && ch <= 'Z') ||
  (ch >= '0' && ch <= '9') ||
  ch == '-' ||
  ch == '.' ||
  ch == '_' ||
  ch == '~'
}

fn is_sub_delim_char(ch : Char) -> Bool {
  ch == '!' ||
  ch == '$' ||
  ch == '&' ||
  ch == '\'' ||
  ch == '(' ||
  ch == ')' ||
  ch == '*' ||
  ch == '+' ||
  ch == ',' ||
  ch == ';' ||
  ch == '='
}

fn is_hex_char(ch : Char) -> Bool {
  (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F')
}

fn hex_char_value(ch : Char) -> Int {
  if ch >= '0' && ch <= '9' {
    return ch.to_int() - '0'.to_int()
  }
  if ch >= 'a' && ch <= 'f' {
    return ch.to_int() - 'a'.to_int() + 10
  }
  if ch >= 'A' && ch <= 'F' {
    return ch.to_int() - 'A'.to_int() + 10
  }
  -1
}

/// Decode `%HH` escapes, leaving malformed escapes untouched. Callers validate
/// the input first, so this only has to handle well-formed escapes.
fn percent_decode_bytes(value : String) -> Bytes {
  let data = @utf8.encode(value)
  let output = Buffer(size_hint=data.length())
  let mut index = 0
  while index < data.length() {
    let byte = data[index]
    if byte == b'%' && index + 2 < data.length() {
      let high = hex_char_value(Char::from_int(data[index + 1].to_int()))
      let low = hex_char_value(Char::from_int(data[index + 2].to_int()))
      if high >= 0 && low >= 0 {
        output.write_byte(((high << 4) | low).to_byte())
        index = index + 3
        continue
      }
    }
    output.write_byte(byte)
    index = index + 1
  }
  output.to_bytes()
}

/// Whether a host is made only of digits and dots. Such a host is intended as
/// an IPv4 literal even when it is malformed (for example a leading-zero octet
/// or an out-of-range octet), so it must never be treated as a DNS suffix.
fn is_numeric_dotted_host(value : String) -> Bool {
  let mut saw_digit = false
  let mut saw_dot = false
  for ch in value {
    if ch == '.' {
      saw_dot = true
    } else if ch >= '0' && ch <= '9' {
      saw_digit = true
    } else {
      return false
    }
  }
  saw_digit && saw_dot
}

fn is_ipv4_literal(value : String) -> Bool {
  let parts = value.split(".").collect()
  if parts.length() != 4 {
    return false
  }
  for part in parts {
    let part = part.to_owned()
    if part.length() == 0 || part.length() > 3 || !is_decimal_digits(part) {
      return false
    }
    if part.length() > 1 && part.get_char(0) == Some('0') {
      return false
    }
    let mut octet = 0
    for ch in part {
      octet = octet * 10 + (ch.to_int() - '0'.to_int())
    }
    if octet > 255 {
      return false
    }
  }
  true
}

fn is_zone_id(value : String) -> Bool {
  if value.length() == 0 {
    return false
  }
  let mut index = 0
  while index < value.length() {
    let ch = match value.get_char(index) {
      Some(ch) => ch
      None => return false
    }
    if is_unreserved_char(ch) {
      index = index + 1
      continue
    }
    if ch == '%' {
      if index + 2 >= value.length() {
        return false
      }
      let high = match value.get_char(index + 1) {
        Some(ch) => ch
        None => return false
      }
      let low = match value.get_char(index + 2) {
        Some(ch) => ch
        None => return false
      }
      if !is_hex_char(high) || !is_hex_char(low) {
        return false
      }
      index = index + 3
      continue
    }
    return false
  }
  true
}

fn ipv6_group_count(value : String, allow_ipv4_tail : Bool) -> Int {
  if value.length() == 0 {
    return 0
  }
  let parts = value.split(":").collect()
  let mut groups = 0
  let mut index = 0
  for part in parts {
    let part = part.to_owned()
    index = index + 1
    if part.length() == 0 {
      return -1
    }
    if allow_ipv4_tail && index == parts.length() && part.contains(".") {
      if !is_ipv4_literal(part) {
        return -1
      }
      groups = groups + 2
    } else {
      if part.length() > 4 || !is_hex_digits(part) {
        return -1
      }
      groups = groups + 1
    }
  }
  groups
}

fn is_ipv6_literal(value : String) -> Bool {
  match value.find("::") {
    Some(index) => {
      let right = value[index + 2:].to_owned()
      if right.contains("::") {
        return false
      }
      let left_groups = ipv6_group_count(value[0:index].to_owned(), false)
      let right_groups = ipv6_group_count(right, true)
      left_groups >= 0 && right_groups >= 0 && left_groups + right_groups < 8
    }
    None => ipv6_group_count(value, true) == 8
  }
}

fn is_ipvfuture_literal(value : String) -> Bool {
  if value.length() < 3 {
    return false
  }
  let first = match value.get_char(0) {
    Some(ch) => ch
    None => return false
  }
  if first != 'v' && first != 'V' {
    return false
  }
  let dot = match value.find(".") {
    Some(index) => index
    None => return false
  }
  if dot <= 1 || dot == value.length() - 1 {
    return false
  }
  if !is_hex_digits(value[1:dot].to_owned()) {
    return false
  }
  for ch in value[dot + 1:] {
    if !is_unreserved_char(ch) && !is_sub_delim_char(ch) && ch != ':' {
      return false
    }
  }
  true
}

fn is_ipv6_literal_with_zone(value : String) -> Bool {
  let mut address = value
  match value.find("%") {
    Some(index) => {
      if index == 0 || index == value.length() - 1 {
        return false
      }
      let zone = value[index + 1:].to_owned()
      let zone = if zone.has_prefix("25") {
        zone[2:].to_owned()
      } else {
        zone
      }
      if !is_zone_id(zone) {
        return false
      }
      address = value[0:index].to_owned()
    }
    None => ()
  }
  is_ipv6_literal(address)
}

fn is_ip_literal(value : String) -> Bool {
  is_ipvfuture_literal(value) || is_ipv6_literal_with_zone(value)
}

/// Fold a host to lowercase without changing the case of an IPv6 zone
/// identifier. Zone identifiers name local interfaces on Unix, where names
/// are case-sensitive; the address portion remains case-insensitive.
fn lowercase_host_preserving_zone(host : String) -> String {
  if host.has_prefix("[") {
    match host.find("]") {
      Some(close) => {
        if close > 1 {
          let inner = host[1:close].to_owned()
          if is_ipv6_literal_with_zone(inner) {
            match inner.find("%") {
              Some(index) => {
                let address = inner[0:index].to_owned().to_lower()
                let zone = inner[index:].to_owned()
                let suffix = host[close:].to_owned()
                return "[" + address + zone + suffix
              }
              None => ()
            }
          }
        }
      }
      None => ()
    }
    return host.to_lower()
  }
  if !is_ipv6_literal_with_zone(host) {
    return host.to_lower()
  }
  match host.find("%") {
    Some(index) => {
      let address = host[0:index].to_owned().to_lower()
      let zone = host[index:].to_owned()
      address + zone
    }
    None => host.to_lower()
  }
}
