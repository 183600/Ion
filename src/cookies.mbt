/// Maximum serialized size of a single `Set-Cookie` value. RFC 6265 §6.1
/// requires implementations to support at least 4096 bytes per cookie; larger
/// cookies are ignored rather than partially stored.
const MAX_COOKIE_BYTES : Int = 4096

/// RFC 6265 §6.1 requires supporting at least 50 cookies per domain and
/// 3000 cookies overall. Older cookies are evicted first to stay within
/// those bounds.
const MAX_COOKIES_PER_DOMAIN : Int = 50
const MAX_TOTAL_COOKIES : Int = 3000

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
  // Whether the authority used a bracketed IP-literal form. Bracketed
  // IPvFuture literals look like DNS names but are distinct authorities.
  priv bracketed : Bool
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
  let result : Array[Cookie] = []
  for cookie in self.cookies {
    if !cookie_expired(cookie, now_ms) {
      result.push(cookie)
    }
  }
  result.sort_by(fn(a, b) { a.creation - b.creation })
  @list.List(result[:])
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
fn cookie_octet(ch : Char) -> Bool {
  ch == '!' || (ch >= '#' && ch <= '+') || (ch >= '-' && ch <= ':') ||
  (ch >= '<' && ch <= '[') || (ch >= ']' && ch <= '~')
}

fn cookie_valid_value(value : String) -> Bool {
  // RFC 6265 §4.1.1 allows `*cookie-octet` or a double-quoted
  // `*cookie-octet`. Whitespace, commas, backslashes and non-ASCII bytes are
  // not cookie-octets and would make the resulting Cookie header ambiguous.
  let body = if value.length() >= 2 && value.get_char(0) == Some('"') &&
    value.get_char(value.length() - 1) == Some('"') {
    value[1:value.length() - 1]
  } else {
    value
  }
  for ch in body {
    if !cookie_octet(ch) {
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
  // RFC 6265 §5.1.4 step 2: a uri-path that is empty or does not start with
  // "/" has the default-path "/" regardless of its contents.
  if url.path.length() == 0 || !url.path.has_prefix("/") {
    return "/"
  }
  match url.path.rev_find("/") {
    Some(index) => if index == 0 { "/" } else { url.path[0:index].to_owned() }
    None => "/"
  }
}

/// Whether bracketing distinguishes this cookie's authority. IPv4 and IPv6
/// literals have canonical textual forms, so their bracketed and unbracketed
/// spellings denote the same authority. Bracketed IPvFuture text, however,
/// looks like a DNS name and must stay distinct from that name.
fn cookie_bracket_identity(bracketed : Bool, domain : String) -> Bool {
  bracketed && !is_ipv4_literal(domain) &&
  !is_ipv6_literal_with_zone(domain)
}

///|
fn cookie_same_identity(a : Cookie, b : Cookie) -> Bool {
  // RFC 6265bis §5.7 includes the host-only flag in cookie identity, so a
  // host-only cookie and a domain cookie can coexist under the same name.
  a.name == b.name &&
  a.domain == b.domain &&
  a.path == b.path &&
  a.host_only == b.host_only &&
  cookie_bracket_identity(a.bracketed, a.domain) ==
  cookie_bracket_identity(b.bracketed, b.domain)
}

/// Whether `host` falls inside the scope of `cookie`'s domain. This is the
/// §5.1.3 domain-match relation applied to another cookie's domain, used by
/// the secure-cookie overlay protection below.
fn cookie_domain_scope_matches(
  cookie : Cookie,
  host : String,
  bracketed : Bool,
) -> Bool {
  let literal_host = bracketed || is_ipv4_literal(host) ||
    is_numeric_dotted_host(host) || is_ipv6_literal_with_zone(host)
  cookie_domain_matches(cookie, host, literal_host, bracketed)
}

/// Whether a new non-secure cookie would overlay an existing secure cookie.
/// RFC 6265bis §5.7 step 16 compares domains with domain-match (in either
/// direction) and checks that the new path path-matches the old one; exact
/// string equality would let a longer path or a sibling domain shadow the
/// secure cookie.
fn cookie_overlays_secure(existing : Cookie, candidate : Cookie) -> Bool {
  candidate.name == existing.name &&
  existing.secure &&
  cookie_bracket_identity(existing.bracketed, existing.domain) ==
  cookie_bracket_identity(candidate.bracketed, candidate.domain) &&
  (cookie_domain_scope_matches(existing, candidate.domain, candidate.bracketed) ||
    cookie_domain_scope_matches(candidate, existing.domain, existing.bracketed)) &&
  cookie_path_matches(existing.path, candidate.path)
}

///|
fn cookie_expired(cookie : Cookie, now_ms : UInt64) -> Bool {
  match cookie.expires_at_ms {
    Some(expires) => expires <= now_ms
    None => false
  }
}

///|
fn cookie_canonical_host(host : String) -> String {
  let host = host.to_lower()
  if host.length() > 1 && host.has_suffix(".") {
    host[0:host.length() - 1].to_owned()
  } else {
    host
  }
}

///|
fn cookie_domain_matches(
  cookie : Cookie,
  host : String,
  literal_host : Bool,
  bracketed : Bool,
) -> Bool {
  let host = cookie_canonical_host(host)
  if cookie.host_only {
    if host != cookie.domain {
      return false
    }
    // IPv4 and IPv6 literals have a canonical textual form, so their bracketed
    // and unbracketed spellings denote the same authority. A bracketed
    // IPvFuture literal, however, looks like a DNS name and must remain
    // distinct from that DNS name.
    let bracketed_matters = !is_ipv4_literal(host) &&
      !is_ipv6_literal_with_zone(host)
    return !bracketed_matters || cookie.bracketed == bracketed
  }
  // RFC 6265 §5.1.3 only allows domain cookies to match host names, never
  // IP literals. The caller distinguishes bracketed IPvFuture literals (whose
  // text looks like a DNS name) from real DNS names.
  if literal_host {
    return false
  }
  if host == cookie.domain {
    return true
  }
  !is_ipv4_literal(host) && !is_ipv6_literal_with_zone(host) &&
  host.has_suffix("." + cookie.domain)
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
// RFC 6265 §5.1.1: date-tokens are separated by any delimiter character,
// not just spaces. Colons remain inside time tokens.
fn cookie_is_date_delimiter(ch : Char) -> Bool {
  ch == '\t' || (ch >= ' ' && ch <= '/') || (ch >= ';' && ch <= '@') ||
  (ch >= '[' && ch <= '`') || (ch >= '{' && ch <= '~')
}

///|
fn cookie_date_tokens(value : String) -> Array[String] {
  let tokens : Array[String] = []
  let mut start = 0
  let mut index = 0
  while index < value.length() {
    let delimiter = match value.get_char(index) {
      Some(ch) => cookie_is_date_delimiter(ch)
      None => false
    }
    if delimiter {
      if index > start {
        tokens.push(value[start:index].to_owned())
      }
      start = index + 1
    }
    index = index + 1
  }
  if start < value.length() {
    tokens.push(value[start:].to_owned())
  }
  tokens
}

///|
fn cookie_month(value : String) -> Int32? {
  // RFC 6265 §5.1.1: month = ( "jan" / ... / "dec" ) *OCTET. Only the
  // three-letter prefix is significant, so both "Sept" and "September" work.
  let lower = value.to_lower()
  let prefix = if lower.length() > 3 {
    lower[0:3].to_owned()
  } else {
    lower
  }
  match prefix {
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

/// Parse between `min` and `max` leading digits. RFC 6265 date productions
/// allow the digits to be followed by `non-digit *OCTET`, so the remainder is
/// accepted as long as it does not start with another digit.
fn cookie_leading_number(value : String, min_digits : Int, max_digits : Int) -> Int32? {
  let mut index = 0
  let mut number : Int32 = 0
  while index < value.length() && index < max_digits {
    let ch = match value.get_char(index) {
      Some(ch) => ch
      None => break
    }
    if ch < '0' || ch > '9' {
      break
    }
    number = number * 10 + (ch.to_int() - '0'.to_int())
    index = index + 1
  }
  if index < min_digits {
    return None
  }
  if index < value.length() {
    let next = value.get_char(index)
    if next is Some(ch) && ch >= '0' && ch <= '9' {
      return None
    }
  }
  Some(number)
}

///|
fn cookie_parse_year(value : String) -> Int32? {
  // RFC 6265 §5.1.1 defines a year as 2*4DIGIT plus an optional non-digit
  // suffix. Normalize two-digit years the way the algorithm requires.
  let year = match cookie_leading_number(value, 2, 4) {
    Some(year) => year
    None => return None
  }
  let normalized = if year < 100 {
    if year >= 70 {
      1900 + year
    } else {
      2000 + year
    }
  } else {
    year
  }
  // A token matching the year grammar but outside 1601..9999 makes the whole
  // cookie-date invalid (RFC 6265 §5.1.1 step 5); it is not an unrecognized
  // token that may simply be skipped in favor of a later year.
  Some(normalized)
}

/// Whether a token has the shape of an RFC 6265 hms-time production,
/// independent of whether its fields are in range. This distinction matters:
/// a token that matches the time grammar but has an invalid minute is a hard
/// date-parse failure, while a token that does not match the time grammar may
/// legitimately fall through to the day-of-month production.
fn cookie_is_time_token(value : String) -> Bool {
  let first_colon = match value.find(":") {
    Some(index) => index
    None => return false
  }
  let rest = value[first_colon + 1:].to_owned()
  let second_colon = match rest.find(":") {
    Some(index) => index
    None => return false
  }
  let hour_text = value[0:first_colon].to_owned()
  let minute_text = rest[0:second_colon].to_owned()
  let second_text = rest[second_colon + 1:].to_owned()
  if hour_text.length() < 1 || hour_text.length() > 2 ||
    minute_text.length() < 1 || minute_text.length() > 2 {
    return false
  }
  if cookie_parse_decimal(hour_text) is None ||
    cookie_parse_decimal(minute_text) is None ||
    cookie_leading_number(second_text, 1, 2) is None {
    return false
  }
  true
}

///|
fn cookie_parse_clock(value : String) -> (Int32, Int32, Int32)? {
  // RFC 6265 time = hms-time [ non-digit *OCTET ].
  let first_colon = match value.find(":") {
    Some(index) => index
    None => return None
  }
  let rest = value[first_colon + 1:].to_owned()
  let second_colon = match rest.find(":") {
    Some(index) => index
    None => return None
  }
  let hour_text = value[0:first_colon].to_owned()
  let minute_text = rest[0:second_colon].to_owned()
  let second_text = rest[second_colon + 1:].to_owned()
  if hour_text.length() < 1 || hour_text.length() > 2 ||
    minute_text.length() < 1 || minute_text.length() > 2 {
    return None
  }
  let hour = match cookie_parse_decimal(hour_text) {
    Some(value) => value
    None => return None
  }
  let minute = match cookie_parse_decimal(minute_text) {
    Some(value) => value
    None => return None
  }
  let second = match cookie_leading_number(second_text, 1, 2) {
    Some(value) => value
    None => return None
  }
  if hour > 23 || minute > 59 || second > 59 {
    return None
  }
  Some((hour, minute, second))
}

///|
fn cookie_days_in_month(year : Int32, month : Int32) -> Int32 {
  match month {
    2 =>
      if (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 {
        29
      } else {
        28
      }
    4 | 6 | 9 | 11 => 30
    _ => 31
  }
}

///|
fn cookie_make_time(
  year : Int32,
  month : Int32,
  day : Int32,
  clock : (Int32, Int32, Int32),
) -> UInt64? {
  if day < 1 || day > cookie_days_in_month(year, month) {
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
/// Parse an `Expires` value using the RFC 6265 §5.1.1 date algorithm: split
/// on delimiter characters, then consume the first token matching the time,
/// day-of-month, month and year productions. Tokens that match no production
/// (weekdays, zones, junk) are ignored.
fn cookie_parse_date(value : String) -> UInt64? {
  let text = value.trim().to_owned()
  if text.length() == 0 {
    return None
  }
  let tokens = cookie_date_tokens(text)
  let mut day : Int32? = None
  let mut month : Int32? = None
  let mut year : Int32? = None
  let mut clock : (Int32, Int32, Int32)? = None
  for token in tokens {
    // A time token that matches the grammar but has an out-of-range field is
    // fatal while no clock has been found yet: reinterpreting it as a
    // day-of-month would silently accept a malformed date. Once a valid clock
    // exists, however, a later malformed time-shaped token must not discard
    // the otherwise complete date. Valid repeated time tokens retain the
    // historical last-one-wins behavior.
    if cookie_is_time_token(token) {
      match cookie_parse_clock(token) {
        Some(value) => {
          clock = Some(value)
          continue
        }
        None =>
          if clock is None {
            // The token matches the time grammar but has an out-of-range
            // field, so the date is invalid rather than a day-of-month.
            return None
          }
        // A valid clock is already set. RFC 6265 §5.1.1 only skips the time
        // production once found-time is set, so this token still gets a
        // chance to match the day-of-month production below.
      }
    }
    if day is None {
      match cookie_leading_number(token, 1, 2) {
        Some(value) => {
          day = Some(value)
          continue
        }
        None => ()
      }
    }
    if month is None {
      match cookie_month(token) {
        Some(value) => {
          month = Some(value)
          continue
        }
        None => ()
      }
    }
    if year is None {
      match cookie_parse_year(token) {
        Some(value) => {
          if value < 1601 || value > 9999 {
            return None
          }
          year = Some(value)
          continue
        }
        None => ()
      }
    }
  }
  let day = match day {
    Some(value) => value
    None => return None
  }
  let month = match month {
    Some(value) => value
    None => return None
  }
  let year = match year {
    Some(value) => value
    None => return None
  }
  let clock = match clock {
    Some(value) => value
    None => return None
  }
  if day < 1 || day > 31 {
    return None
  }
  cookie_make_time(year, month, day, clock)
}

///|
fn cookie_parse_max_age(value : String) -> Int64? {
  let text = value.trim().to_owned()
  if text.length() == 0 {
    return None
  }
  let negative = text.get_char(0) == Some('-')
  let digits = if negative { text[1:].to_owned() } else { text }
  if !is_decimal_digits(digits) {
    return None
  }
  let seconds = try {
    @string.parse_int64(text[:])
  } catch {
    _ => if negative { -1L } else { 9223372036854775807L }
  }
  Some(seconds)
}

///|
fn cookie_from_set_cookie(
  url : Url,
  value : String,
  now_ms : UInt64,
) -> Cookie? {
  if @utf8.encode(value).length() > MAX_COOKIE_BYTES {
    return None
  }
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
  let host = cookie_canonical_host(url.host)
  let mut domain = host
  let mut host_only = true
  let mut path = cookie_default_path(url)
  let mut secure = false
  let mut same_site_none = false
  let mut expires_at_ms : UInt64? = None
  let mut max_age_seen = false
  let mut domain_attribute_seen = false
  let mut domain_attribute : String? = None
  let mut path_attribute_seen = false
  let mut path_attribute_is_root = false
  let mut index = 1
  while index < parts.length() {
    let (raw_attribute, raw_attribute_value) = cookie_split_first(
      parts[index].to_owned(),
      '=',
    )
    let attribute = raw_attribute.trim().to_lower()
    let attribute_value = raw_attribute_value.trim().to_owned()
    // RFC 6265bis §5.5: an attribute whose value is longer than 1024 octets
    // is ignored as a whole, regardless of its name. In particular it must not
    // affect expiry, security, or the selected path.
    if @utf8.encode(attribute_value).length() > 1024 {
      index = index + 1
      continue
    }
    if attribute == "domain" {
      let mut candidate = attribute_value.to_lower()
      if candidate.has_prefix(".") {
        candidate = candidate[1:].to_owned()
      }
      // Overlong attribute values were ignored by the parser above. An empty
      // value (including a lone leading dot) is ignored entirely, so it must
      // not discard an earlier valid Domain attribute.
      if candidate.length() > 0 {
        domain_attribute_seen = true
        domain_attribute = Some(candidate)
      }
    } else if attribute == "path" {
      // RFC 6265 §5.2.4: an empty Path or one that does not begin with "/"
      // resolves to the default-path. The last Path attribute wins.
      path = if attribute_value.has_prefix("/") {
        attribute_value
      } else {
        cookie_default_path(url)
      }
      path_attribute_seen = true
      path_attribute_is_root = attribute_value == "/"
    } else if attribute == "secure" {
      secure = true
    } else if attribute == "samesite" {
      // RFC 6265bis §5.5.7: an unrecognized value means "Default". The last
      // SameSite attribute wins, and only "None" changes storage here.
      same_site_none = attribute_value.to_lower() == "none"
    } else if attribute == "max-age" {
      match cookie_parse_max_age(attribute_value) {
        Some(seconds) => {
          max_age_seen = true
          if seconds <= 0 {
            expires_at_ms = Some(0)
          } else {
            let max_ms = 0xFFFFFFFFFFFFFFFFUL
            let seconds = seconds.to_uint64()
            if seconds > (max_ms - now_ms) / 1000UL {
              expires_at_ms = Some(max_ms)
            } else {
              expires_at_ms = Some(now_ms + seconds * 1000UL)
            }
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
  // Apply the last Domain attribute. RFC 6265 §5.2.3/§5.3: an empty Domain
  // is ignored, leaving the cookie host-only.
  match domain_attribute {
    Some(candidate) =>
      if candidate.length() > 0 {
        if candidate.has_suffix(".") {
          // A trailing root dot cannot domain-match the canonical request
          // host, so the whole cookie is ignored.
          return None
        }
        let single_label = !candidate.contains(".")
        if single_label && candidate != host {
          // A single-label Domain such as "com" is a public suffix, not a
          // domain the request host can control. Reject it so a site cannot
          // set a supercookie for every host under that label. A single-label
          // request host itself (for example "localhost") remains usable, but
          // must still become a host-only cookie.
          return None
        }
        // Bracketed IPvFuture literals have DNS-looking text but are still IP
        // literals; they must never be treated as a domain suffix.
        let literal_host = url.bracketed || is_ipv4_literal(host) ||
          is_numeric_dotted_host(host) || is_ipv6_literal_with_zone(host)
        if valid_url_host_chars(candidate) &&
          (host == candidate ||
            (!literal_host && host.has_suffix("." + candidate))) {
          domain = candidate
          // RFC 6265bis: a Domain attribute for an IP address host, or for a
          // public-suffix label identical to the request host, is ignored,
          // leaving the cookie host-only instead of domain-scoped.
          host_only = literal_host || single_label
        } else {
          // A Domain attribute that does not cover the request host must not
          // be stored, otherwise a response could set cookies for other sites.
          return None
        }
      }
    None => ()
  }
  // RFC 6265 §5.3: a non-secure origin must not be able to set a Secure
  // cookie, even though the jar would never send it over plain HTTP.
  if secure && !url.is_secure() {
    return None
  }
  // RFC 6265bis §5.6 step 19: SameSite=None is only meaningful for a Secure
  // cookie. Without the Secure attribute the cookie must be ignored.
  if same_site_none && !secure {
    return None
  }
  // RFC 6265bis §4.1.3: prefixes let servers ask clients to enforce stronger
  // guarantees than the cookie syntax alone provides. Prefix matching is
  // case-insensitive so a differently capitalized name cannot bypass them.
  let lower_name = name.to_lower()
  if lower_name.has_prefix("__secure-") && !secure {
    return None
  }
  if lower_name.has_prefix("__host-") &&
    (!secure ||
      !host_only ||
      !path_attribute_seen ||
      !path_attribute_is_root ||
      path != "/" ||
      domain_attribute_seen) {
    return None
  }
  Some(Cookie::{
    name,
    value,
    domain,
    path,
    secure,
    host_only,
    bracketed: url.bracketed,
    expires_at_ms,
    creation: 0,
  })
}

///|
fn cookie_oldest_in_domain(cookies : List[Cookie], domain : String) -> Cookie? {
  let mut oldest : Cookie? = None
  for candidate in cookies {
    if candidate.domain != domain {
      continue
    }
    oldest = match oldest {
      Some(current) =>
        if candidate.creation < current.creation {
          Some(candidate)
        } else {
          Some(current)
        }
      None => Some(candidate)
    }
  }
  oldest
}

///|
fn cookie_oldest(cookies : List[Cookie]) -> Cookie? {
  let mut oldest : Cookie? = None
  for candidate in cookies {
    oldest = match oldest {
      Some(current) =>
        if candidate.creation < current.creation {
          Some(candidate)
        } else {
          Some(current)
        }
      None => Some(candidate)
    }
  }
  oldest
}

///|
fn cookie_evict_for_capacity(
  cookies : List[Cookie],
  domain : String,
) -> List[Cookie] {
  let mut result = cookies
  let mut domain_count = 0
  for existing in result {
    if existing.domain == domain {
      domain_count = domain_count + 1
    }
  }
  while domain_count >= MAX_COOKIES_PER_DOMAIN {
    let oldest = match cookie_oldest_in_domain(result, domain) {
      Some(cookie) => cookie
      None => break
    }
    result = result.filter(fn(cookie) { cookie.creation != oldest.creation })
    domain_count = domain_count - 1
  }
  while result.length() >= MAX_TOTAL_COOKIES {
    let oldest = match cookie_oldest(result) {
      Some(cookie) => cookie
      None => break
    }
    result = result.filter(fn(cookie) { cookie.creation != oldest.creation })
  }
  result
}

///|
fn CookieJar::store_parsed(
  self : CookieJar,
  cookie : Cookie,
  now_ms : UInt64,
  from_secure : Bool,
) -> Unit {
  if !from_secure {
    for existing in self.cookies {
      if !cookie_expired(existing, now_ms) &&
        cookie_overlays_secure(existing, cookie) {
        return
      }
    }
  }
  let mut remaining = @list.List([])
  let mut preserved_creation : Int? = None
  for existing in self.cookies {
    if cookie_same_identity(existing, cookie) {
      if !cookie_expired(existing, now_ms) {
        preserved_creation = Some(existing.creation)
      }
    } else if !cookie_expired(existing, now_ms) {
      remaining = remaining.prepend(existing)
    }
  }
  if !cookie_expired(cookie, now_ms) {
    let creation = match preserved_creation {
      Some(creation) => creation
      None => {
        let creation = self.next_creation
        self.next_creation = creation + 1
        creation
      }
    }
    let remaining = cookie_evict_for_capacity(remaining, cookie.domain)
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
    Some(cookie) => self.store_parsed(cookie, now_ms, url.is_secure())
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
  // Classify literals from the canonical host so a trailing root dot cannot
  // make an IP address look like a DNS name. Otherwise a domain cookie that
  // was legitimately set from a DNS name such as `foo.127.0.0.1` could be
  // replayed to the literal address `127.0.0.1.`.
  let host = cookie_canonical_host(url.host)
  let literal_host = url.bracketed || is_ipv4_literal(host) ||
    is_numeric_dotted_host(host) || is_ipv6_literal_with_zone(host)
  let candidates : Array[Cookie] = []
  let mut alive = @list.List([])
  for cookie in self.cookies {
    if cookie_expired(cookie, now_ms) {
      continue
    }
    alive = alive.prepend(cookie)
    if cookie_domain_matches(cookie, host, literal_host, url.bracketed) &&
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
