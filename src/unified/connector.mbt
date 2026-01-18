/// Connector handles the connection establishment logic
pub struct Connector {
  dialer : Dialer
  tls_provider : TlsProvider
  mut connection_pool : Map[String, Stream]
}

pub fn Connector::new(dialer : Dialer, tls_provider : TlsProvider) -> Connector {
  Connector::{
    dialer,
    tls_provider,
    connection_pool: Map::new(),
  }
}

/// Connect to a URL (either HTTP or HTTPS)
pub fn Connector::connect(self : Connector, url : Url) -> Result[Stream, HttpError] {
  let scheme = url.scheme
  let host = url.host
  let port = url.port
  
  // Create a connection key for pooling
  let conn_key = scheme + "://" + host + ":" + port.to_string()
  
  // Check if we have a cached connection
  if self.connection_pool.contains(conn_key) {
    let stream = self.connection_pool.get(conn_key).unwrap()
    return Ok(stream)
  }
  
  // Dial TCP connection
  let raw_stream = self.dialer.dial_tcp(host, port)
  
  if raw_stream.is_err() {
    return Err(NetworkError(raw_stream.unwrap_err()))
  }
  
  let stream = raw_stream.unwrap()
  
  // If HTTPS, wrap with TLS
  if scheme == "https" {
    // Create TLS config
    let tls_config = TlsConfig::new(host)
    
    // Create TLS client context
    let tls_ctx_result = self.tls_provider.new_client(tls_config)
    
    if tls_ctx_result.is_err() {
      stream.close()
      return Err(TlsError(tls_ctx_result.unwrap_err()))
    }
    
    let tls_ctx = tls_ctx_result.unwrap()
    
    // Perform TLS handshake
    let tls_stream_result = tls_ctx.connect(stream)
    
    if tls_stream_result.is_err() {
      return Err(TlsError(tls_stream_result.unwrap_err()))
    }
    
    let tls_stream = tls_stream_result.unwrap()
    
    // Cache the TLS stream
    self.connection_pool.set(conn_key, tls_stream)
    
    Ok(tls_stream)
  } else {
    // For HTTP, use the raw stream directly
    // Cache the connection
    self.connection_pool.set(conn_key, stream)
    
    Ok(stream)
  }
}

/// Close a connection and remove from pool
pub fn Connector::close(self : Connector, url : Url) -> Result[Unit, HttpError] {
  let conn_key = "{url.scheme}://{url.host}:{url.port}"
  
  if self.connection_pool.contains(conn_key) {
    let stream = self.connection_pool.get(conn_key).unwrap()
    stream.close()
    self.connection_pool.remove(conn_key)
    Ok(())
  } else {
    Ok(())
  }
}

/// Close all connections in the pool
pub fn Connector::close_all(self : Connector) -> Result[Unit, HttpError] {
  for conn_key, stream in self.connection_pool.iter() {
    stream.close()
  }
  self.connection_pool = Map::new()
  Ok(())
}
