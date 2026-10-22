/// A stream that replays a fixed prefix of already-read bytes before
/// delegating to the underlying stream. It is used to hand the first bytes of
/// a CONNECT tunnel back to the TLS layer after a single socket read may have
/// delivered them alongside the proxy response headers.
struct PrefixStream {
  prefix : Bytes
  mut offset : Int
  underlying : &Stream
  mut is_open : Bool
}

fn PrefixStream::new(prefix : Bytes, underlying : &Stream) -> PrefixStream {
  PrefixStream::{ prefix, offset: 0, underlying, is_open: true }
}

pub impl Stream for PrefixStream with fn read(self : PrefixStream, buf : Buffer) -> Result[Int, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  if self.offset < self.prefix.length() {
    let remaining = self.prefix.length() - self.offset
    let take = if remaining < 8192 { remaining } else { 8192 }
    buf.write_bytes(self.prefix.exact_view(start=self.offset, end=self.offset + take))
    self.offset = self.offset + take
    return Ok(take)
  }
  self.underlying.read(buf)
}

pub impl Stream for PrefixStream with fn read_ready(self : PrefixStream) -> Bool {
  if !self.is_open {
    return false
  }
  self.offset < self.prefix.length() || self.underlying.read_ready()
}

pub impl Stream for PrefixStream with fn wait_readable(
  self : PrefixStream,
  timeout_ms : Int,
) -> Result[Bool, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  if self.offset < self.prefix.length() {
    return Ok(true)
  }
  self.underlying.wait_readable(timeout_ms)
}

pub impl Stream for PrefixStream with fn write(self : PrefixStream, buf : Buffer) -> Result[Int, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  self.underlying.write(buf)
}

pub impl Stream for PrefixStream with fn flush(self : PrefixStream) -> Result[Unit, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  self.underlying.flush()
}

pub impl Stream for PrefixStream with fn close(self : PrefixStream) -> Result[Unit, NetError] {
  if !self.is_open {
    return Ok(())
  }
  self.is_open = false
  self.underlying.close()
}

pub impl Stream for PrefixStream with fn set_timeout(self : PrefixStream, timeout_ms : Int) -> Result[Unit, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  self.underlying.set_timeout(timeout_ms)
}

pub impl Stream for PrefixStream with fn peer_addr(self : PrefixStream) -> Result[String, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  self.underlying.peer_addr()
}

pub impl Stream for PrefixStream with fn local_addr(self : PrefixStream) -> Result[String, NetError] {
  if !self.is_open {
    return Err(NetError::Closed)
  }
  self.underlying.local_addr()
}

struct ActiveConnection {
  id : Int
  key : String
  stream : &Stream
  h2 : H2ClientConnection?
}

struct IdleConnection {
  stream : &Stream
  last_used_ms : UInt64
  negotiated_protocol : String?
  h2 : H2ClientConnection?
}

/// Default maximum idle time for a pooled connection (90 seconds).
const DEFAULT_IDLE_TIMEOUT_MS : Int = 90000

struct ConnectionPoolState {
  mut idle : Map[String, List[IdleConnection]]
  mut active : List[ActiveConnection]
  mut next_id : Int
  mut max_idle : Int
  mut idle_timeout_ms : Int
}

fn ConnectionPoolState::new() -> ConnectionPoolState {
  ConnectionPoolState::{
    idle: Map([]),
    active: @list.List([]),
    next_id: 0,
    max_idle: 8,
    idle_timeout_ms: DEFAULT_IDLE_TIMEOUT_MS,
  }
}

fn ConnectionPoolState::empty_with_settings(self : ConnectionPoolState) -> ConnectionPoolState {
  ConnectionPoolState::{
    idle: Map([]),
    active: @list.List([]),
    next_id: 0,
    max_idle: self.max_idle,
    idle_timeout_ms: self.idle_timeout_ms,
  }
}

/// Number of connections still checked out for `key`.
fn ConnectionPoolState::active_count(self : ConnectionPoolState, key : String) -> Int {
  let mut count = 0
  for entry in self.active {
    if entry.key == key {
      count = count + 1
    }
  }
  count
}

/// Cache a reusable connection for `key`, keeping at most `max_idle`
/// idle connections per host. Connections beyond the cap are closed.
fn ConnectionPoolState::cache_idle(
  self : ConnectionPoolState,
  key : String,
  stream : &Stream,
  now_ms : UInt64,
) -> Unit {
  self.cache_idle_with_protocol(key, stream, now_ms, None)
}

fn ConnectionPoolState::cache_idle_with_protocol(
  self : ConnectionPoolState,
  key : String,
  stream : &Stream,
  now_ms : UInt64,
  negotiated_protocol : String?,
) -> Unit {
  self.cache_idle_connection(
    key,
    stream,
    now_ms,
    negotiated_protocol,
    None,
  )
}

fn ConnectionPoolState::cache_idle_h2(
  self : ConnectionPoolState,
  key : String,
  connection : H2ClientConnection,
  now_ms : UInt64,
) -> Unit {
  self.cache_idle_connection(
    key,
    connection.stream,
    now_ms,
    Some("h2"),
    Some(connection),
  )
}

fn ConnectionPoolState::cache_idle_connection(
  self : ConnectionPoolState,
  key : String,
  stream : &Stream,
  now_ms : UInt64,
  negotiated_protocol : String?,
  h2 : H2ClientConnection?,
) -> Unit {
  let idle = match self.idle.get(key) {
    Some(streams) => streams
    None => @list.List([])
  }
  let mut updated = idle.prepend(IdleConnection::{
    stream,
    last_used_ms: now_ms,
    negotiated_protocol,
    h2,
  })
  while updated.length() > self.max_idle {
    match updated.last() {
      Some(evicted) => {
        let _ = evicted.stream.close()
        updated = updated.take(updated.length() - 1)
      }
      None => break
    }
  }
  self.idle.set(key, updated)
}

/// Close idle connections whose last use is older than the configured idle
/// timeout. Lookups only need to inspect the target origin, but a long-lived
/// client can idle on many origins it never revisits; sweeping all entries
/// keeps those sockets from staying open indefinitely.
fn ConnectionPoolState::sweep_expired(self : ConnectionPoolState, now_ms : UInt64) -> Unit {
  let timeout = self.idle_timeout_ms
  if timeout <= 0 {
    return
  }
  let keys : Array[String] = []
  for key in self.idle.keys() {
    keys.push(key)
  }
  for key in keys {
    match self.idle.get(key) {
      Some(entries) => {
        let kept = entries.filter(fn(entry) {
          let expired = now_ms > entry.last_used_ms &&
            now_ms - entry.last_used_ms > timeout.to_uint64()
          if expired {
            let _ = entry.stream.close()
            false
          } else {
            true
          }
        })
        if kept.length() != entries.length() {
          if kept.length() == 0 {
            let _ = self.idle.remove(key)
          } else {
            self.idle.set(key, kept)
          }
        }
      }
      None => ()
    }
  }
}

/// Drop the oldest idle connections until every host is within `max_idle`.
fn ConnectionPoolState::trim_idle(self : ConnectionPoolState) -> Unit {
  let keys : Array[String] = []
  for key in self.idle.keys() {
    keys.push(key)
  }
  for key in keys {
    match self.idle.get(key) {
      Some(entries) => {
        let mut updated = entries
        while updated.length() > self.max_idle {
          match updated.last() {
            Some(evicted) => {
              let _ = evicted.stream.close()
              updated = updated.take(updated.length() - 1)
            }
            None => break
          }
        }
        if updated.length() == 0 {
          let _ = self.idle.remove(key)
        } else {
          self.idle.set(key, updated)
        }
      }
      None => ()
    }
  }
}

/// Number of idle (pooled, reusable) connections across every origin.
fn ConnectionPoolState::idle_count(self : ConnectionPoolState) -> Int {
  let mut total = 0
  for _key, entries in self.idle.iter2() {
    total = total + entries.length()
  }
  total
}

/// Connector handles the connection establishment logic
pub struct Connector {
  dialer : &Dialer
  tls_provider : &TlsProvider
  tls_config : TlsConfig?
  proxy : Proxy?
  proxy_bypass : Array[String]
  mut timeout_ms : Int
  // Separate cap for dialing and the TLS handshake. Zero means "use the
  // request timeout", preserving the historical single-timeout behavior.
  mut connect_timeout_ms : Int
  mut max_connections_per_host : Int
  http2 : Bool
  http2_prior_knowledge : Bool
  mut cookies_enabled : Bool
  cookie_jar : @ref.Ref[CookieJar]
  pool : @ref.Ref[ConnectionPoolState]
}

pub struct ConnectionLease {
  priv id : Int
  priv key : String
  priv stream : &Stream
  priv negotiated_protocol : String?
  priv h2 : H2ClientConnection?
  priv reused : Bool
  priv mut released : Bool
  priv pool : @ref.Ref[ConnectionPoolState]
}

/// Release the checked-out connection, returning it to the pool when it is
/// still usable. Releasing a lease more than once is a no-op.
pub fn ConnectionLease::release(self : ConnectionLease, reusable : Bool) -> Unit {
  if self.released {
    return
  }
  self.released = true
  let id = self.id
  self.pool.val.active = self.pool.val.active.filter(fn(entry) { entry.id != id })
  match self.h2 {
    Some(connection) =>
      if reusable {
        if connection.is_open() {
          self.pool.val.cache_idle_h2(self.key, connection, @env.now())
        } else {
          let _ = self.stream.close()
        }
      } else {
        connection.close()
      }
    None =>
      if reusable {
        match self.stream.peer_addr() {
          Ok(_) => self.pool.val.cache_idle_with_protocol(
            self.key,
            self.stream,
            @env.now(),
            self.negotiated_protocol,
          )
          Err(_) => {
            let _ = self.stream.close()
          }
        }
      } else {
        let _ = self.stream.close()
      }
  }
}

/// The ALPN protocol selected for this leased connection, if known.
pub fn ConnectionLease::negotiated_protocol(self : ConnectionLease) -> String? {
  self.negotiated_protocol
}

/// Remove and return an idle connection for `key`. Entries whose last use is
/// older than the configured idle timeout are closed and skipped; the search
/// stops at the first live entry because `idle` is ordered by recency.
fn take_idle_connection_at(
  pool : @ref.Ref[ConnectionPoolState],
  key : String,
  now_ms : UInt64,
  accept_h2? : Bool,
) -> Option[(&Stream, String?, H2ClientConnection?)] {
  let accept_h2 = accept_h2.unwrap_or(true)
  let entries = match pool.val.idle.get(key) {
    Some(entries) => entries
    None => return None
  }
  let timeout = pool.val.idle_timeout_ms
  let mut remaining = entries
  while true {
    match remaining.head() {
      Some(entry) => {
        let rest = remaining.unsafe_tail()
        let expired = if timeout > 0 && now_ms > entry.last_used_ms {
          now_ms - entry.last_used_ms > timeout.to_uint64()
        } else {
          false
        }
        let usable_h2 = if entry.h2 is Some(connection) {
          accept_h2 && connection.is_open()
        } else {
          true
        }
        let alive = if expired { false } else { entry.stream.peer_addr() is Ok(_) }
        if expired || !alive || !usable_h2 {
          let _ = entry.stream.close()
          if rest.length() == 0 {
            let _ = pool.val.idle.remove(key)
            return None
          }
          pool.val.idle.set(key, rest)
          remaining = rest
          continue
        }
        if rest.length() == 0 {
          let _ = pool.val.idle.remove(key)
        } else {
          pool.val.idle.set(key, rest)
        }
        return Some((entry.stream, entry.negotiated_protocol, entry.h2))
      }
      None => {
        let _ = pool.val.idle.remove(key)
        return None
      }
    }
  }
  None
}

pub fn Connector::new(dialer : &Dialer, tls_provider : &TlsProvider) -> Connector {
  Connector::{
    dialer,
    tls_provider,
    tls_config: None,
    proxy: None,
    proxy_bypass: [],
    timeout_ms: 30000,
    connect_timeout_ms: 0,
    max_connections_per_host: 0,
    http2: false,
    http2_prior_knowledge: false,
    cookies_enabled: false,
    cookie_jar: @ref.Ref(CookieJar::new()),
    pool: @ref.Ref(ConnectionPoolState::new()),
  }
}

/// A connector that inherits this one's configuration but owns an empty pool.
/// Builder methods use it so deriving a tuned client does not reconfigure the
/// source client's pool or close its in-flight/idle connections.
fn Connector::detached(self : Connector) -> Connector {
  Connector::{
    dialer: self.dialer,
    tls_provider: self.tls_provider,
    tls_config: self.tls_config,
    proxy: self.proxy,
    proxy_bypass: self.proxy_bypass,
    timeout_ms: self.timeout_ms,
    connect_timeout_ms: self.connect_timeout_ms,
    max_connections_per_host: self.max_connections_per_host,
    http2: self.http2,
    http2_prior_knowledge: self.http2_prior_knowledge,
    cookies_enabled: self.cookies_enabled,
    cookie_jar: self.cookie_jar,
    pool: @ref.Ref(self.pool.val.empty_with_settings()),
  }
}

/// Set the timeout applied to newly dialed connections and TLS handshakes.
pub fn Connector::with_timeout(self : Connector, timeout_ms : Int) -> Connector {
  self.timeout_ms = if timeout_ms < 0 { 0 } else { timeout_ms }
  self.dialer.set_timeout(self.timeout_ms)
  self
}

/// The timeout applied to newly dialed connections and TLS handshakes.
pub fn Connector::timeout(self : Connector) -> Int {
  self.timeout_ms
}

/// Bound connection establishment separately from the response exchange.
/// A value below 1 keeps using the request timeout. The effective connect
/// timeout is never longer than the request timeout for that checkout.
pub fn Connector::with_connect_timeout(
  self : Connector,
  timeout_ms : Int,
) -> Connector {
  self.connect_timeout_ms = if timeout_ms < 0 { 0 } else { timeout_ms }
  self
}

/// The explicit connection-establishment timeout, or `0` when it follows the
/// request timeout.
pub fn Connector::connect_timeout(self : Connector) -> Int {
  self.connect_timeout_ms
}

/// Combine the request deadline with the optional connect-only deadline.
/// Zero means "unbounded" for the request timeout, so it must not win against
/// a finite connect timeout.
fn effective_connect_timeout(
  request_timeout_ms : Int,
  connect_timeout_ms : Int,
) -> Int {
  if connect_timeout_ms <= 0 {
    request_timeout_ms
  } else if request_timeout_ms <= 0 {
    connect_timeout_ms
  } else if connect_timeout_ms < request_timeout_ms {
    connect_timeout_ms
  } else {
    request_timeout_ms
  }
}

/// Use a shared TLS configuration for every HTTPS connection.
/// Existing pooled connections were established with the previous
/// configuration, so they must not be reused.
pub fn Connector::with_tls_config(self : Connector, config : TlsConfig) -> Connector {
  let pool = @ref.Ref(self.pool.val.empty_with_settings())
  let _ = self.close_all()
  Connector::{
    dialer: self.dialer,
    tls_provider: self.tls_provider,
    tls_config: Some(config),
    proxy: self.proxy,
    proxy_bypass: self.proxy_bypass,
    timeout_ms: self.timeout_ms,
    connect_timeout_ms: self.connect_timeout_ms,
    max_connections_per_host: self.max_connections_per_host,
    http2: self.http2,
    http2_prior_knowledge: self.http2_prior_knowledge,
    cookies_enabled: self.cookies_enabled,
    cookie_jar: self.cookie_jar,
    pool,
  }
}

/// Route every request through an HTTP(S) or SOCKS5 proxy. Existing pooled
/// connections were made directly, so they are closed and cannot be reused.
pub fn Connector::with_proxy(self : Connector, proxy : Proxy) -> Connector {
  let pool = @ref.Ref(self.pool.val.empty_with_settings())
  let _ = self.close_all()
  Connector::{
    dialer: self.dialer,
    tls_provider: self.tls_provider,
    tls_config: self.tls_config,
    proxy: Some(proxy),
    proxy_bypass: self.proxy_bypass,
    timeout_ms: self.timeout_ms,
    connect_timeout_ms: self.connect_timeout_ms,
    max_connections_per_host: self.max_connections_per_host,
    http2: self.http2,
    http2_prior_knowledge: self.http2_prior_knowledge,
    cookies_enabled: self.cookies_enabled,
    cookie_jar: self.cookie_jar,
    pool,
  }
}

/// Route requests to matching hosts directly instead of through the proxy.
/// Entries follow the common `NO_PROXY` syntax: a host name matches that host
/// and its subdomains, a leading `.` or `*.` is allowed, `host:port` restricts
/// the match to one port, IP literals match exactly, IPv4 and IPv6 CIDR blocks
/// (`10.0.0.0/8`, `2001:db8::/32`) match an address range, and `*` disables
/// the proxy for every request. Matching is case-insensitive and ignores
/// surrounding whitespace.
///
/// Existing pooled connections may have been opened through the proxy, so they
/// are closed before the new routing rules take effect.
pub fn Connector::with_proxy_bypass(
  self : Connector,
  patterns : Array[String],
) -> Connector {
  let pool = @ref.Ref(self.pool.val.empty_with_settings())
  let _ = self.close_all()
  Connector::{ ..self, proxy_bypass: patterns.copy(), pool }
}

/// The configured proxy bypass patterns.
pub fn Connector::proxy_bypass(self : Connector) -> Array[String] {
  self.proxy_bypass.copy()
}

fn normalize_bypass_host(host : String) -> String {
  let lower = host.to_lower()
  if lower.length() > 0 && lower.get_char(lower.length() - 1) == Some('.') {
    lower[0:lower.length() - 1].to_owned()
  } else {
    lower
  }
}

/// Split `host`, `host:port`, `[v6]`, or `[v6]:port` into its parts.
/// Returns `None` for malformed entries so they simply never match.
fn parse_bypass_authority(value : String) -> (String, Int?)? {
  if value.length() == 0 {
    return None
  }
  if value.get_char(0) == Some('[') {
    let end = match value.find("]") {
      Some(index) => index
      None => return None
    }
    let host = value[1:end].to_owned()
    if host.length() == 0 {
      return None
    }
    let rest = value[end + 1:].to_owned()
    if rest.length() == 0 {
      return Some((host, None))
    }
    if rest.get_char(0) != Some(':') || rest.length() == 1 {
      return None
    }
    let port_text = rest[1:].to_owned()
    if !is_decimal_digits(port_text) {
      return None
    }
    let port = try {
      @string.parse_int(port_text[:])
    } catch {
      _ => return None
    }
    if port < 1 || port > 65535 {
      return None
    }
    return Some((host, Some(port)))
  }
  let first_colon = value.find(":")
  let last_colon = value.rev_find(":")
  if first_colon is Some(index) && last_colon == first_colon {
    let host = value[0:index].to_owned()
    let port_text = value[index + 1:].to_owned()
    if host.length() == 0 || !is_decimal_digits(port_text) {
      return None
    }
    let port = try {
      @string.parse_int(port_text[:])
    } catch {
      _ => return None
    }
    if port < 1 || port > 65535 {
      return None
    }
    return Some((host, Some(port)))
  }
  Some((value, None))
}

/// Parse a dotted-quad IPv4 address into its 32-bit numeric form. Leading
/// zeroes are rejected so an address cannot be interpreted differently by the
/// resolver (where they may mean octal) and the bypass matcher.
fn bypass_ipv4_value(value : String) -> Int? {
  let parts = value.split(".").collect()
  if parts.length() != 4 {
    return None
  }
  let mut result = 0
  for part in parts {
    let part = part.to_owned()
    if part.length() == 0 || part.length() > 3 || !is_decimal_digits(part) ||
      (part.length() > 1 && part.get_char(0) == Some('0')) {
      return None
    }
    let octet = try {
      @string.parse_int(part[:])
    } catch {
      _ => return None
    }
    if octet < 0 || octet > 255 {
      return None
    }
    result = (result << 8) | octet
  }
  Some(result)
}

fn bypass_prefix_matches(first : Int, second : Int, bits : Int) -> Bool {
  let mut remaining = bits
  let mut shift = 24
  while remaining > 0 {
    let take = if remaining < 8 { remaining } else { 8 }
    let mask = (0xff << (8 - take)) & 0xff
    if (((first >> shift) & 0xff) & mask) != (((second >> shift) & 0xff) & mask) {
      return false
    }
    remaining = remaining - take
    shift = shift - 8
  }
  true
}

fn bypass_hex_group(value : String) -> Int? {
  if value.length() == 0 || value.length() > 4 || !is_hex_digits(value) {
    return None
  }
  let group = try {
    @string.parse_int(value[:], base=16)
  } catch {
    _ => return None
  }
  Some(group)
}

/// Parse the colon-separated groups of one half of an IPv6 address. An
/// embedded dotted-quad tail is accepted only at the end when requested.
fn bypass_ipv6_groups(
  value : String,
  allow_ipv4_tail : Bool,
) -> Array[Int]? {
  if value.length() == 0 {
    return Some([])
  }
  let parts = value.split(":").collect()
  let groups : Array[Int] = []
  let mut index = 0
  for part in parts {
    let part = part.to_owned()
    index = index + 1
    if part.length() == 0 {
      return None
    }
    if allow_ipv4_tail && index == parts.length() && part.contains(".") {
      let address = match bypass_ipv4_value(part) {
        Some(address) => address
        None => return None
      }
      groups.push((address >> 16) & 0xffff)
      groups.push(address & 0xffff)
    } else {
      let group = match bypass_hex_group(part) {
        Some(group) => group
        None => return None
      }
      groups.push(group)
    }
  }
  Some(groups)
}

fn bypass_ipv6_bytes(value : String) -> Bytes? {
  let mut text = value
  if text.has_prefix("[") && text.has_suffix("]") {
    text = text[1:text.length() - 1].to_owned()
  }
  match text.find("%") {
    Some(index) => text = text[0:index].to_owned()
    None => ()
  }
  let groups = match text.find("::") {
    Some(index) => {
      let right_text = text[index + 2:].to_owned()
      if right_text.contains("::") {
        return None
      }
      let left = match bypass_ipv6_groups(text[0:index].to_owned(), false) {
        Some(groups) => groups
        None => return None
      }
      let right = match bypass_ipv6_groups(right_text, true) {
        Some(groups) => groups
        None => return None
      }
      if left.length() + right.length() >= 8 {
        return None
      }
      let groups = Array::make(8, 0)
      let mut left_index = 0
      while left_index < left.length() {
        groups[left_index] = left[left_index]
        left_index = left_index + 1
      }
      let mut right_index = 0
      while right_index < right.length() {
        groups[8 - right.length() + right_index] = right[right_index]
        right_index = right_index + 1
      }
      groups
    }
    None => {
      let groups = match bypass_ipv6_groups(text, true) {
        Some(groups) => groups
        None => return None
      }
      if groups.length() != 8 {
        return None
      }
      groups
    }
  }
  let output : Array[Byte] = Array::make(16, b'\x00')
  let mut index = 0
  while index < 8 {
    let group = groups[index]
    output[index * 2] = ((group >> 8) & 0xff).to_byte()
    output[index * 2 + 1] = (group & 0xff).to_byte()
    index = index + 1
  }
  Some(Bytes::from_array(output[:]))
}

fn bypass_prefix_bytes_match(first : Bytes, second : Bytes, bits : Int) -> Bool {
  let mut remaining = bits
  let mut index = 0
  while remaining > 0 {
    let take = if remaining < 8 { remaining } else { 8 }
    let mask = (0xff << (8 - take)) & 0xff
    if (first[index].to_int() & mask) != (second[index].to_int() & mask) {
      return false
    }
    remaining = remaining - take
    index = index + 1
  }
  true
}

/// Match `base/prefix` against a host. Returns false for anything that is not
/// a well-formed CIDR block, leaving ordinary host and path patterns to the
/// existing matcher.
fn bypass_cidr_matches(candidate : String, host : String) -> Bool {
  // A trailing root dot is part of the DNS presentation, not the address.
  // Normalize it so a numeric host such as `10.0.0.1.` still matches a CIDR.
  let host = normalize_bypass_host(host)
  let slash = match candidate.find("/") {
    Some(index) => index
    None => return false
  }
  let base = candidate[0:slash].to_owned()
  let prefix_text = candidate[slash + 1:].to_owned()
  if prefix_text.length() == 0 || !is_decimal_digits(prefix_text) {
    return false
  }
  let prefix = try {
    @string.parse_int(prefix_text[:])
  } catch {
    _ => return false
  }
  if prefix < 0 {
    return false
  }
  match (bypass_ipv4_value(base), bypass_ipv4_value(host)) {
    (Some(network), Some(address)) =>
      return prefix <= 32 && bypass_prefix_matches(network, address, prefix)
    _ => ()
  }
  let network = match bypass_ipv6_bytes(base) {
    Some(bytes) => bytes
    None => return false
  }
  let address = match bypass_ipv6_bytes(host) {
    Some(bytes) => bytes
    None => return false
  }
  prefix <= 128 && bypass_prefix_bytes_match(network, address, prefix)
}

fn proxy_bypass_matches(
  pattern : String,
  host : String,
  port : Int,
  bracketed? : Bool,
) -> Bool {
  let bracketed = bracketed.unwrap_or(false)
  let trimmed = pattern.trim().to_lower()
  if trimmed.length() == 0 {
    return false
  }
  if trimmed == "*" {
    return true
  }
  let mut candidate = trimmed.to_owned()
  match candidate.find("://") {
    Some(index) => candidate = candidate[index + 3:].to_owned()
    None => ()
  }
  if candidate == "*" {
    return true
  }
  // A `network/prefix` entry is a CIDR block, not a host followed by a path.
  // If the text before the slash is an IP literal (or a numeric dotted
  // address that is malformed as IPv4), the entry is unambiguously a CIDR
  // block: a malformed prefix must not fall through to the generic path
  // stripping below and match the bare base address as a plain host.
  match candidate.find("/") {
    Some(index) => {
      let base = candidate[0:index].to_owned()
      let looks_like_cidr = bypass_ipv4_value(base) is Some(_) ||
        bypass_ipv6_bytes(base) is Some(_) ||
        is_numeric_dotted_host(base)
      if looks_like_cidr {
        return bypass_cidr_matches(candidate, host)
      }
      candidate = base
    }
    None => ()
  }
  let (raw_pattern_host, pattern_port) = match parse_bypass_authority(candidate) {
    Some(parts) => parts
    None => return false
  }
  if pattern_port is Some(expected_port) && expected_port != port {
    return false
  }
  // Bracketed patterns denote IP literals. A bracketed IPvFuture literal has
  // DNS-looking text, so it must not match the same text used as a DNS name
  // (and vice versa), mirroring the authority distinction used elsewhere.
  let pattern_bracketed = candidate.has_prefix("[")
  if pattern_bracketed && !is_ip_literal(raw_pattern_host) {
    return false
  }
  if pattern_bracketed && !bracketed && is_ipvfuture_literal(raw_pattern_host) {
    return false
  }
  if bracketed && !pattern_bracketed && is_ipvfuture_literal(host) {
    return false
  }
  let mut pattern_host = raw_pattern_host.to_lower()
  let explicit_domain = pattern_host.has_prefix("*.") ||
    pattern_host.has_prefix(".")
  if pattern_host.has_prefix("*.") {
    pattern_host = pattern_host[2:].to_owned()
  } else if pattern_host.has_prefix(".") {
    pattern_host = pattern_host[1:].to_owned()
  }
  pattern_host = normalize_bypass_host(pattern_host)
  if pattern_host.length() == 0 || pattern_host.contains("*") {
    return false
  }
  let normalized_host = normalize_bypass_host(host)
  if pattern_host == normalized_host {
    return true
  }
  let numeric_ip = pattern_host.contains(":") ||
    is_ipv4_literal(pattern_host) ||
    is_numeric_dotted_host(pattern_host)
  // A bare label such as `com` is a public suffix, not a domain owned by the
  // caller; only match subdomains for multi-label domain patterns. An explicit
  // `*.` or leading `.` opts into subdomain matching even for a single label
  // such as `*.localhost`. The same numeric check keeps partial or malformed
  // numeric hosts from matching by suffix.
  !numeric_ip &&
  (pattern_host.contains(".") || explicit_domain) &&
  normalized_host.has_suffix("." + pattern_host)
}

fn Connector::proxy_is_bypassed(self : Connector, url : Url) -> Bool {
  for pattern in self.proxy_bypass {
    if proxy_bypass_matches(pattern, url.host, url.port, bracketed=url.bracketed) {
      return true
    }
  }
  false
}

/// The proxy used for `url`, or `None` when the URL is not proxied because no
/// proxy is configured or a bypass rule matches its host.
pub fn Connector::proxy_for_url(self : Connector, url : Url) -> Proxy? {
  if self.proxy_is_bypassed(url) {
    return None
  }
  self.proxy
}

/// Whether requests for `url` must use absolute-form request targets (plain
/// HTTP sent to a forward proxy).
pub fn Connector::uses_absolute_form(self : Connector, url : Url) -> Bool {
  self.proxy_for_url(url) is Some(proxy) &&
  !proxy.is_socks5() &&
  url.scheme.to_lower() == "http"
}

/// Proxy credentials for requests that travel through the proxy itself.
pub fn Connector::proxy_authorization(self : Connector) -> String? {
  match self.proxy {
    Some(proxy) => proxy.authorization
    None => None
  }
}

/// Proxy credentials for `url`, or `None` when the request goes directly to
/// the origin (including when a bypass rule applies).
pub fn Connector::proxy_authorization_for(self : Connector, url : Url) -> String? {
  match self.proxy_for_url(url) {
    Some(proxy) => if proxy.is_socks5() { None } else { proxy.authorization }
    None => None
  }
}

/// Cap the number of idle (keep-alive) connections retained per host.
/// A value below 1 is clamped to 1. Connections beyond the cap are closed.
pub fn Connector::with_max_idle_per_host(
  self : Connector,
  max_idle : Int,
) -> Connector {
  self.pool.val.max_idle = if max_idle < 1 { 1 } else { max_idle }
  self.pool.val.trim_idle()
  self
}

/// The current per-host idle connection cap.
pub fn Connector::max_idle_per_host(self : Connector) -> Int {
  self.pool.val.max_idle
}

/// Cap the number of simultaneously checked-out connections per host. A value
/// below 1 means unlimited (the default). Requests that exceed the cap fail
/// with a connection error instead of opening another socket.
pub fn Connector::with_max_connections_per_host(
  self : Connector,
  max_connections : Int,
) -> Connector {
  self.max_connections_per_host = if max_connections < 1 { 0 } else { max_connections }
  self
}

/// The current per-host connection cap; `0` means unlimited.
pub fn Connector::max_connections_per_host(self : Connector) -> Int {
  self.max_connections_per_host
}

/// Advertise HTTP/2 through ALPN when no explicit TLS configuration is set.
/// An explicit `with_tls_config` value is respected as-is, so callers that
/// want HTTP/2 with shared credentials must include `h2` in its ALPN list.
pub fn Connector::with_http2(self : Connector, enabled : Bool) -> Connector {
  // Disabling HTTP/2 also disables cleartext prior knowledge; enabling it
  // leaves the existing prior-knowledge policy untouched.
  if self.http2 == enabled && (enabled || !self.http2_prior_knowledge) {
    return self
  }
  // Existing connections negotiated the old ALPN list and cannot be reused
  // for the new HTTP version policy.
  let pool = @ref.Ref(self.pool.val.empty_with_settings())
  let _ = self.close_all()
  Connector::{
    ..self,
    http2: enabled,
    http2_prior_knowledge: enabled && self.http2_prior_knowledge,
    pool,
  }
}

/// Whether default TLS configurations advertise HTTP/2.
pub fn Connector::http2_enabled(self : Connector) -> Bool {
  self.http2
}

/// Use HTTP/2 for cleartext `http://` origins without an ALPN negotiation
/// (prior knowledge, RFC 9113 §3.4). This is opt-in because a server that only
/// speaks HTTP/1.1 will reject the HTTP/2 client preface. HTTPS requests keep
/// using normal ALPN negotiation.
pub fn Connector::with_http2_prior_knowledge(
  self : Connector,
  enabled : Bool,
) -> Connector {
  if self.http2_prior_knowledge == enabled &&
    (!enabled || self.http2) {
    return self
  }
  let pool = @ref.Ref(self.pool.val.empty_with_settings())
  let _ = self.close_all()
  Connector::{
    ..self,
    // Prior knowledge is an HTTP/2 policy, so enabling it also enables the
    // normal TLS ALPN advertisement for HTTPS origins.
    http2: enabled || self.http2,
    http2_prior_knowledge: enabled,
    pool,
  }
}

/// Whether cleartext origins use HTTP/2 prior knowledge.
pub fn Connector::http2_prior_knowledge(self : Connector) -> Bool {
  self.http2 && self.http2_prior_knowledge
}

/// The name passed to the TLS provider for a URL. Bracketed IPvFuture
/// literals must keep their brackets so the provider treats them as IP
/// literals instead of DNS names; bracketed IPv6 addresses are already
/// understood without brackets.
fn tls_server_name_for_url(url : Url) -> String {
  if url.bracketed && !is_ipv6_literal_with_zone(url.host) {
    "[" + url.host + "]"
  } else {
    url.host
  }
}

fn Connector::origin_tls_config(self : Connector, host : String) -> TlsConfig {
  match self.tls_config {
    Some(config) => config.with_server_name(host)
    None => {
      let config = TlsConfig::new(host)
      if self.http2 {
        config.with_alpn(@list.List(["h2", "http/1.1"]))
      } else {
        config
      }
    }
  }
}

/// Discard pooled connections that have been idle for longer than
/// `idle_timeout_ms`. A value below 1 disables idle eviction.
pub fn Connector::with_idle_timeout(self : Connector, idle_timeout_ms : Int) -> Connector {
  self.pool.val.idle_timeout_ms = if idle_timeout_ms < 0 { 0 } else { idle_timeout_ms }
  self.pool.val.sweep_expired(@env.now())
  self
}

/// The current idle timeout; `0` means idle connections are never evicted.
pub fn Connector::idle_timeout(self : Connector) -> Int {
  self.pool.val.idle_timeout_ms
}

/// Enable or disable the cookie jar for requests made through this connector.
/// Cookie handling is disabled by default.
pub fn Connector::with_cookies(self : Connector, enabled : Bool) -> Connector {
  self.cookies_enabled = enabled
  self
}

/// Whether cookie storage and replay is enabled.
pub fn Connector::cookies_enabled(self : Connector) -> Bool {
  self.cookies_enabled
}

/// Replace the cookie jar and enable cookie handling. The derived connector
/// gets its own jar reference so it cannot replace a jar shared with another
/// connector.
pub fn Connector::with_cookie_jar(self : Connector, jar : CookieJar) -> Connector {
  Connector::{
    ..self,
    cookies_enabled: true,
    cookie_jar: @ref.Ref(jar),
  }
}

/// The connector's cookie jar.
pub fn Connector::cookie_jar(self : Connector) -> CookieJar {
  self.cookie_jar.val
}

/// The `Cookie` header value for `url`, if cookie handling is enabled.
pub fn Connector::cookie_header(self : Connector, url : Url) -> String? {
  if !self.cookies_enabled {
    return None
  }
  self.cookie_jar.val.cookie_header(url)
}

/// Store every `Set-Cookie` header from a response to `url`.
pub fn Connector::store_cookies(
  self : Connector,
  url : Url,
  headers : Headers,
) -> Unit {
  if self.cookies_enabled {
    self.cookie_jar.val.store_from_headers(url, headers)
  }
}

fn Connector::connection_key(self : Connector, url : Url) -> String {
  // IP literals and DNS names can have the same text (IPvFuture); keep the
  // bracketing distinction so a connection verified for one authority is
  // never reused for the other.
  let authority = url_authority_host(url.host.to_lower(), url.bracketed)
  let origin = url.scheme.to_lower() + "://" + authority + ":" + url.port.to_string()
  match self.proxy_for_url(url) {
    Some(proxy) => {
      // Preserve the proxy authority form as well: an IPvFuture literal that
      // looks like a DNS name must not share a key with that DNS name.
      let proxy_authority = url_authority_host(
        proxy.url.host.to_lower(),
        proxy.url.bracketed,
      )
      "proxy:" +
      proxy.url.scheme.to_lower() +
      "://" +
      proxy_authority +
      ":" +
      proxy.url.port.to_string() +
      "|" +
      origin
    }
    None => origin
  }
}

/// TLS settings for reaching an HTTPS proxy. The proxy always speaks HTTP/1.1,
/// so it must not inherit an ALPN list meant for the origin (for example one
/// that advertises `h2`). Client certificates are origin credentials and are
/// deliberately not sent to the proxy.
fn Connector::proxy_tls_config(self : Connector, proxy : Proxy) -> TlsConfig {
  let server_name = tls_server_name_for_url(proxy.url)
  let base = match self.tls_config {
    Some(config) => config
    None => TlsConfig::new(server_name)
  }
  TlsConfig::{
    server_name,
    alpn: @list.List(["http/1.1"]),
    root_store: base.root_store,
    client_auth: None,
    verify: base.verify,
    min_version: base.min_version,
    key_log: base.key_log,
  }
}

/// Locate the end of the header section (`CRLFCRLF`) and return the offset just
/// past it. The terminator is searched for rather than only inspected at the
/// end of the buffer because a single read may deliver the whole CONNECT
/// response plus tunnel data that belongs to the peer's next protocol.
fn find_head_end(data : Bytes) -> Int? {
  let length = data.length()
  let mut index = 0
  while index + 3 < length {
    if data[index] == b'\r' && data[index + 1] == b'\n' &&
      data[index + 2] == b'\r' && data[index + 3] == b'\n' {
      return Some(index + 4)
    }
    index = index + 1
  }
  None
}

/// Validate one CONNECT response head and return its status code. Header
/// lines are checked here (rather than ignored) so a malformed response cannot
/// make arbitrary tunnel bytes look like the end of the header section.
fn parse_connect_response_head(head : Bytes) -> Result[Int, HttpError] {
  let text = @utf8.decode_lossy(head)
  let line_end = match text.find("\r\n") {
    Some(index) => index
    None => return Err(ProtocolError("Invalid proxy CONNECT response"))
  }
  let status_line = text[0:line_end].to_owned()
  let first_space = match status_line.find(" ") {
    Some(index) => index
    None => return Err(ProtocolError("Invalid proxy CONNECT response"))
  }
  let version = status_line[0:first_space].to_owned()
  if version != "HTTP/1.1" && version != "HTTP/1.0" {
    return Err(ProtocolError("Unsupported HTTP version"))
  }
  let mut start = first_space
  while start < status_line.length() &&
    status_line.get_char(start) == Some(' ') {
    start = start + 1
  }
  let mut stop = start
  while stop < status_line.length() &&
    status_line.get_char(stop) != Some(' ') {
    stop = stop + 1
  }
  let status_text = status_line[start:stop].to_owned()
  if stop - start != 3 || !is_decimal_digits(status_text) {
    return Err(ProtocolError("Invalid proxy CONNECT response"))
  }
  let status = try {
    @string.parse_int(status_text[:])
  } catch {
    _ => return Err(ProtocolError("Invalid proxy CONNECT response"))
  }
  if status < 100 || status > 599 {
    return Err(ProtocolError("Invalid proxy CONNECT response"))
  }
  if !valid_header_value(status_line[stop:].to_owned()) {
    return Err(ProtocolError("Invalid proxy CONNECT response"))
  }
  let lines = text.split("\r\n").collect()
  let mut index = 1
  let mut header_count = 0
  while index < lines.length() {
    let line = lines[index]
    if line.length() == 0 {
      return Ok(status)
    }
    if line.get_char(0) == Some(' ') || line.get_char(0) == Some('\t') {
      return Err(ProtocolError("Invalid proxy CONNECT response headers"))
    }
    header_count = header_count + 1
    if header_count > MAX_RESPONSE_HEADERS {
      return Err(ProtocolError("Too many proxy CONNECT response headers"))
    }
    let colon_idx = match line.find(":") {
      Some(value) => value
      None => return Err(ProtocolError("Invalid proxy CONNECT response headers"))
    }
    let name = line[0:colon_idx].to_owned()
    if !valid_header_name(name) {
      return Err(ProtocolError("Invalid proxy CONNECT response headers"))
    }
    let raw_value = line[colon_idx + 1:].to_owned()
    if !valid_header_value(raw_value) {
      return Err(ProtocolError("Invalid proxy CONNECT response headers"))
    }
    // Interim responses cannot carry content, so framing fields would be
    // meaningless and could otherwise desynchronize the tunnel parsing.
    let lower_name = name.to_lower()
    if status < 200 &&
      (lower_name == "content-length" || lower_name == "transfer-encoding") {
      return Err(ProtocolError(
        "Informational proxy response must not include framing headers",
      ))
    }
    index = index + 1
  }
  Err(ProtocolError("Invalid proxy CONNECT response"))
}

/// Read the proxy's CONNECT response head. Informational responses (except
/// `101 Switching Protocols`) are skipped. Returns any bytes that were read
/// past the end of the final head, which belong to the tunnelled stream and
/// must be replayed before reading further from `stream`.
fn read_connect_response(stream : &Stream) -> Result[Bytes, HttpError] {
  let head = Buffer(size_hint=128)
  let limit = 16384
  let mut offset = 0
  while head.length() <= limit {
    let chunk = Buffer(size_hint=512)
    let count = match stream.read(chunk) {
      Ok(count) => count
      Err(err) => return Err(NetworkError(err))
    }
    if count <= 0 {
      return Err(NetworkError(ConnectionFailed(
        "proxy closed the connection during CONNECT",
      )))
    }
    let bytes = chunk.to_bytes()
    if bytes.length() == 0 {
      return Err(NetworkError(ReadError("stream returned no data")))
    }
    head.write_bytes(bytes)
    let data = head.to_bytes()
    let mut progressed = true
    while progressed {
      progressed = false
      let remaining = data.exact_view(start=offset, end=data.length()).to_owned()
      match find_head_end(remaining) {
        Some(relative_end) => {
          let head_end = offset + relative_end
          if head_end > limit {
            return Err(ProtocolError("proxy CONNECT response headers too large"))
          }
          let status = match parse_connect_response_head(
            data.exact_view(start=offset, end=head_end).to_owned(),
          ) {
            Ok(value) => value
            Err(err) => return Err(err)
          }
          if status >= 100 && status < 200 && status != 101 {
            offset = head_end
            progressed = true
          } else {
            if status < 200 || status > 299 {
              return Err(ProtocolError(
                "proxy CONNECT failed with status " + status.to_string(),
              ))
            }
            // Only the final head belongs to this exchange; any trailing
            // bytes are the first bytes of the tunnelled stream and must be
            // replayed by the caller instead of being discarded.
            return Ok(
              data.exact_view(start=head_end, end=data.length()).to_owned(),
            )
          }
        }
        None => ()
      }
    }
  }
  Err(ProtocolError("proxy CONNECT response headers too large"))
}

fn connect_authority(url : Url) -> String {
  url.connect_authority()
}

fn establish_tunnel(
  stream : &Stream,
  url : Url,
  proxy : Proxy,
) -> Result[Bytes, HttpError] {
  let authority = connect_authority(url)
  let mut request = "CONNECT " + authority + " HTTP/1.1\r\nHost: " + authority + "\r\n"
  match proxy.authorization {
    Some(value) => request = request + "Proxy-Authorization: " + value + "\r\n"
    None => ()
  }
  request = request + "\r\n"
  match write_all(stream, @utf8.encode(request)) {
    Ok(_) => ()
    Err(err) => return Err(NetworkError(err))
  }
  match stream.flush() {
    Ok(_) => ()
    Err(err) => return Err(NetworkError(err))
  }
  read_connect_response(stream)
}

/// Connect to a URL (either HTTP or HTTPS).
///
/// The returned stream is also placed in the connection pool, so a later
/// `connect` or `checkout` for the same origin may take it back while it is
/// still in use. Callers that need exclusive ownership should prefer
/// `checkout`, which returns a lease that recycles the stream when the
/// exchange finishes.
pub fn Connector::connect(self : Connector, url : Url) -> Result[&Stream, HttpError] {
  let request_timeout = self.timeout_ms
  let connect_timeout = effective_connect_timeout(
    request_timeout,
    self.connect_timeout_ms,
  )
  // Cache only after the timeout has been applied successfully. Publishing the
  // stream first would leave a closed socket in the idle pool when
  // `set_timeout` fails, so a later checkout could hand it out again.
  match self.connect_impl(url, false, false, connect_timeout) {
    Ok((stream, reused, negotiated_protocol, h2)) => {
      // The connect timeout only bounds dialing and the TLS handshake; restore
      // the request timeout for the bytes exchanged after the connection is up.
      // A pooled stream may still carry the timeout from its previous request,
      // so apply the current request timeout even when it was reused.
      match stream.set_timeout(request_timeout) {
        Ok(_) => ()
        Err(err) => {
          let _ = stream.close()
          return Err(http_error_from_net(err))
        }
      }
      if !reused && h2 is None && negotiated_protocol != Some("h2") {
        self.pool.val.cache_idle_with_protocol(
          self.connection_key(url),
          stream,
          @env.now(),
          negotiated_protocol,
        )
      }
      Ok(stream)
    }
    Err(err) => Err(err)
  }
}

fn Connector::connect_impl(
  self : Connector,
  url : Url,
  cache_new : Bool,
  accept_h2_pool : Bool,
  timeout_ms : Int,
) -> Result[(&Stream, Bool, String?, H2ClientConnection?), HttpError] {
  // Expire idle sockets for every origin, not just the one being requested.
  self.pool.val.sweep_expired(@env.now())
  let scheme = url.scheme.to_lower()
  let host = url.host
  let port = url.port
  if scheme != "http" && scheme != "https" {
    return Err(InvalidUrl("Only http and https schemes supported"))
  }
  if !valid_tcp_host(host) {
    return Err(InvalidUrl("Invalid host"))
  }
  if port < 1 || port > 65535 {
    return Err(InvalidUrl("Invalid port number"))
  }

  let conn_key = self.connection_key(url)
  let proxy = self.proxy_for_url(url)
  // A bracketed IPvFuture literal is not a DNS name. Keep its brackets when
  // handing it to the TLS provider so SNI is not attempted for it. Bracketed
  // IPv6 addresses keep the raw host form understood by every provider.
  let tls_host = tls_server_name_for_url(url)

  // Validate proxy settings before opening any socket.
  match proxy {
    Some(proxy) => {
      if !valid_tcp_host(proxy.url.host) || !valid_tcp_port(proxy.url.port) {
        return Err(InvalidUrl("Invalid proxy address"))
      }
      if proxy.is_secure() {
        match self.proxy_tls_config(proxy).validate() {
          Ok(_) => ()
          Err(err) => return Err(TlsError(err))
        }
      }
      if proxy.is_socks5() {
        match proxy.socks_credentials() {
          Some((username, password)) =>
            match socks5_credentials_valid(username, password) {
              Ok(_) => ()
              Err(err) => return Err(err)
            }
          None => ()
        }
      }
    }
    None => ()
  }

  // Validate TLS settings before opening a socket. The connection host
  // overrides any server name from the shared configuration.
  if scheme == "https" {
    let tls_config = self.origin_tls_config(tls_host)
    match tls_config.validate() {
      Ok(_) => ()
      Err(err) => return Err(TlsError(err))
    }
  }

  // Refuse to exceed the per-host connection cap before taking an idle
  // connection, otherwise a pool with more idle entries than the cap could
  // hand out enough streams to exceed it. The check is done before dialing so
  // no socket is wasted.
  if self.max_connections_per_host > 0 &&
    self.pool.val.active_count(conn_key) >= self.max_connections_per_host {
    return Err(NetworkError(ConnectionFailed(
      "connection limit reached for " + conn_key,
    )))
  }

  // Check if we have a cached connection. A plain `connect` cannot take an
  // HTTP/2 session because the caller would issue a fresh preface; that path
  // skips and closes cached sessions, then dials a fresh connection.
  match take_idle_connection_at(
    self.pool,
    conn_key,
    @env.now(),
    accept_h2=accept_h2_pool,
  ) {
    Some((stream, negotiated_protocol, h2)) => {
      return Ok((stream, true, negotiated_protocol, h2))
    }
    None => ()
  }

  // Dial the proxy when one is configured, otherwise dial the origin. Keep
  // the bracketed form for IPvFuture literals so a custom dialer can tell them
  // apart from the DNS name with the same text.
  let (dial_host, dial_port) = match proxy {
    Some(proxy) => (tls_server_name_for_url(proxy.url), proxy.url.port)
    None => (tls_host, port)
  }
  // The dialer may have been constructed with a different timeout (for
  // example before `UnifiedClient::with_timeout` was called), so apply the
  // effective policy for this checkout before it opens the socket.
  self.dialer.set_timeout(timeout_ms)
  // Plain `socks5://` resolves the destination locally and sends its address;
  // `socks5h://` leaves the name for the proxy to resolve. Do the lookup before
  // dialing so a resolution failure does not consume a proxy connection.
  let mut socks_target_host = host
  let mut socks_target_bracketed = url.bracketed
  match proxy {
    Some(proxy) =>
      if proxy.is_socks5() && !proxy.is_socks5h() && !url.bracketed &&
        !is_ipv4_literal(host) && !is_ipv6_literal_with_zone(host) {
        let addresses = match self.dialer.resolve(host) {
          Ok(addresses) => addresses
          Err(err) => return Err(NetworkError(err))
        }
        if addresses.length() == 0 {
          return Err(NetworkError(InvalidAddress(
            "DNS resolution returned no addresses for " + host,
          )))
        }
        socks_target_host = addresses.nth(0).unwrap()
        socks_target_bracketed = false
      }
    None => ()
  }
  let raw_stream = match self.dialer.dial_tcp(dial_host, dial_port) {
    Ok(stream) => stream
    Err(err) => return Err(NetworkError(err))
  }

  // Bound both plain HTTP I/O and the TLS handshake using the same timeout.
  match raw_stream.set_timeout(timeout_ms) {
    Ok(_) => ()
    Err(err) => {
      let _ = raw_stream.close()
      return Err(NetworkError(err))
    }
  }

  // An HTTPS proxy is reached over TLS before the proxy protocol starts, and a
  // SOCKS5 proxy is tunnelled immediately after dialing. The resulting stream
  // carries either absolute-form HTTP, a CONNECT tunnel, or a SOCKS tunnel.
  let proxy_stream : &Stream = match proxy {
    Some(proxy) =>
      if proxy.is_socks5() {
        let leftover = match socks5_connect(
          raw_stream,
          socks_target_host,
          port,
          socks_target_bracketed,
          proxy.socks_credentials(),
        ) {
          Ok(leftover) => leftover
          Err(err) => {
            let _ = raw_stream.close()
            return Err(err)
          }
        }
        if leftover.length() > 0 {
          let prefix : &Stream = PrefixStream::new(leftover, raw_stream)
          prefix
        } else {
          raw_stream
        }
      } else if proxy.is_secure() {
        let config = self.proxy_tls_config(proxy)
        let ctx = match self.tls_provider.new_client(config) {
          Ok(ctx) => ctx
          Err(err) => {
            let _ = raw_stream.close()
            return Err(TlsError(err))
          }
        }
        match ctx.connect(raw_stream) {
          Ok(stream) => stream
          Err(err) => {
            let _ = raw_stream.close()
            return Err(TlsError(err))
          }
        }
      } else {
        raw_stream
      }
    None => raw_stream
  }

  // For HTTPS through an HTTP proxy, open a CONNECT tunnel before starting
  // TLS. A SOCKS5 proxy already established the tunnel above.
  let mut tunnel_leftover : Bytes = b""
  if scheme == "https" {
    match proxy {
      Some(proxy) =>
        if !proxy.is_socks5() {
          match establish_tunnel(proxy_stream, url, proxy) {
            Ok(leftover) => tunnel_leftover = leftover
            Err(err) => {
              let _ = proxy_stream.close()
              return Err(err)
            }
          }
        }
      None => ()
    }
  }

  // If HTTPS, wrap with TLS
  if scheme == "https" {
    // Use the shared configuration when present, otherwise secure defaults.
    let tls_config = self.origin_tls_config(tls_host)
    let tls_config = match tls_config.validate() {
      Ok(_) => tls_config
      Err(err) => {
        let _ = proxy_stream.close()
        return Err(TlsError(err))
      }
    }

    // A single socket read during CONNECT may have delivered the first bytes
    // of the tunnelled stream; replay them ahead of the socket so the TLS
    // handshake sees the whole record.
    let tls_underlying : &Stream = if tunnel_leftover.length() > 0 {
      let prefix : &Stream = PrefixStream::new(tunnel_leftover, proxy_stream)
      prefix
    } else {
      proxy_stream
    }

    // Create TLS client context
    let tls_ctx = match self.tls_provider.new_client(tls_config) {
      Ok(ctx) => ctx
      Err(err) => {
        let _ = proxy_stream.close()
        return Err(TlsError(err))
      }
    }

    // Perform TLS handshake
    let tls_stream = match tls_ctx.connect(tls_underlying) {
      Ok(stream) => stream
      Err(err) => {
        let _ = proxy_stream.close()
        return Err(TlsError(err))
      }
    }

    let negotiated_protocol = tls_ctx.negotiated_alpn()
    if cache_new && negotiated_protocol != Some("h2") {
      self.pool.val.cache_idle_with_protocol(
        conn_key,
        tls_stream,
        @env.now(),
        negotiated_protocol,
      )
    }
    Ok((tls_stream, false, negotiated_protocol, None))
  } else {
    // For plain HTTP, use the proxy stream (raw or TLS-to-proxy) directly.
    // Prior knowledge can only be used on a direct connection: an HTTP proxy
    // expects an HTTP/1.1 request in absolute-form, not an HTTP/2 preface.
    if proxy is None && self.http2 && self.http2_prior_knowledge {
      // The caller (or `checkout`) starts the HTTP/2 session on this stream.
      // Do not cache it as an HTTP/1.1 connection.
      Ok((proxy_stream, false, Some("h2"), None))
    } else {
      if cache_new {
        self.pool.val.cache_idle(conn_key, proxy_stream, @env.now())
      }
      Ok((proxy_stream, false, None, None))
    }
  }
}

pub fn Connector::checkout(
  self : Connector,
  url : Url,
  timeout_ms? : Int,
) -> Result[(&Stream, ConnectionLease), HttpError] {
  let request_timeout = timeout_ms.unwrap_or(self.timeout_ms)
  let connect_timeout = effective_connect_timeout(
    request_timeout,
    self.connect_timeout_ms,
  )
  // A newly dialed stream still carries the connect-only deadline. The
  // checked-out caller applies its request timeout before writing anything;
  // doing it here would consume a timeout-retry opportunity and hide a stale
  // stream from the request layer.
  let conn_key = self.connection_key(url)
  let (stream, reused, negotiated_protocol, h2) = match self.connect_impl(
    url,
    false,
    true,
    connect_timeout,
  ) {
    Ok(connection) => connection
    Err(err) => return Err(err)
  }
  let h2 = match h2 {
    Some(connection) => Some(connection)
    None =>
      if negotiated_protocol == Some("h2") {
        match H2ClientConnection::new(stream) {
          Ok(connection) => Some(connection)
          Err(err) => {
            let _ = stream.close()
            return Err(err)
          }
        }
      } else {
        None
      }
  }
  let id = self.pool.val.next_id
  self.pool.val.next_id = id + 1
  self.pool.val.active = self.pool.val.active.prepend(
    ActiveConnection::{ id, key: conn_key, stream, h2 },
  )
  Ok((
    stream,
    ConnectionLease::{
      id,
      key: conn_key,
      stream,
      negotiated_protocol,
      h2,
      reused,
      released: false,
      pool: self.pool,
    },
  ))
}

/// The persistent HTTP/2 connection associated with this lease, if the
/// negotiated protocol is `h2`.
fn ConnectionLease::h2_connection(self : ConnectionLease) -> H2ClientConnection? {
  self.h2
}

/// Close a connection and remove from pool
pub fn Connector::close(self : Connector, url : Url) -> Result[Unit, HttpError] {
  let conn_key = self.connection_key(url)

  match self.pool.val.idle.get(conn_key) {
    Some(entries) => {
      for entry in entries {
        match entry.h2 {
          Some(connection) => connection.close()
          None => {
            let _ = entry.stream.close()
          }
        }
      }
      let _ = self.pool.val.idle.remove(conn_key)
    }
    None => ()
  }
  let key = conn_key
  for entry in self.pool.val.active {
    if entry.key == key {
      match entry.h2 {
        Some(connection) => connection.close()
        None => {
          let _ = entry.stream.close()
        }
      }
    }
  }
  self.pool.val.active = self.pool.val.active.filter(fn(entry) { entry.key != key })
  Ok(())
}

/// Number of idle connections currently retained for reuse.
pub fn Connector::idle_connection_count(self : Connector) -> Int {
  self.pool.val.idle_count()
}

/// Number of connections currently checked out by a caller.
pub fn Connector::active_connection_count(self : Connector) -> Int {
  self.pool.val.active.length()
}

/// Total number of live connections owned by this connector, both checked out
/// and idle. Connections that failed a liveness probe are not counted after
/// the next pool operation sweeps them.
pub fn Connector::connection_count(self : Connector) -> Int {
  self.idle_connection_count() + self.active_connection_count()
}

/// Close every idle pooled connection while leaving checked-out connections
/// alone. This is useful before forking or when an application has finished a
/// burst of requests but still owns streaming bodies.
pub fn Connector::close_idle(self : Connector) -> Result[Unit, HttpError] {
  for _conn_key, entries in self.pool.val.idle.iter2() {
    for entry in entries {
      match entry.h2 {
        Some(connection) => connection.close()
        None => {
          let _ = entry.stream.close()
        }
      }
    }
  }
  self.pool.val.idle = Map([])
  Ok(())
}

pub fn Connector::close_all(self : Connector) -> Result[Unit, HttpError] {
  for _conn_key, entries in self.pool.val.idle.iter2() {
    for entry in entries {
      match entry.h2 {
        Some(connection) => connection.close()
        None => {
          let _ = entry.stream.close()
        }
      }
    }
  }
  for entry in self.pool.val.active {
    match entry.h2 {
      Some(connection) => connection.close()
      None => {
        let _ = entry.stream.close()
      }
    }
  }
  self.pool.val.idle = Map([])
  self.pool.val.active = @list.List([])
  Ok(())
}
