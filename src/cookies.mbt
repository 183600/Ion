/// Minimal RFC 6265 cookie jar.
///
/// It supports the parts of the standard that matter for an HTTP client:
/// host-only and domain cookies, path matching, `Secure`, `Max-Age`, `Expires`
/// and deletion by overwriting a cookie with an already expired one. The jar is
/// opt-in; callers enable it through `UnifiedClient::with_cookies`.

///|
/// A single stored cookie.
pub struct Cookie {
  name : String
  value : String
  domain : String
  path : String
  secure : Bool
  host_only : Bool
  expires_at_ms : UInt64?
  creation : Int32
} derive(Eq, Debug)

///|
/// An in-memory cookie store.
pub struct CookieJar {
  mut cookies : List[Cookie]
  mut next_creation : Int32
} derive(Eq, Debug)

///|
pub fn CookieJar::new() -> CookieJar {
  CookieJar::{ cookies: @list.List([]), next_creation: 0, }
}

///|
/// Number of non-expired cookies currently stored.
pub fn CookieJar::length(self : CookieJar) -> Int32 {
  let now_ms = @env.now()
  let mut count = 0
  for cookie in self.cookies {
    if !cookie_expired(cookie, now_ms) {
      count = count + 1
    }
  }
  count
}

///|
/// Remove every stored cookie.
pub fn CookieJar::clear(self : CookieJar) -> Unit {
  self.cookies = @list.List([])
}

///|
/// Snapshot of the stored cookies. Expired cookies are omitted.
pub fn CookieJar::cookies(self : CookieJar) -> List[Cookie] {
  let now_ms = @env.now()
  let mut result = @list.List([])
  for cookie in self.cookies {
    if !cookie_expired(cookie, now_ms) {
      result = result.prepend(cookie)
    }
  }
  result
}

///|
fn cookie_token_char(ch : Char) -> Bool {
  if (ch >= 'a' && ch <= 'z') ||
    (ch >= 'A' && ch <= 'Z') ||
    (ch >= '0' && ch <= '9') {
    return true
  }
  match ch {
    '!'
    | '#'
    | '$'
    | '%'
    | '&'
    | '\''
    | '*'
    | '+'
    | '-'
    | '.'
    | '^'
    | '_'
    | '`'
    | '|'
    | '~' => true
    _ => false
  }
}

///|
fn cookie_valid_name(name : String) -> Bool {
  if name.length() == 0 {
    return false
  }
  for ch in name {
    if !cookie_token_char(ch) {
      return false
    }
  }
  true
}

///|
fn cookie_valid_value(value : String) -> Bool {
  for ch in value {
    if ch < ' ' || ch == '\u{7f}' || ch == ';' {
      return false
    }
  }
  true
}

///|
fn cookie_split_first(value : String, delimiter : Char) -> (String, String) {
  match value.find(delimiter.to_string()) {
    Some(index) => (value[0:index].to_owned(), value[index + 1:].to_owned())
    None => (value, "")
  }
}

///|
fn cookie_default_path(url : Url) -> String {
  let path = if url.path.length() == 0 {
    "/"
  } else if url.path.has_prefix("/") {
    url.path
  } else {
    "/" + url.path
  }
  match path.rev_find("/") {
    Some(index) => if index == 0 { "/" } else { path[0:index].to_owned() }
    None => "/"
  }
}

///|
fn cookie_same_identity(a : Cookie, b : Cookie) -> Bool {
  a.name == b.name && a.domain == b.domain && a.path == b.path
}

///|
fn cookie_expired(cookie : Cookie, now_ms : UInt64) -> Bool {
  match cookie.expires_at_ms {
    Some(expires) => expires <= now_ms
    None => false
  }
}

///|
fn cookie_domain_matches(cookie : Cookie, host : String) -> Bool {
  let host = host.to_lower()
  if cookie.host_only {
    host == cookie.domain
  } else {
    host == cookie.domain || host.has_suffix("." + cookie.domain)
  }
}

///|
fn cookie_path_matches(cookie_path : String, request_path : String) -> Bool {
  if request_path == cookie_path {
    return true
  }
  if !request_path.has_prefix(cookie_path) {
    return false
  }
  if cookie_path.has_suffix("/") {
    return true
  }
  request_path.get_char(cookie_path.length()) == Some('/')
}

///|
fn cookie_trimmed_tokens(value : String) -> Array[String] {
  let tokens : Array[String] = []
  for part in value.split(" ") {
    let token = part.trim().to_owned()
    if token.length() > 0 {
      tokens.push(token)
    }
  }
  tokens
}

///|
fn cookie_month(value : String) -> Int32? {
  match value.to_lower() {
    "jan" => Some(1)
    "feb" => Some(2)
    "mar" => Some(3)
    "apr" => Some(4)
    "may" => Some(5)
    "jun" => Some(6)
    "jul" => Some(7)
    "aug" => Some(8)
    "sep" => Some(9)
    "oct" => Some(10)
    "nov" => Some(11)
    "dec" => Some(12)
    _ => None
  }
}

///|
fn cookie_weekday(value : String) -> Bool {
  let value = value.trim().to_owned()
  let value = if value.has_suffix(",") {
    value[0:value.length() - 1].to_owned()
  } else {
    value
  }
  match value.to_lower() {
    "mon"
    | "monday"
    | "tue"
    | "tuesday"
    | "wed"
    | "wednesday"
    | "thu"
    | "thursday"
    | "fri"
    | "friday"
    | "sat"
    | "saturday"
    | "sun"
    | "sunday" => true
    _ => false
  }
}

///|
fn cookie_days_from_civil(year : Int32, month : Int32, day : Int32) -> Int32 {
  let year = if month <= 2 { year - 1 } else { year }
  let era = (if year >= 0 { year } else { year - 399 }) / 400
  let year_of_era = year - era * 400
  let month_index = if month > 2 { month - 3 } else { month + 9 }
  let day_of_year = (153 * month_index + 2) / 5 + day - 1
  let day_of_era = year_of_era * 365 +
    year_of_era / 4 -
    year_of_era / 100 +
    day_of_year
  era * 146097 + day_of_era - 719468
}

///|
fn cookie_parse_decimal(value : String) -> Int32? {
  if value.length() == 0 {
    return None
  }
  for ch in value {
    if ch < '0' || ch > '9' {
      return None
    }
  }
  let parsed = @string.parse_int(value[:]) catch { _ => return None }
  if parsed < 0 {
    return None
  }
  Some(parsed)
}

///|
fn cookie_parse_year(value : String) -> Int32? {
  let year = match cookie_parse_decimal(value) {
    Some(year) => year
    None => return None
  }
  let normalized = if value.length() == 2 {
    if year >= 70 {
      1900 + year
    } else {
      2000 + year
    }
  } else {
    year
  }
  if normalized < 1970 || normalized > 9999 {
    return None
  }
  Some(normalized)
}

///|
fn cookie_parse_clock(value : String) -> (Int32, Int32, Int32)? {
  let parts = value.split(":").collect()
  if parts.length() != 3 {
    return None
  }
  let hour = match cookie_parse_decimal(parts[0].to_owned()) {
    Some(value) => value
    None => return None
  }
  let minute = match cookie_parse_decimal(parts[1].to_owned()) {
    Some(value) => value
    None => return None
  }
  let second = match cookie_parse_decimal(parts[2].to_owned()) {
    Some(value) => value
    None => return None
  }
  if hour > 23 || minute > 59 || second > 59 {
    return None
  }
  Some((hour, minute, second))
}

///|
fn cookie_make_time(
  year : Int32,
  month : Int32,
  day : Int32,
  clock : (Int32, Int32, Int32),
) -> UInt64? {
  if day < 1 || day > 31 {
    return None
  }
  let (hour, minute, second) = clock
  let days = cookie_days_from_civil(year, month, day)
  let seconds = days.to_int64() * 86400L +
    hour.to_int64() * 3600L +
    minute.to_int64() * 60L +
    second.to_int64()
  if seconds < 0 {
    return Some(0)
  }
  Some((seconds * 1000L).to_uint64())
}

///|
/// Parse the three date formats historically used by `Expires` (RFC 6265
/// §5.1.1): IMF-fixdate, RFC 850 and asctime.
fn cookie_parse_date(value : String) -> UInt64? {
  let text = value.trim().to_owned()
  if text.length() == 0 {
    return None
  }
  let mut tokens = cookie_trimmed_tokens(text)
  if tokens.length() > 0 && cookie_weekday(tokens[0]) {
    let rest : Array[String] = []
    let mut index = 1
    while index < tokens.length() {
      rest.push(tokens[index])
      index = index + 1
    }
    tokens = rest
  }
  if tokens.length() < 4 {
    return None
  }
  // RFC 850: "06-Nov-94 08:49:37 GMT" (the weekday was removed above).
  if tokens[0].contains("-") {
    let date_parts = tokens[0].split("-").collect()
    if date_parts.length() != 3 {
      return None
    }
    let day = match cookie_parse_decimal(date_parts[0].to_owned()) {
      Some(value) => value
      None => return None
    }
    let month = match cookie_month(date_parts[1].to_owned()) {
      Some(value) => value
      None => return None
    }
    let year = match cookie_parse_year(date_parts[2].to_owned()) {
      Some(value) => value
      None => return None
    }
    let clock = match cookie_parse_clock(tokens[1]) {
      Some(value) => value
      None => return None
    }
    return cookie_make_time(year, month, day, clock)
  }
  // IMF-fixdate starts with the day; asctime starts with the month name.
  if cookie_month(tokens[0]) is Some(_) {
    let month = cookie_month(tokens[0]).unwrap()
    let day = match cookie_parse_decimal(tokens[1]) {
      Some(value) => value
      None => return None
    }
    let clock = match cookie_parse_clock(tokens[2]) {
      Some(value) => value
      None => return None
    }
    let year = match cookie_parse_year(tokens[3]) {
      Some(value) => value
      None => return None
    }
    return cookie_make_time(year, month, day, clock)
  }
  let day = match cookie_parse_decimal(tokens[0]) {
    Some(value) => value
    None => return None
  }
  let month = match cookie_month(tokens[1]) {
    Some(value) => value
    None => return None
  }
  let year = match cookie_parse_year(tokens[2]) {
    Some(value) => value
    None => return None
  }
  let clock = match cookie_parse_clock(tokens[3]) {
    Some(value) => value
    None => return None
  }
  cookie_make_time(year, month, day, clock)
}

///|
fn cookie_parse_max_age(value : String) -> Int32? {
  let text = value.trim().to_owned()
  if text.length() == 0 {
    return None
  }
  let negative = text.get_char(0) == Some('-')
  let digits = if negative { text[1:].to_owned() } else { text }
  let seconds = match cookie_parse_decimal(digits) {
    Some(seconds) => seconds
    None => return None
  }
  if negative {
    Some(-seconds)
  } else {
    Some(seconds)
  }
}

///|
fn cookie_from_set_cookie(
  url : Url,
  value : String,
  now_ms : UInt64,
) -> Cookie? {
  let parts = value.split(";").collect()
  if parts.length() == 0 || !parts[0].contains("=") {
    return None
  }
  let (raw_name, raw_value) = cookie_split_first(parts[0].to_owned(), '=')
  let name = raw_name.trim().to_owned()
  let value = raw_value.trim().to_owned()
  if !cookie_valid_name(name) || !cookie_valid_value(value) {
    return None
  }
  let host = url.host.to_lower()
  let mut domain = host
  let mut host_only = true
  let mut path = cookie_default_path(url)
  let mut secure = false
  let mut expires_at_ms : UInt64? = None
  let mut max_age_seen = false
  let mut index = 1
  while index < parts.length() {
    let (raw_attribute, raw_attribute_value) = cookie_split_first(
      parts[index].to_owned(),
      '=',
    )
    let attribute = raw_attribute.trim().to_lower()
    let attribute_value = raw_attribute_value.trim().to_owned()
    if attribute == "domain" {
      let mut candidate = attribute_value.to_lower()
      if candidate.has_prefix(".") {
        candidate = candidate[1:].to_owned()
      }
      if candidate.length() > 0 &&
        !is_ip_literal(host) &&
        valid_url_host_chars(candidate) &&
        (host == candidate || host.has_suffix("." + candidate)) {
        domain = candidate
        host_only = false
      } else if candidate.length() > 0 {
        // A Domain attribute that does not cover the request host must not be
        // stored, otherwise a response could set cookies for other sites.
        return None
      }
    } else if attribute == "path" {
      if attribute_value.has_prefix("/") {
        path = attribute_value
      }
    } else if attribute == "secure" {
      secure = true
    } else if attribute == "max-age" {
      match cookie_parse_max_age(attribute_value) {
        Some(seconds) => {
          max_age_seen = true
          if seconds <= 0 {
            expires_at_ms = Some(0)
          } else {
            let delta = seconds.to_int64() * 1000L
            expires_at_ms = Some(now_ms + delta.to_uint64())
          }
        }
        None => ()
      }
    } else if attribute == "expires" {
      if !max_age_seen {
        match cookie_parse_date(attribute_value) {
          Some(expires) => expires_at_ms = Some(expires)
          None => ()
        }
      }
    }
    index = index + 1
  }
  Some(Cookie::{
    name,
    value,
    domain,
    path,
    secure,
    host_only,
    expires_at_ms,
    creation: 0,
  })
}

///|
fn CookieJar::store_parsed(
  self : CookieJar,
  cookie : Cookie,
  now_ms : UInt64,
) -> Unit {
  let mut remaining = @list.List([])
  for existing in self.cookies {
    if !cookie_same_identity(existing, cookie) &&
      !cookie_expired(existing, now_ms) {
      remaining = remaining.prepend(existing)
    }
  }
  if !cookie_expired(cookie, now_ms) {
    let creation = self.next_creation
    self.next_creation = creation + 1
    self.cookies = remaining.prepend(Cookie::{ ..cookie, creation, })
  } else {
    self.cookies = remaining
  }
}

///|
/// Store a single `Set-Cookie` header value for the response to `url`.
pub fn CookieJar::store(
  self : CookieJar,
  url : Url,
  set_cookie : String,
) -> Unit {
  self.store_at(url, set_cookie, @env.now())
}

///|
/// Like `store`, with an explicit clock for deterministic tests.
pub fn CookieJar::store_at(
  self : CookieJar,
  url : Url,
  set_cookie : String,
  now_ms : UInt64,
) -> Unit {
  match cookie_from_set_cookie(url, set_cookie, now_ms) {
    Some(cookie) => self.store_parsed(cookie, now_ms)
    None => ()
  }
}

///|
/// Store every `Set-Cookie` header from a response.
pub fn CookieJar::store_from_headers(
  self : CookieJar,
  url : Url,
  headers : Headers,
) -> Unit {
  let now_ms = @env.now()
  for value in headers.get_all("Set-Cookie") {
    self.store_at(url, value, now_ms)
  }
}

///|
/// Build the `Cookie` request header value for `url`, if any cookie matches.
pub fn CookieJar::cookie_header(self : CookieJar, url : Url) -> String? {
  self.cookie_header_at(url, @env.now())
}

///|
/// Like `cookie_header`, with an explicit clock for deterministic tests.
pub fn CookieJar::cookie_header_at(
  self : CookieJar,
  url : Url,
  now_ms : UInt64,
) -> String? {
  let request_path = if url.path.length() == 0 {
    "/"
  } else if url.path.has_prefix("/") {
    url.path
  } else {
    "/" + url.path
  }
  let secure = url.is_secure()
  let candidates : Array[Cookie] = []
  let mut alive = @list.List([])
  for cookie in self.cookies {
    if cookie_expired(cookie, now_ms) {
      continue
    }
    alive = alive.prepend(cookie)
    if cookie_domain_matches(cookie, url.host) &&
      cookie_path_matches(cookie.path, request_path) &&
      (!cookie.secure || secure) {
      candidates.push(cookie)
    }
  }
  self.cookies = alive
  if candidates.length() == 0 {
    return None
  }
  candidates.sort_by(fn(a, b) {
    let path_order = b.path.length() - a.path.length()
    if path_order != 0 {
      path_order
    } else {
      a.creation - b.creation
    }
  })
  let result = Buffer(size_hint=64)
  for cookie in candidates {
    if result.length() > 0 {
      result.write_bytes(@utf8.encode("; "))
    }
    result.write_bytes(@utf8.encode(cookie.name + "=" + cookie.value))
  }
  Some(@utf8.decode_lossy(result.to_bytes()[:]))
}
