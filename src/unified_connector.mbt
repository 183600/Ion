struct ActiveConnection {
  id : Int
  key : String
  stream : &Stream
}

struct ConnectionPoolState {
  mut idle : Map[String, List[&Stream]]
  mut active : List[ActiveConnection]
  mut next_id : Int
  mut max_idle : Int
}

fn ConnectionPoolState::new() -> ConnectionPoolState {
  ConnectionPoolState::{
    idle: Map([]),
    active: @list.List([]),
    next_id: 0,
    max_idle: 8,
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
) -> Unit {
  let idle = match self.idle.get(key) {
    Some(streams) => streams
    None => @list.List([])
  }
  let mut updated = idle.prepend(stream)
  while updated.length() > self.max_idle {
    match updated.last() {
      Some(evicted) => {
        let _ = evicted.close()
        updated = updated.take(updated.length() - 1)
      }
      None => break
    }
  }
  self.idle.set(key, updated)
}

/// Connector handles the connection establishment logic
pub struct Connector {
  dialer : &Dialer
  tls_provider : &TlsProvider
  tls_config : TlsConfig?
  timeout_ms : Int
  mut max_connections_per_host : Int
  pool : @ref.Ref[ConnectionPoolState]
}

struct ConnectionLease {
  id : Int
  key : String
  stream : &Stream
  reused : Bool
  pool : @ref.Ref[ConnectionPoolState]
}

fn ConnectionLease::release(self : ConnectionLease, reusable : Bool) -> Unit {
  let id = self.id
  self.pool.val.active = self.pool.val.active.filter(fn(entry) { entry.id != id })
  if reusable {
    match self.stream.peer_addr() {
      Ok(_) => self.pool.val.cache_idle(self.key, self.stream)
      Err(_) => {
        let _ = self.stream.close()
      }
    }
  } else {
    let _ = self.stream.close()
  }
}

fn take_idle_stream(
  pool : @ref.Ref[ConnectionPoolState],
  key : String,
) -> Option[&Stream] {
  let streams = match pool.val.idle.get(key) {
    Some(streams) => streams
    None => return None
  }
  let mut remaining = streams
  while true {
    match remaining.head() {
      Some(stream) => {
        let rest = remaining.unsafe_tail()
        match stream.peer_addr() {
          Ok(_) => {
            if rest.length() == 0 {
              let _ = pool.val.idle.remove(key)
            } else {
              pool.val.idle.set(key, rest)
            }
            return Some(stream)
          }
          Err(_) => {
            let _ = stream.close()
            remaining = rest
          }
        }
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
    timeout_ms: 30000,
    max_connections_per_host: 0,
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
  let _ = self.close_all()
  Connector::{
    dialer: self.dialer,
    tls_provider: self.tls_provider,
    tls_config: Some(config),
    timeout_ms: self.timeout_ms,
    max_connections_per_host: self.max_connections_per_host,
    pool: @ref.Ref(ConnectionPoolState::new()),
  }
}

/// Cap the number of idle (keep-alive) connections retained per host.
/// A value below 1 is clamped to 1. Connections beyond the cap are closed.
pub fn Connector::with_max_idle_per_host(
  self : Connector,
  max_idle : Int,
) -> Connector {
  self.pool.val.max_idle = if max_idle < 1 { 1 } else { max_idle }
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

fn connection_key(url : Url) -> String {
  url.scheme.to_lower() + "://" + url.host.to_lower() + ":" + url.port.to_string()
}

/// Connect to a URL (either HTTP or HTTPS)
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

  let conn_key = connection_key(url)

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

  // Check if we have a cached connection
  match take_idle_stream(self.pool, conn_key) {
    Some(stream) => return Ok((stream, true))
    None => ()
  }

  // Refuse to exceed the per-host connection cap once no idle connection is
  // available. The check is done before dialing so no socket is wasted.
  if self.max_connections_per_host > 0 &&
    self.pool.val.active_count(conn_key) >= self.max_connections_per_host {
    return Err(NetworkError(ConnectionFailed(
      "connection limit reached for " + conn_key,
    )))
  }

  // Dial TCP connection
  let raw_stream = match self.dialer.dial_tcp(host, port) {
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

    // Create TLS client context
    let tls_ctx = match self.tls_provider.new_client(tls_config) {
      Ok(ctx) => ctx
      Err(err) => {
        let _ = raw_stream.close()
        return Err(TlsError(err))
      }
    }

    // Perform TLS handshake
    let tls_stream = match tls_ctx.connect(raw_stream) {
      Ok(stream) => stream
      Err(err) => {
        let _ = raw_stream.close()
        return Err(TlsError(err))
      }
    }

    if cache_new {
      self.pool.val.cache_idle(conn_key, tls_stream)
    }
    Ok((tls_stream, false))
  } else {
    // For HTTP, use the raw stream directly
    if cache_new {
      self.pool.val.cache_idle(conn_key, raw_stream)
    }
    Ok((raw_stream, false))
  }
}

pub fn Connector::checkout(
  self : Connector,
  url : Url,
) -> Result[(&Stream, ConnectionLease), HttpError] {
  let conn_key = connection_key(url)
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
    ConnectionLease::{ id, key: conn_key, stream, reused, pool: self.pool },
  ))
}

/// Close a connection and remove from pool
pub fn Connector::close(self : Connector, url : Url) -> Result[Unit, HttpError] {
  let conn_key = connection_key(url)

  match self.pool.val.idle.get(conn_key) {
    Some(streams) => {
      for stream in streams {
        let _ = stream.close()
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
  for _conn_key, streams in self.pool.val.idle.iter2() {
    for stream in streams {
      let _ = stream.close()
    }
  }
  for entry in self.pool.val.active {
    let _ = entry.stream.close()
  }
  self.pool.val.idle = Map([])
  self.pool.val.active = @list.List([])
  Ok(())
}
