struct H2NegotiatingTlsCtx {
  protocol : String?
}

pub impl TlsClientCtx for H2NegotiatingTlsCtx with fn server_name(
  self : H2NegotiatingTlsCtx,
) -> String {
  let _ = self
  "example.com"
}

pub impl TlsClientCtx for H2NegotiatingTlsCtx with fn negotiated_alpn(
  self : H2NegotiatingTlsCtx,
) -> String? {
  self.protocol
}

pub impl TlsClientCtx for H2NegotiatingTlsCtx with fn connect(
  self : H2NegotiatingTlsCtx,
  underlying : &Stream,
) -> Result[&Stream, TlsError] {
  let _ = self
  Ok(underlying)
}

struct H2NegotiatingTlsProvider {
  protocol : String?
}

pub impl TlsProvider for H2NegotiatingTlsProvider with fn new_client(
  self : H2NegotiatingTlsProvider,
  config : TlsConfig,
) -> Result[&TlsClientCtx, TlsError] {
  let _ = self
  match config.validate() {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  Ok(H2NegotiatingTlsCtx::{ protocol: self.protocol })
}

test "UnifiedClient uses HTTP/2 after ALPN negotiation" {
  let response_headers = hpack_encode([
    (":status", "200"),
    ("content-type", "text/plain"),
    ("x-http2", "yes"),
  ])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM, 1, response_headers),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let provider = H2NegotiatingTlsProvider::{ protocol: Some("h2") }
  let client = UnifiedClient::with_transport(
    dialer,
    provider,
    ClientOptions::new().with_follow_redirects(false),
  )
  let response = client.get("https://example.com/h2").unwrap()
  assert_eq(dialer.count, 1)
  assert_eq(response.version, "HTTP/2")
  assert_eq(response.status, 200)
  assert_eq(response.headers.get("x-http2"), Some("yes"))
  assert_eq(response.read_body().unwrap(), b"")
  // The persistent HTTP/2 session stays open in the pool for the next request.
  assert_true(stream.is_open)
  let wire = stream.output.to_bytes()
  assert_true(wire.length() > h2_preface_bytes.length())
  assert_eq(
    @utf8.decode_lossy(wire[: h2_preface_bytes.length()]),
    H2_PREFACE,
  )
  let _ = client.close_all()
  assert_true(!stream.is_open)
}

test "UnifiedClient reuses one HTTP/2 session for sequential requests" {
  let first = hpack_encode([(":status", "200"), ("x-request", "first")])
  let second = hpack_encode([(":status", "201"), ("x-request", "second")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM, 1, first),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM, 3, second),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let provider = H2NegotiatingTlsProvider::{ protocol: Some("h2") }
  let client = UnifiedClient::with_transport(
    dialer,
    provider,
    ClientOptions::new().with_follow_redirects(false),
  )
  let first_response = client.get("https://example.com/first").unwrap()
  let second_response = client.get("https://example.com/second").unwrap()
  assert_eq(dialer.count, 1)
  assert_eq(first_response.status, 200)
  assert_eq(first_response.headers.get("x-request"), Some("first"))
  assert_eq(second_response.status, 201)
  assert_eq(second_response.headers.get("x-request"), Some("second"))

  let wire = stream.output.to_bytes()
  let mut preface_count = 0
  let mut index = 0
  while index + h2_preface_bytes.length() <= wire.length() {
    if wire.exact_view(start=index, end=index + h2_preface_bytes.length()) ==
      h2_preface_bytes.exact_view(start=0, end=h2_preface_bytes.length()) {
      preface_count = preface_count + 1
    }
    index = index + 1
  }
  assert_eq(preface_count, 1)
  let _ = client.close_all()
  assert_true(!stream.is_open)
}

test "UnifiedClient applies its response body limit to HTTP/2" {
  let response_headers = hpack_encode([(":status", "200")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, response_headers),
    h2_test_frame(H2_FRAME_DATA, H2_FLAG_END_STREAM, 1, @utf8.encode("hello")),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let provider = H2NegotiatingTlsProvider::{ protocol: Some("h2") }
  let client = UnifiedClient::with_transport(
    dialer,
    provider,
    ClientOptions::new()
      .with_follow_redirects(false)
      .with_max_response_body_bytes(4),
  )
  match client.get("https://example.com/h2") {
    Ok(_) => fail("HTTP/2 response body limit was not applied")
    Err(err) => assert_eq(err, ProtocolError("HTTP/2 response body too large"))
  }
  assert_true(!stream.is_open)

  let accepted = h2_frame_mock_stream(input, 0)
  let accepted_dialer = RegressionMockDialer::{ stream: accepted, count: 0 }
  let accepted_provider = H2NegotiatingTlsProvider::{ protocol: Some("h2") }
  let accepted_client = UnifiedClient::with_transport(
    accepted_dialer,
    accepted_provider,
    ClientOptions::new()
      .with_follow_redirects(false)
      .with_max_response_body_bytes(5),
  )
  let response = accepted_client.get("https://example.com/h2").unwrap()
  assert_eq(response.read_body().unwrap(), @utf8.encode("hello"))
}

test "UnifiedClient rejects an unsupported negotiated ALPN protocol" {
  let stream = h2_frame_mock_stream(b"", 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let provider = H2NegotiatingTlsProvider::{ protocol: Some("spdy/3.1") }
  let client = UnifiedClient::with_transport(
    dialer,
    provider,
    ClientOptions::new().with_follow_redirects(false),
  )
  assert_true(client.get("https://example.com/") is Err(ProtocolError(_)))
  assert_true(!stream.is_open)
}

test "connector advertises HTTP/2 in default TLS ALPN when enabled" {
  let stream = regression_mock_stream("", 0, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let provider = ConfigCapturingTlsProvider::{ last_config: None }
  let connector = Connector::new(dialer, provider).with_http2(true)
  let _ = connector.connect(Url::new("https", "example.com", 443)).unwrap()
  match provider.last_config {
    Some(config) => {
      assert_eq(config.server_name, "example.com")
      assert_eq(config.alpn.to_array(), ["h2", "http/1.1"])
    }
    None => abort("TLS config was not captured")
  }
}

struct H2SequenceDialer {
  streams : Array[&Stream]
  mut index : Int
  mut count : Int
}

pub impl Dialer for H2SequenceDialer with fn dial_tcp(
  self : H2SequenceDialer,
  host : String,
  port : Int,
) -> Result[&Stream, NetError] {
  let _ = host
  let _ = port
  self.count = self.count + 1
  if self.index >= self.streams.length() {
    return Err(NetError::ConnectionFailed("no mock stream left"))
  }
  let stream = self.streams[self.index]
  self.index = self.index + 1
  Ok(stream)
}

pub impl Dialer for H2SequenceDialer with fn resolve(self : H2SequenceDialer, host : String) -> Result[List[String], NetError] {
  let _ = self
  Ok(@list.List([host]))
}

test "UnifiedClient retries a stale pooled HTTP/2 session once" {
  let response_headers = hpack_encode([(":status", "200"), ("x-retry", "yes")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM, 1, response_headers),
  ])
  let stale = h2_frame_mock_stream(b"", 0)
  let fresh = h2_frame_mock_stream(input, 0)
  let stale_stream : &Stream = stale
  let fresh_stream : &Stream = fresh
  let dialer = H2SequenceDialer::{
    streams: [fresh_stream],
    index: 0,
    count: 0,
  }
  let provider = H2NegotiatingTlsProvider::{ protocol: Some("h2") }
  let connector = Connector::new(dialer, provider).with_http2(true)
  let url = Url::parse("https://example.com/stale").unwrap()
  let stale_connection = H2ClientConnection::new(stale_stream).unwrap()
  connector.pool.val.cache_idle_h2(
    connector.connection_key(url),
    stale_connection,
    0,
  )
  let client = UnifiedClient::{
    connector,
    options: ClientOptions::new().with_follow_redirects(false),
    redirect_count: 0,
  }
  let response = client.get("https://example.com/stale").unwrap()
  assert_eq(dialer.count, 1)
  assert_eq(response.status, 200)
  assert_eq(response.headers.get("x-retry"), Some("yes"))
  assert_true(!stale.is_open)
  assert_true(fresh.is_open)
  let _ = client.close_all()
}

test "changing the HTTP/2 policy closes connections negotiated under the old policy" {
  let stream = regression_mock_stream("", 1, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  let url = Url::parse("http://example.com/").unwrap()
  let _ = connector.connect(url).unwrap()
  assert_true(stream.is_open)
  let enabled = connector.with_http2(true)
  assert_true(enabled.http2_enabled())
  assert_false(stream.is_open)
  // Setting the same value again is a no-op for the current pool.
  let again = enabled.with_http2(true)
  assert_true(again.http2_enabled())
}

test "connection keys distinguish IPvFuture literals from DNS names" {
  let connector = Connector::new(TcpDialer::new(), MockTlsProvider::new("test"))
  let dns = Url::parse("https://v1.foo/").unwrap()
  let literal = Url::parse("https://[v1.foo]/").unwrap()
  assert_true(connector.connection_key(dns) != connector.connection_key(literal))
}

test "local HTTP/2 request errors preserve the pooled session" {
  let first = hpack_encode([(":status", "200"), ("x-request", "first")])
  let second = hpack_encode([(":status", "201"), ("x-request", "second")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM, 1, first),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM, 3, second),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let provider = H2NegotiatingTlsProvider::{ protocol: Some("h2") }
  let client = UnifiedClient::with_transport(
    dialer,
    provider,
    ClientOptions::new().with_follow_redirects(false),
  )
  let url = "https://example.com/path"
  let first_response = client.get(url).unwrap()
  assert_eq(first_response.status, 200)

  let invalid = Request::new(POST, Url::parse(url).unwrap())
    .with_header("Content-Length", "1")
  match client.request(invalid) {
    Ok(_) => fail("invalid HTTP/2 request was accepted")
    Err(err) => assert_eq(err, InvalidHeader("Content-Length"))
  }
  assert_eq(dialer.count, 1)
  assert_true(stream.is_open)

  let second_response = client.get(url).unwrap()
  assert_eq(second_response.status, 201)
  assert_eq(second_response.headers.get("x-request"), Some("second"))
  assert_eq(dialer.count, 1)
  let _ = client.close_all()
}

test "UnifiedClient retries a request refused on a fresh HTTP/2 connection" {
  let refused_input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_RST_STREAM, 0, 1, b"\x00\x00\x00\x07"),
  ])
  let response_headers = hpack_encode([(":status", "200"), ("x-retry", "refused")])
  let fresh_input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM, 1, response_headers),
  ])
  let refused = h2_frame_mock_stream(refused_input, 0)
  let fresh = h2_frame_mock_stream(fresh_input, 0)
  let refused_stream : &Stream = refused
  let fresh_stream : &Stream = fresh
  let dialer = H2SequenceDialer::{
    streams: [refused_stream, fresh_stream],
    index: 0,
    count: 0,
  }
  let provider = H2NegotiatingTlsProvider::{ protocol: Some("h2") }
  let connector = Connector::new(dialer, provider).with_http2(true)
  let client = UnifiedClient::{
    connector,
    options: ClientOptions::new().with_follow_redirects(false),
    redirect_count: 0,
  }
  let response = client.get("https://example.com/refused").unwrap()
  assert_eq(dialer.count, 2)
  assert_eq(response.status, 200)
  assert_eq(response.headers.get("x-retry"), Some("refused"))
  assert_false(refused.is_open)
  let _ = client.close_all()
}

test "UnifiedClient retries a refused POST because no bytes were processed" {
  let refused_input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_RST_STREAM, 0, 1, b"\x00\x00\x00\x07"),
  ])
  let response_headers = hpack_encode([(":status", "200"), ("x-retry", "post")])
  let fresh_input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM, 1, response_headers),
  ])
  let refused = h2_frame_mock_stream(refused_input, 0)
  let fresh = h2_frame_mock_stream(fresh_input, 0)
  let refused_stream : &Stream = refused
  let fresh_stream : &Stream = fresh
  let dialer = H2SequenceDialer::{
    streams: [refused_stream, fresh_stream],
    index: 0,
    count: 0,
  }
  let provider = H2NegotiatingTlsProvider::{ protocol: Some("h2") }
  let connector = Connector::new(dialer, provider).with_http2(true)
  let client = UnifiedClient::{
    connector,
    options: ClientOptions::new().with_follow_redirects(false),
    redirect_count: 0,
  }
  let response = client.post("https://example.com/refused", b"").unwrap()
  assert_eq(dialer.count, 2)
  assert_eq(response.status, 200)
  assert_eq(response.headers.get("x-retry"), Some("post"))
  assert_false(refused.is_open)
  let _ = client.close_all()
}

test "UnifiedClient retries a POST the server excluded with GOAWAY" {
  let goaway_input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_GOAWAY, 0, 0, b"\x00\x00\x00\x00\x00\x00\x00\x00"),
  ])
  let response_headers = hpack_encode([(":status", "200"), ("x-retry", "goaway")])
  let fresh_input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM, 1, response_headers),
  ])
  let first = h2_frame_mock_stream(goaway_input, 0)
  let fresh = h2_frame_mock_stream(fresh_input, 0)
  let first_stream : &Stream = first
  let fresh_stream : &Stream = fresh
  let dialer = H2SequenceDialer::{
    streams: [first_stream, fresh_stream],
    index: 0,
    count: 0,
  }
  let provider = H2NegotiatingTlsProvider::{ protocol: Some("h2") }
  let connector = Connector::new(dialer, provider).with_http2(true)
  let client = UnifiedClient::{
    connector,
    options: ClientOptions::new().with_follow_redirects(false),
    redirect_count: 0,
  }
  let response = client.post("https://example.com/goaway", b"payload").unwrap()
  assert_eq(dialer.count, 2)
  assert_eq(response.status, 200)
  assert_eq(response.headers.get("x-retry"), Some("goaway"))
  assert_false(first.is_open)
  let _ = client.close_all()
}

///|
test "UnifiedClient retries a POST after a pre-stream GOAWAY error" {
  let goaway_input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_GOAWAY, 0, 0, b"\x00\x00\x00\x00\x00\x00\x00\x01"),
  ])
  let response_headers = hpack_encode([(":status", "200"), ("x-retry", "error")])
  let fresh_input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM, 1, response_headers),
  ])
  let first = h2_frame_mock_stream(goaway_input, 0)
  let fresh = h2_frame_mock_stream(fresh_input, 0)
  let first_stream : &Stream = first
  let fresh_stream : &Stream = fresh
  let dialer = H2SequenceDialer::{
    streams: [first_stream, fresh_stream],
    index: 0,
    count: 0,
  }
  let provider = H2NegotiatingTlsProvider::{ protocol: Some("h2") }
  let connector = Connector::new(dialer, provider).with_http2(true)
  let client = UnifiedClient::{
    connector,
    options: ClientOptions::new().with_follow_redirects(false),
    redirect_count: 0,
  }
  let response = client.post("https://example.com/goaway", b"payload").unwrap()
  assert_eq(dialer.count, 2)
  assert_eq(response.status, 200)
  assert_eq(response.headers.get("x-retry"), Some("error"))
  assert_false(first.is_open)
  let _ = client.close_all()
}

///|
test "HTTP/2 response bodies become closed streams after close" {
  let response_headers = hpack_encode([(":status", "200")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, 1, response_headers),
    h2_test_frame(H2_FRAME_DATA, H2_FLAG_END_STREAM, 1, @utf8.encode("hello")),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let provider = H2NegotiatingTlsProvider::{ protocol: Some("h2") }
  let client = UnifiedClient::with_transport(
    dialer,
    provider,
    ClientOptions::new().with_follow_redirects(false),
  )
  let response = client.get("https://example.com/closed-body").unwrap()
  assert_true(response.body.close() is Ok(_))
  assert_true(response.body.read(Buffer()) is Err(Closed))
  assert_true(response.body.write(Buffer()) is Err(Closed))
  assert_true(response.body.flush() is Err(Closed))
  assert_true(response.body.set_timeout(1000) is Err(Closed))
  assert_true(response.body.peer_addr() is Err(Closed))
  assert_true(response.body.local_addr() is Err(Closed))
  let _ = client.close_all()
}

///|
test "cleartext HTTP/2 prior knowledge sends the client preface" {
  let response_headers = hpack_encode([(":status", "200"), ("x-h2c", "yes")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM, 1, response_headers),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let provider = H2NegotiatingTlsProvider::{ protocol: None }
  let client = UnifiedClient::with_transport(
    dialer,
    provider,
    ClientOptions::new().with_follow_redirects(false),
  ).with_http2_prior_knowledge(true)
  let response = client.get("http://example.com/h2c").unwrap()
  assert_eq(dialer.count, 1)
  assert_eq(response.version, "HTTP/2")
  assert_eq(response.status, 200)
  assert_eq(response.headers.get("x-h2c"), Some("yes"))
  assert_eq(response.read_body().unwrap(), b"")
  let wire = stream.output.to_bytes()
  assert_true(wire.length() > h2_preface_bytes.length())
  assert_eq(
    @utf8.decode_lossy(wire[: h2_preface_bytes.length()]),
    H2_PREFACE,
  )
  let _ = client.close_all()
  assert_true(!stream.is_open)
}

///|
test "cleartext HTTP/2 prior knowledge reuses one session" {
  let first = hpack_encode([(":status", "200"), ("x-request", "first")])
  let second = hpack_encode([(":status", "201"), ("x-request", "second")])
  let input = h2_test_concat([
    h2_test_settings(),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM, 1, first),
    h2_test_frame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS | H2_FLAG_END_STREAM, 3, second),
  ])
  let stream = h2_frame_mock_stream(input, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let provider = H2NegotiatingTlsProvider::{ protocol: None }
  let client = UnifiedClient::with_transport(
    dialer,
    provider,
    ClientOptions::new().with_follow_redirects(false),
  ).with_http2_prior_knowledge(true)
  let first_response = client.get("http://example.com/first").unwrap()
  let second_response = client.get("http://example.com/second").unwrap()
  assert_eq(dialer.count, 1)
  assert_eq(first_response.headers.get("x-request"), Some("first"))
  assert_eq(second_response.headers.get("x-request"), Some("second"))
  assert_eq(second_response.status, 201)

  let wire = stream.output.to_bytes()
  let mut preface_count = 0
  let mut index = 0
  while index + h2_preface_bytes.length() <= wire.length() {
    if wire.exact_view(start=index, end=index + h2_preface_bytes.length()) ==
      h2_preface_bytes.exact_view(start=0, end=h2_preface_bytes.length()) {
      preface_count = preface_count + 1
    }
    index = index + 1
  }
  assert_eq(preface_count, 1)
  let _ = client.close_all()
  assert_true(!stream.is_open)
}

///|
test "disabling HTTP/2 also disables cleartext prior knowledge" {
  let stream = regression_mock_stream("", 0, 0)
  let dialer = RegressionMockDialer::{ stream, count: 0 }
  let connector = Connector::new(dialer, MockTlsProvider::new("test"))
  assert_false(connector.http2_prior_knowledge())
  let enabled = connector.with_http2_prior_knowledge(true)
  assert_true(enabled.http2_enabled())
  assert_true(enabled.http2_prior_knowledge())
  let disabled = enabled.with_http2(false)
  assert_false(disabled.http2_enabled())
  assert_false(disabled.http2_prior_knowledge())
}
