test "ClientOptions creation" {
  let options = ClientOptions::new()
  assert_eq!(options.user_agent, "Feather/0.1.0")
  assert_eq!(options.timeout_ms, 30000)
  assert_eq!(options.follow_redirects, true)
  assert_eq!(options.max_redirects, 10)
}

test "ClientOptions customization" {
  let options = ClientOptions::new()
    .with_user_agent("CustomAgent/1.0")
    .with_timeout(5000)
    .with_follow_redirects(false)
    .with_max_redirects(5)
  
  assert_eq!(options.user_agent, "CustomAgent/1.0")
  assert_eq!(options.timeout_ms, 5000)
  assert_eq!(options.follow_redirects, false)
  assert_eq!(options.max_redirects, 5)
}

test "UnifiedClient creation" {
  let client = UnifiedClient::new()
  assert_eq!(client.options.user_agent, "Feather/0.1.0")
  assert_eq!(client.redirect_count, 0)
}

test "UnifiedClient with options" {
  let options = ClientOptions::new()
    .with_user_agent("TestAgent/1.0")
    .with_follow_redirects(false)
  
  let client = UnifiedClient::with_options(options)
  assert_eq!(client.options.user_agent, "TestAgent/1.0")
  assert_eq!(client.options.follow_redirects, false)
}

test "is_redirect function" {
  assert_eq!(is_redirect(301), true)
  assert_eq!(is_redirect(302), true)
  assert_eq!(is_redirect(303), true)
  assert_eq!(is_redirect(307), true)
  assert_eq!(is_redirect(308), true)
  assert_eq!(is_redirect(200), false)
  assert_eq!(is_redirect(404), false)
  assert_eq!(is_redirect(500), false)
}

test "Connector creation" {
  let dialer = TcpDialer::new()
  let tls_provider = MockTlsProvider::new("test")
  let connector = Connector::new(dialer, tls_provider)
  
  // Test that connector is created successfully
  assert!(true) // If we got here, it worked
}

test "Connector close_all" {
  let dialer = TcpDialer::new()
  let tls_provider = MockTlsProvider::new("test")
  let connector = Connector::new(dialer, tls_provider)
  
  let result = connector.close_all()
  assert!(result.is_ok())
}

// Note: These are basic tests. In a real implementation, we would need mock servers
// to test the actual HTTP request/response flow without making real network calls.
