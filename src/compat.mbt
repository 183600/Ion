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
