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
  assert_true(!stream.is_open)
  let wire = stream.output.to_bytes()
  assert_true(wire.length() > h2_preface_bytes.length())
  assert_eq(
    @utf8.decode_lossy(wire[: h2_preface_bytes.length()]),
    H2_PREFACE,
  )
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
