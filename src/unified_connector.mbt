/// Connector handles the connection establishment logic
pub struct Connector {
  dialer : &Dialer
  tls_provider : &TlsProvider
  mut connection_pool : Map[String, &Stream]
}

pub fn Connector::new(dialer : &Dialer, tls_provider : &TlsProvider) -> Connector {
  Connector::{
    dialer,
    tls_provider,
    connection_pool: Map::new(),
  }
}

/// Connect to a URL (either HTTP or HTTPS)
pub fn Connector::connect(self : Connector, url : Url) -> Result[&Stream, HttpError] {
  let scheme = url.scheme
  let host = url.host
  let port = url.port

  // Create a connection key for pooling
  let conn_key = scheme + "://" + host + ":" + port.to_string()

  // Check if we have a cached connection
  match self.connection_pool.get(conn_key) {
    Some(stream) => return Ok(stream)
    None => ()
  }

  // Dial TCP connection
  let raw_stream = match self.dialer.dial_tcp(host, port) {
    Ok(stream) => stream
    Err(err) => return Err(NetworkError(err))
  }

  // If HTTPS, wrap with TLS
  if scheme == "https" {
    // Create TLS config
    let tls_config = TlsConfig::new(host)

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
  let conn_key = url.scheme + "://" + url.host + ":" + url.port.to_string()

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
  self.connection_pool = Map::new()
  Ok(())
}
