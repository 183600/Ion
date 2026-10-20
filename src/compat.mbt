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
