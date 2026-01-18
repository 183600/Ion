test "MockTlsProvider creation" {
  let provider = MockTlsProvider::new("test")
  assert_eq!(provider.name, "test")
}

test "MockTlsProvider new_client" {
  let provider = MockTlsProvider::new("test")
  let config = TlsConfig::new("example.com")
  let result = provider.new_client(config)
  
  assert!(result.is_ok())
  let ctx = result.unwrap()
  assert_eq!(ctx.config.server_name, "example.com")
}

test "MockTlsClientCtx connect" {
  let provider = MockTlsProvider::new("test")
  let config = TlsConfig::new("example.com")
  let ctx_result = provider.new_client(config)
  assert!(ctx_result.is_ok())
  
  let ctx = ctx_result.unwrap()
  let stream = TcpStream::new("example.com", 443)
  let open_result = stream.open()
  assert!(open_result.is_ok())
  
  let tls_stream_result = ctx.connect(stream)
  assert!(tls_stream_result.is_ok())
  
  let tls_stream = tls_stream_result.unwrap()
  assert_eq!(tls_stream.is_open, true)
}

test "TlsStream operations" {
  let underlying = TcpStream::new("example.com", 443)
  let open_result = underlying.open()
  assert!(open_result.is_ok())
  
  let config = TlsConfig::new("example.com")
  let tls_stream = TlsStream::{ underlying, config, is_open: true }
  
  let buf = Buffer::make(1024)
  let read_result = tls_stream.read(buf)
  // Should succeed even though it's a mock
  assert!(read_result.is_ok() || read_result.unwrap_err() == Closed)
}
