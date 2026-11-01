/// RFC 9111 cache directives.
pub struct CacheControl {
  mut no_store : Bool
  mut no_cache : Bool
  mut must_revalidate : Bool
  mut public_cache : Bool
  mut private_cache : Bool
  mut immutable : Bool
  mut max_age : Int?
  mut s_maxage : Int?
  mut max_stale : Int?
  mut min_fresh : Int?
  mut only_if_cached : Bool
} derive(Eq, Debug)

pub fn CacheControl::new() -> CacheControl {
  CacheControl::{
    no_store: false,
    no_cache: false,
    must_revalidate: false,
    public_cache: false,
    private_cache: false,
    immutable: false,
    max_age: None,
    s_maxage: None,
    max_stale: None,
    min_fresh: None,
    only_if_cached: false,
  }
}

fn cache_index_of_char(value : String, target : Char) -> Int? {
  let mut i = 0
  while i < value.length() {
    match value.get_char(i) {
      Some(ch) => {
        if ch == target {
          return Some(i)
        }
      }
      None => ()
    }
    i = i + 1
  }
  None
}

fn cache_split_directives(value : String) -> Array[String] {
  let parts : Array[Bytes] = []
  let buffer = @buffer.new(size_hint=value.length())
  let mut quoted = false
  let mut escaped = false
  for ch in value {
    if escaped {
      buffer.write_char_utf8(ch)
      escaped = false
      continue
    }
    if quoted && ch == '\\' {
      buffer.write_char_utf8(ch)
      escaped = true
      continue
    }
    if ch == '"' {
      quoted = !quoted
      buffer.write_char_utf8(ch)
      continue
    }
    if ch == ',' && !quoted {
      parts.push(buffer.to_bytes())
      buffer.reset()
      continue
    }
    buffer.write_char_utf8(ch)
  }
  parts.push(buffer.to_bytes())
  parts.map(fn(part) { @utf8.decode_lossy(part[:]) })
}

fn cache_unquote(value : String) -> String {
  let text = value.trim().to_owned()
  if text.length() >= 2 && text.has_prefix("\"") && text.has_suffix("\"") {
    text[1:text.length() - 1].to_owned()
  } else {
    text
  }
}

fn cache_parse_delta(value : String) -> Int {
  let text = cache_unquote(value)
  if !is_decimal_digits(text) {
    return 0
  }
  let mut result = 0
  for ch in text {
    let digit = ch.to_int() - '0'.to_int()
    if result > (2147483647 - digit) / 10 {
      return 2147483647
    }
    result = result * 10 + digit
  }
  result
}

fn cache_parse_directive(part : String) -> (String, String?) {
  match cache_index_of_char(part, '=') {
    Some(index) => (
      part[0:index].trim().to_lower().to_owned(),
      Some(part[index + 1:].trim().to_owned()),
    )
    None => (part.trim().to_lower().to_owned(), None)
  }
}

pub fn CacheControl::parse(value : String) -> CacheControl {
  let control = CacheControl::new()
  for part in cache_split_directives(value) {
    let (name, value) = cache_parse_directive(part)
    match name {
      "" => ()
      "no-store" => control.no_store = true
      "no-cache" => control.no_cache = true
      "must-revalidate" | "proxy-revalidate" => control.must_revalidate = true
      "public" => control.public_cache = true
      "private" => control.private_cache = true
      "immutable" => control.immutable = true
      "max-age" => {
        control.max_age = Some(match value {
          Some(value) => cache_parse_delta(value)
          None => 0
        })
      }
      "s-maxage" => {
        control.s_maxage = Some(match value {
          Some(value) => cache_parse_delta(value)
          None => 0
        })
      }
      "max-stale" => {
        control.max_stale = Some(match value {
          Some(value) => cache_parse_delta(value)
          None => -1
        })
      }
      "min-fresh" => {
        control.min_fresh = Some(match value {
          Some(value) => cache_parse_delta(value)
          None => 0
        })
      }
      "only-if-cached" => control.only_if_cached = true
      _ => ()
    }
  }
  control
}

pub fn CacheControl::from_headers(headers : Headers) -> CacheControl {
  let values = headers.get_all("Cache-Control")
  if values.length() == 0 {
    return CacheControl::new()
  }
  CacheControl::parse(values.to_array().join(", "))
}

fn cache_header_value(headers : Headers, name : String) -> String? {
  headers.get(name)
}

fn cache_join_header_values(headers : Headers, name : String) -> String {
  let values = headers.get_all(name)
  if values.length() == 0 {
    return ""
  }
  values.to_array().join(", ")
}

fn cache_header_seconds(value : String?) -> UInt64 {
  match value {
    Some(value) => {
      let text = cache_unquote(value.trim().to_owned())
      if is_decimal_digits(text) {
        cache_parse_delta(text).to_uint64()
      } else {
        0UL
      }
    }
    None => 0UL
  }
}

fn cache_header_date(value : String?) -> UInt64? {
  match value {
    Some(value) => cookie_parse_date(value)
    None => None
  }
}

fn cache_seconds_to_ms(seconds : Int) -> UInt64 {
  seconds.to_uint64() * 1000UL
}

fn cache_freshness_lifetime_ms(headers : Headers, date_ms : UInt64) -> UInt64 {
  let control = CacheControl::from_headers(headers)
  match control.max_age {
    Some(seconds) => cache_seconds_to_ms(seconds)
    None => {
      match cache_header_date(cache_header_value(headers, "Expires")) {
        Some(expires_ms) => {
          if expires_ms > date_ms {
            expires_ms - date_ms
          } else {
            0UL
          }
        }
        None => {
          match cache_header_date(cache_header_value(headers, "Last-Modified")) {
            Some(modified_ms) => {
              let heuristic = if date_ms > modified_ms {
                (date_ms - modified_ms) / 10UL
              } else {
                0UL
              }
              let cap = 86400UL * 1000UL
              if heuristic > cap {
                cap
              } else {
                heuristic
              }
            }
            None => 0UL
          }
        }
      }
    }
  }
}

fn cache_has_explicit_freshness(headers : Headers) -> Bool {
  let control = CacheControl::from_headers(headers)
  control.max_age is Some(_) ||
    cache_header_date(cache_header_value(headers, "Expires")) is Some(_)
}

fn cache_has_validator(headers : Headers) -> Bool {
  headers.get("ETag") is Some(_) || headers.get("Last-Modified") is Some(_)
}

fn cache_key(url : Url) -> String {
  Url::{ ..url, fragment: "" }.to_string()
}

fn cache_hop_by_hop(name : String) -> Bool {
  match name {
    "connection" |
    "keep-alive" |
    "proxy-authenticate" |
    "proxy-authorization" |
    "te" |
    "trailer" |
    "transfer-encoding" |
    "upgrade" => true
    _ => false
  }
}

fn cache_transfer_coding_supported(headers : Headers) -> Bool {
  let transfer = cache_join_header_values(headers, "Transfer-Encoding")
  if transfer.length() > 0 {
    for encoding in transfer.split(",") {
      let token = encoding.trim().to_lower().to_owned()
      if token.length() > 0 && token != "chunked" && !content_coding_supported(token) {
        return false
      }
    }
  }
  true
}

fn cache_status_cacheable(status : Int, headers : Headers) -> Bool {
  match status {
    200 | 203 | 204 | 300 | 301 | 308 | 404 | 405 | 410 | 414 | 501 => true
    302 | 307 => cache_has_explicit_freshness(headers)
    _ => false
  }
}

fn cache_vary_names(
  request_headers : Headers,
  response_headers : Headers,
) -> Array[String]? {
  let names : Array[String] = []
  for value in response_headers.get_all("Vary") {
    for part in value.split(",") {
      let name = part.trim().to_lower().to_owned()
      if name == "*" {
        return None
      }
      if name.length() > 0 && !names.contains(name) {
        names.push(name)
      }
    }
  }
  if request_headers.get("Cookie") is Some(_) && !names.contains("cookie") {
    names.push("cookie")
  }
  names.sort()
  Some(names)
}

fn cache_request_header_value(headers : Headers, name : String) -> String {
  let values = headers.get_all(name)
  if values.length() == 0 {
    return ""
  }
  if name == "cookie" {
    values.to_array().join("; ")
  } else {
    values.to_array().join(", ")
  }
}

fn cache_vary_values(
  names : Array[String],
  request_headers : Headers,
) -> Array[String] {
  names.map(fn(name) { cache_request_header_value(request_headers, name) })
}

fn cache_current_age_ms(entry : CacheEntry, now_ms : UInt64) -> UInt64 {
  let apparent = if entry.response_time_ms > entry.date_ms {
    entry.response_time_ms - entry.date_ms
  } else {
    0UL
  }
  let corrected = if apparent > entry.age_header_ms {
    apparent
  } else {
    entry.age_header_ms
  }
  let resident = if now_ms > entry.response_time_ms {
    now_ms - entry.response_time_ms
  } else {
    0UL
  }
  corrected + resident
}

fn cache_entry_matches(entry : CacheEntry, request : Request) -> Bool {
  if cache_key(entry.url) != cache_key(request.url) {
    return false
  }
  if entry.vary_names.length() != entry.vary_values.length() {
    return false
  }
  let mut i = 0
  while i < entry.vary_names.length() {
    if cache_request_header_value(request.headers, entry.vary_names[i]) !=
      entry.vary_values[i] {
      return false
    }
    i = i + 1
  }
  true
}

fn cache_connection_tokens(headers : Headers) -> Array[String] {
  let tokens : Array[String] = []
  for value in headers.get_all("Connection") {
    for part in value.split(",") {
      let token = part.trim().to_lower().to_owned()
      if token.length() > 0 && !tokens.contains(token) {
        tokens.push(token)
      }
    }
  }
  tokens
}

fn cache_stored_headers(headers : Headers) -> Headers {
  let mut stored = Headers::new()
  let connection_tokens = cache_connection_tokens(headers)
  for header in headers.iter() {
    let name = header.name.to_lower()
    if cache_hop_by_hop(name) ||
      connection_tokens.contains(name) ||
      name == "age" ||
      name == "content-length" ||
      name == "set-cookie" {
      continue
    }
    stored = stored.add(header.name, header.value)
  }
  stored
}

fn cache_entry_size(entry : CacheEntry) -> Int {
  let mut size = entry.body.length() + entry.url.to_string().length() + 64
  for header in entry.headers.iter() {
    size = size + header.name.length() + header.value.length() + 4
  }
  let mut i = 0
  while i < entry.vary_names.length() {
    size = size + entry.vary_names[i].length() + entry.vary_values[i].length() + 4
    i = i + 1
  }
  size
}

fn cache_entry_response(entry : CacheEntry, now_ms : UInt64) -> Response {
  let age_seconds = cache_current_age_ms(entry, now_ms) / 1000UL
  let mut headers = entry.headers.add("Age", age_seconds.to_string())
  if entry.status != 204 {
    headers = headers.set("Content-Length", entry.body.length().to_string())
  }
  let stream = BufferedStream::new(entry.body)
  let body : &Stream = stream
  Response::new_with_version(entry.version, entry.status, headers, body)
    .with_max_body_bytes(entry.max_body_bytes)
    .with_auto_decompress(entry.auto_decompress)
    .with_request_url(entry.url)
}

struct CacheEntry {
  url : Url
  version : String
  status : Int
  headers : Headers
  body : Bytes
  max_body_bytes : Int
  auto_decompress : Bool
  vary_names : Array[String]
  vary_values : Array[String]
  date_ms : UInt64
  response_time_ms : UInt64
  age_header_ms : UInt64
  freshness_lifetime_ms : UInt64
  must_revalidate : Bool
  mut last_used_ms : UInt64
}

struct CacheState {
  entries : Array[CacheEntry]
  max_entries : Int
  max_body_bytes : Int
  max_total_bytes : Int
}

pub struct CacheHit {
  response : Response
  fresh : Bool
  etag : String?
  last_modified : String?
}

pub enum CacheLookup {
  Miss
  Hit(CacheHit)
}

pub struct HttpCache {
  state : @ref.Ref[CacheState]
}

pub fn HttpCache::new() -> HttpCache {
  HttpCache::with_limits(128, 16 * 1024 * 1024, 64 * 1024 * 1024)
}

pub fn HttpCache::with_limits(
  max_entries : Int,
  max_body_bytes : Int,
  max_total_bytes : Int,
) -> HttpCache {
  HttpCache::{
    state: @ref.Ref(CacheState::{
      entries: [],
      max_entries: if max_entries < 0 { 0 } else { max_entries },
      max_body_bytes: if max_body_bytes < 0 { 0 } else { max_body_bytes },
      max_total_bytes: if max_total_bytes < 0 { 0 } else { max_total_bytes },
    }),
  }
}

pub fn HttpCache::length(self : HttpCache) -> Int {
  self.state.val.entries.length()
}

pub fn HttpCache::clear(self : HttpCache) -> Unit {
  self.state.val.entries.clear()
}

fn cache_total_size(state : CacheState) -> Int {
  let mut total = 0
  for entry in state.entries {
    total = total + cache_entry_size(entry)
  }
  total
}

fn cache_oldest_index(state : CacheState) -> Int {
  if state.entries.length() == 0 {
    return -1
  }
  let mut oldest = 0
  let mut i = 1
  while i < state.entries.length() {
    if state.entries[i].last_used_ms < state.entries[oldest].last_used_ms {
      oldest = i
    }
    i = i + 1
  }
  oldest
}

fn cache_evict(state : CacheState) -> Unit {
  while state.entries.length() > state.max_entries {
    let index = cache_oldest_index(state)
    if index < 0 {
      return
    }
    let _ = state.entries.remove(index)
  }
  while cache_total_size(state) > state.max_total_bytes && state.entries.length() > 0 {
    let index = cache_oldest_index(state)
    if index < 0 {
      return
    }
    let _ = state.entries.remove(index)
  }
}

pub fn HttpCache::invalidate(self : HttpCache, url : Url) -> Unit {
  let key = cache_key(url)
  let entries = self.state.val.entries
  let mut i = 0
  while i < entries.length() {
    if cache_key(entries[i].url) == key {
      let _ = entries.remove(i)
    } else {
      i = i + 1
    }
  }
}

fn cache_find_index(state : CacheState, request : Request) -> Int? {
  let mut i = state.entries.length() - 1
  while i >= 0 {
    if cache_entry_matches(state.entries[i], request) {
      return Some(i)
    }
    i = i - 1
  }
  None
}

pub fn HttpCache::lookup(
  self : HttpCache,
  request : Request,
  now_ms : UInt64,
) -> CacheLookup {
  if canonical_http_method(request.method) != GET {
    return CacheLookup::Miss
  }
  if request.get_header("Authorization") is Some(_) {
    return CacheLookup::Miss
  }
  let request_control = CacheControl::from_headers(request.headers)
  if request_control.no_store {
    return CacheLookup::Miss
  }
  let state = self.state.val
  let index = match cache_find_index(state, request) {
    Some(index) => index
    None => return CacheLookup::Miss
  }
  let entry = state.entries[index]
  entry.last_used_ms = now_ms
  state.entries[index] = entry
  let age_ms = cache_current_age_ms(entry, now_ms)
  let response_control = CacheControl::from_headers(entry.headers)
  let mut fresh = age_ms < entry.freshness_lifetime_ms
  if response_control.no_cache {
    fresh = false
  }
  if request_control.no_cache {
    fresh = false
  }
  match request_control.max_age {
    Some(seconds) => {
      if age_ms > cache_seconds_to_ms(seconds) {
        fresh = false
      }
    }
    None => ()
  }
  match request_control.min_fresh {
    Some(seconds) => {
      let remaining = if entry.freshness_lifetime_ms > age_ms {
        entry.freshness_lifetime_ms - age_ms
      } else {
        0UL
      }
      if remaining < cache_seconds_to_ms(seconds) {
        fresh = false
      }
    }
    None => ()
  }
  if !fresh && !entry.must_revalidate && !response_control.must_revalidate {
    match request_control.max_stale {
      Some(seconds) => {
        let staleness = if age_ms > entry.freshness_lifetime_ms {
          age_ms - entry.freshness_lifetime_ms
        } else {
          0UL
        }
        if seconds < 0 || staleness <= cache_seconds_to_ms(seconds) {
          fresh = true
        }
      }
      None => ()
    }
  }
  CacheLookup::Hit(CacheHit::{
    response: cache_entry_response(entry, now_ms),
    fresh,
    etag: entry.headers.get("ETag"),
    last_modified: entry.headers.get("Last-Modified"),
  })
}

fn cache_response_cacheable(request : Request, response : Response) -> Bool {
  if request.get_header("Authorization") is Some(_) {
    return false
  }
  if response.headers.get("Set-Cookie") is Some(_) ||
    response.headers.get("Trailer") is Some(_) ||
    response.early_hints().length() > 0 {
    return false
  }
  let request_control = CacheControl::from_headers(request.headers)
  if request_control.no_store {
    return false
  }
  let response_control = CacheControl::from_headers(response.headers)
  if response_control.no_store {
    return false
  }
  if !cache_status_cacheable(response.status, response.headers) {
    return false
  }
  if response_control.no_cache && !cache_has_validator(response.headers) {
    return false
  }
  cache_has_explicit_freshness(response.headers) ||
    cache_has_validator(response.headers)
}

fn cache_response_after_body(
  version : String,
  status : Int,
  headers : Headers,
  body : Bytes,
  max_body_bytes : Int,
  auto_decompress : Bool,
  url : Url,
) -> Response {
  let stream = BufferedStream::new(body)
  let stream_ref : &Stream = stream
  Response::new_with_version(version, status, headers, stream_ref)
    .with_max_body_bytes(max_body_bytes)
    .with_auto_decompress(auto_decompress)
    .with_request_url(url)
}

pub fn HttpCache::store(
  self : HttpCache,
  request : Request,
  response : Response,
  now_ms : UInt64,
) -> Result[Response, HttpError] {
  if canonical_http_method(request.method) != GET {
    return Ok(response)
  }
  let state = self.state.val
  if state.max_entries == 0 || state.max_body_bytes == 0 {
    return Ok(response)
  }
  if !cache_response_cacheable(request, response) {
    return Ok(response)
  }
  match response.request_url() {
    Some(url) => {
      if cache_key(url) != cache_key(request.url) {
        return Ok(response)
      }
    }
    None => ()
  }
  if !cache_transfer_coding_supported(response.headers) {
    return Ok(response)
  }
  let vary_names = match cache_vary_names(request.headers, response.headers) {
    Some(names) => names
    None => return Ok(response)
  }
  let limit = if state.max_body_bytes < response.max_body_bytes {
    state.max_body_bytes
  } else {
    response.max_body_bytes
  }
  match cache_header_value(response.headers, "Content-Length") {
    Some(value) => {
      let text = value.trim().to_owned()
      if is_decimal_digits(text) && cache_parse_delta(text) > limit {
        return Ok(response)
      }
    }
    None => ()
  }
  let body = match response.read_body_with_limit(response.max_body_bytes) {
    Ok(body) => body
    Err(err) => return Err(err)
  }
  let final_url = match response.request_url() {
    Some(url) => url
    None => request.url
  }
  if body.length() > state.max_body_bytes {
    return Ok(cache_response_after_body(
      response.version,
      response.status,
      response.headers,
      body,
      response.max_body_bytes,
      response.auto_decompress(),
      final_url,
    ))
  }
  let headers = cache_stored_headers(response.headers)
  let date_ms = match cache_header_date(cache_header_value(response.headers, "Date")) {
    Some(date) => date
    None => now_ms
  }
  let age_header_ms = cache_header_seconds(
    cache_header_value(response.headers, "Age"),
  ) * 1000UL
  let control = CacheControl::from_headers(headers)
  let entry = CacheEntry::{
    url: final_url,
    version: response.version,
    status: response.status,
    headers,
    body,
    max_body_bytes: response.max_body_bytes,
    auto_decompress: response.auto_decompress(),
    vary_names,
    vary_values: cache_vary_values(vary_names, request.headers),
    date_ms,
    response_time_ms: now_ms,
    age_header_ms,
    freshness_lifetime_ms: cache_freshness_lifetime_ms(headers, date_ms),
    must_revalidate: control.must_revalidate,
    last_used_ms: now_ms,
  }
  if cache_entry_size(entry) > state.max_total_bytes {
    return Ok(cache_response_after_body(
      response.version,
      response.status,
      response.headers,
      body,
      response.max_body_bytes,
      response.auto_decompress(),
      final_url,
    ))
  }
  let mut i = 0
  while i < state.entries.length() {
    if cache_entry_matches(state.entries[i], request) {
      let _ = state.entries.remove(i)
    } else {
      i = i + 1
    }
  }
  state.entries.push(entry)
  cache_evict(state)
  let index = match cache_find_index(state, request) {
    Some(index) => index
    None => state.entries.length() - 1
  }
  Ok(cache_entry_response(state.entries[index], now_ms))
}

fn cache_merge_headers(stored : Headers, update : Headers) -> Headers {
  let mut merged = stored
  let connection_tokens = cache_connection_tokens(update)
  for header in update.iter() {
    let name = header.name.to_lower()
    if cache_hop_by_hop(name) ||
      connection_tokens.contains(name) ||
      name == "age" ||
      name == "content-length" ||
      name == "content-encoding" ||
      name == "set-cookie" {
      continue
    }
    merged = merged.remove(header.name).add(header.name, header.value)
  }
  merged
}

pub fn HttpCache::revalidate(
  self : HttpCache,
  request : Request,
  not_modified : Response,
  now_ms : UInt64,
) -> Option[Response] {
  let state = self.state.val
  let index = match cache_find_index(state, request) {
    Some(index) => index
    None => {
      let _ = not_modified.body.close()
      return None
    }
  }
  let _ = not_modified.body.close()
  let mut entry = state.entries[index]
  let control = CacheControl::from_headers(not_modified.headers)
  if control.no_store {
    let _ = state.entries.remove(index)
    return None
  }
  let merged = cache_merge_headers(entry.headers, not_modified.headers)
  let merged_control = CacheControl::from_headers(merged)
  if merged_control.no_store {
    let _ = state.entries.remove(index)
    return None
  }
  let date_ms = match cache_header_date(cache_header_value(merged, "Date")) {
    Some(date) => date
    None => now_ms
  }
  entry = CacheEntry::{
    ..entry,
    headers: merged,
    date_ms,
    response_time_ms: now_ms,
    age_header_ms: cache_header_seconds(
      cache_header_value(not_modified.headers, "Age"),
    ) * 1000UL,
    freshness_lifetime_ms: cache_freshness_lifetime_ms(merged, date_ms),
    must_revalidate: merged_control.must_revalidate,
    last_used_ms: now_ms,
  }
  state.entries[index] = entry
  Some(cache_entry_response(entry, now_ms))
}

pub struct CachedClient {
  client : UnifiedClient
  cache : HttpCache
}

pub fn CachedClient::new(client : UnifiedClient) -> CachedClient {
  CachedClient::{ client, cache: HttpCache::new() }
}

pub fn CachedClient::with_cache(self : CachedClient, cache : HttpCache) -> CachedClient {
  CachedClient::{ ..self, cache }
}

pub fn CachedClient::cache(self : CachedClient) -> HttpCache {
  self.cache
}

pub fn CachedClient::inner(self : CachedClient) -> UnifiedClient {
  self.client
}

pub fn CachedClient::get(self : CachedClient, url : String) -> Result[Response, HttpError] {
  let request = match Request::from_url(GET, url) {
    Ok(request) => request
    Err(err) => return Err(err)
  }
  self.request(request)
}

pub fn CachedClient::post(
  self : CachedClient,
  url : String,
  body : Bytes,
) -> Result[Response, HttpError] {
  let request = match Request::from_url(POST, url) {
    Ok(request) => request.with_body(body)
    Err(err) => return Err(err)
  }
  self.request(request)
}

pub fn CachedClient::close(self : CachedClient) -> Result[Unit, HttpError] {
  self.client.close()
}

pub fn CachedClient::close_all(self : CachedClient) -> Result[Unit, HttpError] {
  self.client.close_all()
}

fn CachedClient::with_cookie_header(self : CachedClient, request : Request) -> Request {
  if request.get_header("Cookie") is Some(_) {
    return request
  }
  match self.client.connector.cookie_header(request.url) {
    Some(value) => request.with_header("Cookie", value)
    None => request
  }
}

fn cache_unsafe_status(status : Int) -> Bool {
  status >= 200 && status < 400 && status != 304
}

fn CachedClient::invalidate_related(self : CachedClient, request : Request, response : Response) -> Unit {
  self.cache.invalidate(request.url)
  match response.request_url() {
    Some(url) => self.cache.invalidate(url)
    None => ()
  }
  match response.headers.get("Location") {
    Some(location) => {
      match request.url.join(location) {
        Ok(url) => self.cache.invalidate(url)
        Err(_) => ()
      }
    }
    None => ()
  }
}

fn CachedClient::request_cached(
  self : CachedClient,
  request : Request,
) -> Result[Response, HttpError] {
  if canonical_http_method(request.method) != GET {
    let response = match self.client.request(request) {
      Ok(response) => response
      Err(err) => return Err(err)
    }
    if cache_unsafe_status(response.status) {
      self.invalidate_related(request, response)
    }
    return Ok(response)
  }
  let cache_request = self.with_cookie_header(request)
  let request_control = CacheControl::from_headers(cache_request.headers)
  if request_control.no_store {
    return self.client.request(cache_request)
  }
  let now_ms = @env.now()
  match self.cache.lookup(cache_request, now_ms) {
    CacheLookup::Miss => {
      if request_control.only_if_cached {
        return Err(ProtocolError("only-if-cached request missed the cache"))
      }
      let response = match self.client.request(cache_request) {
        Ok(response) => response
        Err(err) => return Err(err)
      }
      self.cache.store(cache_request, response, @env.now())
    }
    CacheLookup::Hit(hit) => {
      if hit.fresh {
        return Ok(hit.response)
      }
      if request_control.only_if_cached {
        return Err(ProtocolError("only-if-cached response is stale"))
      }
      let mut conditional = cache_request
      match hit.etag {
        Some(etag) => {
          if conditional.get_header("If-None-Match") is None {
            conditional = conditional.with_header("If-None-Match", etag)
          }
        }
        None => ()
      }
      match hit.last_modified {
        Some(modified) => {
          if conditional.get_header("If-Modified-Since") is None {
            conditional = conditional.with_header("If-Modified-Since", modified)
          }
        }
        None => ()
      }
      let response = match self.client.request(conditional) {
        Ok(response) => response
        Err(err) => return Err(err)
      }
      if response.status == 304 {
        match self.cache.revalidate(cache_request, response, @env.now()) {
          Some(response) => Ok(response)
          None => {
            let response = match self.client.request(cache_request) {
              Ok(response) => response
              Err(err) => return Err(err)
            }
            self.cache.store(cache_request, response, @env.now())
          }
        }
      } else {
        self.cache.store(cache_request, response, @env.now())
      }
    }
  }
}

pub impl HttpClient for CachedClient with fn request(
  self : CachedClient,
  request : Request,
) -> Result[Response, HttpError] {
  self.request_cached(request)
}

extend CachedClient with HttpClient::{request}
