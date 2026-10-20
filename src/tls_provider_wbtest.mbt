test "MockTlsProvider creation" {
  let provider = MockTlsProvider::new("test")
  assert_eq(provider.name, "test")
}

test "MockTlsProvider new_client" {
  let provider = MockTlsProvider::new("test")
  let config = TlsConfig::new("example.com")
  let result = provider.new_client(config)
  
  assert_true(result is Ok(_))
  let ctx = result.unwrap()
  assert_eq(ctx.server_name(), "example.com")
}

test "MockTlsClientCtx connect" {
  let provider = MockTlsProvider::new("test")
  let config = TlsConfig::new("example.com")
  let ctx_result = provider.new_client(config)
  assert_true(ctx_result is Ok(_))
  
  let ctx = ctx_result.unwrap()
  let stream = TcpStream::new("example.com", 443)
  let open_result = stream.open()
  assert_true(open_result is Ok(_))
  
  let tls_stream_result = ctx.connect(stream)
  assert_true(tls_stream_result is Ok(_))
  
  let tls_stream = tls_stream_result.unwrap()
  let write_result = tls_stream.write(@buffer.new(size_hint=4))
  assert_true(write_result is Ok(_))
  let close_result = tls_stream.close()
  assert_true(close_result is Ok(_))
  assert_true(tls_stream.peer_addr() is Err(_))
}

test "TlsStream operations" {
  let underlying = TcpStream::new("example.com", 443)
  let open_result = underlying.open()
  assert_true(open_result is Ok(_))
  
  let config = TlsConfig::new("example.com")
  let tls_stream = TlsStream::{ underlying, config, is_open: true }
  
  let buf = @buffer.new(size_hint=1024)
  let read_result = tls_stream.read(buf)
  // Should succeed even though it's a mock
  assert_true(read_result is Ok(_) || read_result.unwrap_err() == NetError::Closed)
}
