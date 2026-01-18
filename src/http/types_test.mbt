test "HttpMethod to_string" {
  assert_eq!(GET.to_string(), "GET")
  assert_eq!(POST.to_string(), "POST")
  assert_eq!(PUT.to_string(), "PUT")
  assert_eq!(DELETE.to_string(), "DELETE")
  assert_eq!(HEAD.to_string(), "HEAD")
  assert_eq!(OPTIONS.to_string(), "OPTIONS")
  assert_eq!(PATCH.to_string(), "PATCH")
}

test "Header creation" {
  let header = Header::new("Content-Type", "application/json")
  assert_eq!(header.name, "Content-Type")
  assert_eq!(header.value, "application/json")
}

test "Headers operations" {
  let headers = Headers::new()
  let headers_with_content = headers.add("Content-Type", "application/json")
  let headers_with_both = headers_with_content.add("User-Agent", "Feather/0.1.0")
  
  let content_type = headers_with_both.get("Content-Type")
  assert!(content_type.is_some())
  assert_eq!(content_type.unwrap(), "application/json")
  
  let user_agent = headers_with_both.get("User-Agent")
  assert!(user_agent.is_some())
  assert_eq!(user_agent.unwrap(), "Feather/0.1.0")
  
  let missing = headers_with_both.get("Missing")
  assert!(missing.is_none())
}

test "Url parse http" {
  let url_str = "http://example.com:8080/path?query=1"
  let result = Url::parse(url_str)
  
  assert!(result.is_ok())
  let url = result.unwrap()
  assert_eq!(url.scheme, "http")
  assert_eq!(url.host, "example.com")
  assert_eq!(url.port, 8080)
  assert_eq!(url.path, "/path")
}

test "Url parse https default port" {
  let url_str = "https://example.com"
  let result = Url::parse(url_str)
  
  assert!(result.is_ok())
  let url = result.unwrap()
  assert_eq!(url.scheme, "https")
  assert_eq!(url.host, "example.com")
  assert_eq!(url.port, 443)
  assert_eq!(url.path, "/")
}

test "Url parse invalid" {
  let result = Url::parse("")
  assert!(result.is_err())
  
  let result2 = Url::parse("ftp://example.com")
  assert!(result2.is_err())
}

test "Request creation" {
  let url = Url::new("https", "example.com", 443)
  let request = Request::new(GET, url)
  
  assert_eq!(request.method, GET)
  assert_eq!(request.url.scheme, "https")
  assert_eq!(request.timeout_ms, 30000)
  assert!(request.body.is_none())
}

test "Request with header and body" {
  let url = Url::new("https", "example.com", 443)
  let body = Bytes::from_string("test data")
  let request = Request::new(POST, url)
    .with_header("Content-Type", "application/json")
    .with_body(body)
    .with_timeout(5000)
  
  assert_eq!(request.method, POST)
  assert_eq!(request.timeout_ms, 5000)
  assert!(request.body.is_some())
  
  let content_type = request.get_header("Content-Type")
  assert!(content_type.is_some())
  assert_eq!(content_type.unwrap(), "application/json")
}

test "Response creation" {
  let url = Url::new("https", "example.com", 443)
  let stream = TcpStream::new(url.host, url.port)
  let open_result = stream.open()
  assert!(open_result.is_ok())
  
  let headers = Headers::new()
  let response = Response::new(200, headers, stream)
  
  assert_eq!(response.status, 200)
}
