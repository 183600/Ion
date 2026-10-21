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
}

struct IdleConnection {
  stream : &Stream
  last_used_ms : UInt64
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
  let idle = match self.idle.get(key) {
    Some(streams) => streams
    None => @list.List([])
  }
  let mut updated = idle.prepend(IdleConnection::{ stream, last_used_ms: now_ms })
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

/// Connector handles the connection establishment logic
pub struct Connector {
  dialer : &Dialer
  tls_provider : &TlsProvider
  tls_config : TlsConfig?
  proxy : Proxy?
  timeout_ms : Int
  mut max_connections_per_host : Int
  mut cookies_enabled : Bool
  cookie_jar : @ref.Ref[CookieJar]
  pool : @ref.Ref[ConnectionPoolState]
}

pub struct ConnectionLease {
  priv id : Int
  priv key : String
  priv stream : &Stream
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
  if reusable {
    match self.stream.peer_addr() {
      Ok(_) => self.pool.val.cache_idle(self.key, self.stream, @env.now())
      Err(_) => {
        let _ = self.stream.close()
      }
    }
  } else {
    let _ = self.stream.close()
  }
}

/// Remove and return an idle connection for `key`. Entries whose last use is
/// older than the configured idle timeout are closed and skipped; the search
/// stops at the first live entry because `idle` is ordered by recency.
fn take_idle_stream_at(
  pool : @ref.Ref[ConnectionPoolState],
  key : String,
  now_ms : UInt64,
) -> Option[&Stream] {
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
        let alive = if expired { false } else { entry.stream.peer_addr() is Ok(_) }
        if expired || !alive {
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
        return Some(entry.stream)
      }
      None => {
        let _ = pool.val.idle.remove(key)
        return None
      }
    }
  }
  None
}

fn take_idle_stream(
  pool : @ref.Ref[ConnectionPoolState],
  key : String,
) -> Option[&Stream] {
  take_idle_stream_at(pool, key, @env.now())
}

pub fn Connector::new(dialer : &Dialer, tls_provider : &TlsProvider) -> Connector {
  Connector::{
    dialer,
    tls_provider,
    tls_config: None,
    proxy: None,
    timeout_ms: 30000,
    max_connections_per_host: 0,
    cookies_enabled: false,
    cookie_jar: @ref.Ref(CookieJar::new()),
    pool: @ref.Ref(ConnectionPoolState::new()),
  }
}

/// Set the timeout applied to newly dialed connections and TLS handshakes.
pub fn Connector::with_timeout(self : Connector, timeout_ms : Int) -> Connector {
  let timeout_ms = if timeout_ms < 0 { 0 } else { timeout_ms }
  Connector::{ ..self, timeout_ms }
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
    timeout_ms: self.timeout_ms,
    max_connections_per_host: self.max_connections_per_host,
    cookies_enabled: self.cookies_enabled,
    cookie_jar: self.cookie_jar,
    pool,
  }
}

/// Route every request through an HTTP proxy. Existing pooled connections were
/// made directly, so they are closed and cannot be reused.
pub fn Connector::with_proxy(self : Connector, proxy : Proxy) -> Connector {
  let pool = @ref.Ref(self.pool.val.empty_with_settings())
  let _ = self.close_all()
  Connector::{
    dialer: self.dialer,
    tls_provider: self.tls_provider,
    tls_config: self.tls_config,
    proxy: Some(proxy),
    timeout_ms: self.timeout_ms,
    max_connections_per_host: self.max_connections_per_host,
    cookies_enabled: self.cookies_enabled,
    cookie_jar: self.cookie_jar,
    pool,
  }
}

/// Whether requests for `url` must use absolute-form request targets (plain
/// HTTP sent to a forward proxy).
pub fn Connector::uses_absolute_form(self : Connector, url : Url) -> Bool {
  self.proxy is Some(_) && url.scheme.to_lower() == "http"
}

/// Proxy credentials for requests that travel through the proxy itself.
pub fn Connector::proxy_authorization(self : Connector) -> String? {
  match self.proxy {
    Some(proxy) => proxy.authorization
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

/// Discard pooled connections that have been idle for longer than
/// `idle_timeout_ms`. A value below 1 disables idle eviction.
pub fn Connector::with_idle_timeout(self : Connector, idle_timeout_ms : Int) -> Connector {
  self.pool.val.idle_timeout_ms = if idle_timeout_ms < 0 { 0 } else { idle_timeout_ms }
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

/// Replace the cookie jar and enable cookie handling.
pub fn Connector::with_cookie_jar(self : Connector, jar : CookieJar) -> Connector {
  self.cookie_jar.val = jar
  self.cookies_enabled = true
  self
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
  let origin = url.scheme.to_lower() + "://" + url.host.to_lower() + ":" + url.port.to_string()
  match self.proxy {
    Some(proxy) =>
      "proxy://" +
      proxy.url.host.to_lower() +
      ":" +
      proxy.url.port.to_string() +
      "|" +
      origin
    None => origin
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
  url_authority_host(url.host) + ":" + url.port.to_string()
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
  match self.connect_impl(url, true) {
    Ok((stream, _)) => Ok(stream)
    Err(err) => Err(err)
  }
}

fn Connector::connect_impl(
  self : Connector,
  url : Url,
  cache_new : Bool,
) -> Result[(&Stream, Bool), HttpError] {
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

  // Validate proxy settings before opening any socket.
  match self.proxy {
    Some(proxy) => {
      if !valid_tcp_host(proxy.url.host) || !valid_tcp_port(proxy.url.port) {
        return Err(InvalidUrl("Invalid proxy address"))
      }
    }
    None => ()
  }

  // Validate TLS settings before opening a socket. The connection host
  // overrides any server name from the shared configuration.
  if scheme == "https" {
    let tls_config = match self.tls_config {
      Some(config) => config.with_server_name(host)
      None => TlsConfig::new(host)
    }
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

  // Check if we have a cached connection
  match take_idle_stream(self.pool, conn_key) {
    Some(stream) => return Ok((stream, true))
    None => ()
  }

  // Dial the proxy when one is configured, otherwise dial the origin.
  let (dial_host, dial_port) = match self.proxy {
    Some(proxy) => (proxy.url.host, proxy.url.port)
    None => (host, port)
  }
  let raw_stream = match self.dialer.dial_tcp(dial_host, dial_port) {
    Ok(stream) => stream
    Err(err) => return Err(NetworkError(err))
  }

  // Bound both plain HTTP I/O and the TLS handshake using the connector timeout.
  match raw_stream.set_timeout(self.timeout_ms) {
    Ok(_) => ()
    Err(err) => {
      let _ = raw_stream.close()
      return Err(NetworkError(err))
    }
  }

  // For HTTPS through a proxy, open a CONNECT tunnel before starting TLS.
  let mut tunnel_leftover : Bytes = b""
  if scheme == "https" {
    match self.proxy {
      Some(proxy) => match establish_tunnel(raw_stream, url, proxy) {
        Ok(leftover) => tunnel_leftover = leftover
        Err(err) => {
          let _ = raw_stream.close()
          return Err(err)
        }
      }
      None => ()
    }
  }

  // If HTTPS, wrap with TLS
  if scheme == "https" {
    // Use the shared configuration when present, otherwise secure defaults.
    let tls_config = match self.tls_config {
      Some(config) => config.with_server_name(host)
      None => TlsConfig::new(host)
    }
    let tls_config = match tls_config.validate() {
      Ok(_) => tls_config
      Err(err) => {
        let _ = raw_stream.close()
        return Err(TlsError(err))
      }
    }

    // A single socket read during CONNECT may have delivered the first bytes
    // of the tunnelled stream; replay them ahead of the socket so the TLS
    // handshake sees the whole record.
    let tls_underlying : &Stream = if tunnel_leftover.length() > 0 {
      let prefix : &Stream = PrefixStream::new(tunnel_leftover, raw_stream)
      prefix
    } else {
      raw_stream
    }

    // Create TLS client context
    let tls_ctx = match self.tls_provider.new_client(tls_config) {
      Ok(ctx) => ctx
      Err(err) => {
        let _ = raw_stream.close()
        return Err(TlsError(err))
      }
    }

    // Perform TLS handshake
    let tls_stream = match tls_ctx.connect(tls_underlying) {
      Ok(stream) => stream
      Err(err) => {
        let _ = raw_stream.close()
        return Err(TlsError(err))
      }
    }

    if cache_new {
      self.pool.val.cache_idle(conn_key, tls_stream, @env.now())
    }
    Ok((tls_stream, false))
  } else {
    // For HTTP, use the raw stream directly
    if cache_new {
      self.pool.val.cache_idle(conn_key, raw_stream, @env.now())
    }
    Ok((raw_stream, false))
  }
}

pub fn Connector::checkout(
  self : Connector,
  url : Url,
) -> Result[(&Stream, ConnectionLease), HttpError] {
  let conn_key = self.connection_key(url)
  let (stream, reused) = match self.connect_impl(url, false) {
    Ok(connection) => connection
    Err(err) => return Err(err)
  }
  let id = self.pool.val.next_id
  self.pool.val.next_id = id + 1
  self.pool.val.active = self.pool.val.active.prepend(
    ActiveConnection::{ id, key: conn_key, stream },
  )
  Ok((
    stream,
    ConnectionLease::{
      id,
      key: conn_key,
      stream,
      reused,
      released: false,
      pool: self.pool,
    },
  ))
}

/// Close a connection and remove from pool
pub fn Connector::close(self : Connector, url : Url) -> Result[Unit, HttpError] {
  let conn_key = self.connection_key(url)

  match self.pool.val.idle.get(conn_key) {
    Some(entries) => {
      for entry in entries {
        let _ = entry.stream.close()
      }
      let _ = self.pool.val.idle.remove(conn_key)
    }
    None => ()
  }
  let key = conn_key
  for entry in self.pool.val.active {
    if entry.key == key {
      let _ = entry.stream.close()
    }
  }
  self.pool.val.active = self.pool.val.active.filter(fn(entry) { entry.key != key })
  Ok(())
}

pub fn Connector::close_all(self : Connector) -> Result[Unit, HttpError] {
  for _conn_key, entries in self.pool.val.idle.iter2() {
    for entry in entries {
      let _ = entry.stream.close()
    }
  }
  for entry in self.pool.val.active {
    let _ = entry.stream.close()
  }
  self.pool.val.idle = Map([])
  self.pool.val.active = @list.List([])
  Ok(())
}
