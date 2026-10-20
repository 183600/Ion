/// Connector handles the connection establishment logic
pub struct Connector {
  dialer : &Dialer
  tls_provider : &TlsProvider
  tls_config : TlsConfig?
  timeout_ms : Int
  mut connection_pool : Map[String, &Stream]
}

pub fn Connector::new(dialer : &Dialer, tls_provider : &TlsProvider) -> Connector {
  Connector::{
    dialer,
    tls_provider,
    tls_config: None,
    timeout_ms: 30000,
    connection_pool: Map([]),
  }
}

/// Set the timeout applied to newly dialed connections and TLS handshakes.
pub fn Connector::with_timeout(self : Connector, timeout_ms : Int) -> Connector {
  let timeout_ms = if timeout_ms < 0 { 0 } else { timeout_ms }
  Connector::{ ..self, timeout_ms }
}

/// Use a shared TLS configuration for every HTTPS connection.
pub fn Connector::with_tls_config(self : Connector, config : TlsConfig) -> Connector {
  Connector::{ ..self, tls_config: Some(config) }
}

fn connection_key(url : Url) -> String {
  url.scheme.to_lower() + "://" + url.host.to_lower() + ":" + url.port.to_string()
}

/// Connect to a URL (either HTTP or HTTPS)
pub fn Connector::connect(self : Connector, url : Url) -> Result[&Stream, HttpError] {
  let scheme = url.scheme.to_lower()
  let host = url.host
  let port = url.port
  if scheme != "http" && scheme != "https" {
    return Err(InvalidUrl("Only http and https schemes supported"))
  }
  if host.length() == 0 {
    return Err(InvalidUrl("URL has no host"))
  }
  if port < 1 || port > 65535 {
    return Err(InvalidUrl("Invalid port number"))
  }

  let conn_key = connection_key(url)

  // Check if we have a cached connection
  match self.connection_pool.get(conn_key) {
    Some(stream) => match stream.peer_addr() {
      Ok(_) => return Ok(stream)
      Err(_) => {
        let _ = stream.close()
        self.connection_pool.remove(conn_key)
      }
    }
    None => ()
  }

  // Dial TCP connection
  let raw_stream = match self.dialer.dial_tcp(host, port) {
    Ok(stream) => stream
    Err(err) => return Err(NetworkError(err))
  }

  // If HTTPS, wrap with TLS
  if scheme == "https" {
    // Bound the TLS handshake using the same deadline as the connection.
    match raw_stream.set_timeout(self.timeout_ms) {
      Ok(_) => ()
      Err(err) => {
        let _ = raw_stream.close()
        return Err(NetworkError(err))
      }
    }
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

    // Cache the TLS stream
    self.connection_pool.set(conn_key, tls_stream)

    Ok(tls_stream)
  } else {
    // For HTTP, use the raw stream directly
    // Cache the connection
    self.connection_pool.set(conn_key, raw_stream)

    Ok(raw_stream)
  }
}

/// Close a connection and remove from pool
pub fn Connector::close(self : Connector, url : Url) -> Result[Unit, HttpError] {
  let conn_key = connection_key(url)

  match self.connection_pool.get(conn_key) {
    Some(stream) => {
      let _ = stream.close()
      self.connection_pool.remove(conn_key)
      Ok(())
    }
    None => Ok(())
  }
}

/// Close all connections in the pool
pub fn Connector::close_all(self : Connector) -> Result[Unit, HttpError] {
  for _conn_key, stream in self.connection_pool.iter2() {
    let _ = stream.close()
  }
  self.connection_pool = Map([])
  Ok(())
}
