/// HTTP proxy configuration.
///
/// Feather supports `http://` and `https://` forward proxies. Plain HTTP
/// requests are sent in absolute-form and HTTPS requests are tunnelled with
/// `CONNECT`. An `https://` proxy is reached over TLS before either form is
/// used, so the proxy connection itself is encrypted too.
pub struct Proxy {
  url : Url
  authorization : String?
} derive(Eq, Debug)

fn proxy_hex_value(byte : Byte) -> Int {
  if byte >= b'0' && byte <= b'9' {
    return byte.to_int() - b'0'.to_int()
  }
  if byte >= b'a' && byte <= b'f' {
    return byte.to_int() - b'a'.to_int() + 10
  }
  if byte >= b'A' && byte <= b'F' {
    return byte.to_int() - b'A'.to_int() + 10
  }
  -1
}

fn proxy_percent_decode_bytes(value : String) -> Bytes {
  let data = @utf8.encode(value)
  let output = Buffer(size_hint=data.length())
  let mut index = 0
  while index < data.length() {
    let byte = data[index]
    if byte == b'%' && index + 2 < data.length() {
      let high = proxy_hex_value(data[index + 1])
      let low = proxy_hex_value(data[index + 2])
      if high >= 0 && low >= 0 {
        output.write_byte(((high << 4) | low).to_byte())
        index = index + 3
        continue
      }
    }
    output.write_byte(byte)
    index = index + 1
  }
  output.to_bytes()
}

fn proxy_userinfo(url : String) -> String? {
  let scheme_end = match url.find("://") {
    Some(index) => index
    None => return None
  }
  let rest = url[scheme_end + 3:].to_owned()
  let authority_end = match find_first_delimiter(rest) {
    Some(index) => index
    None => rest.length()
  }
  let authority = rest[0:authority_end].to_owned()
  match authority.rev_find("@") {
    Some(index) => Some(authority[0:index].to_owned())
    None => None
  }
}

fn proxy_basic_authorization(userinfo : String) -> String {
  let (user, password) = match userinfo.find(":") {
    Some(index) => (
      userinfo[0:index].to_owned(),
      userinfo[index + 1:].to_owned(),
    )
    None => (userinfo, "")
  }
  let credentials = Buffer(size_hint=user.length() + password.length() + 1)
  credentials.write_bytes(proxy_percent_decode_bytes(user))
  credentials.write_byte(b':')
  credentials.write_bytes(proxy_percent_decode_bytes(password))
  @base64.encode(credentials.to_bytes())
}

fn proxy_from_url(url : String, scheme : String) -> Result[Proxy, HttpError] {
  let parsed = match Url::parse(url) {
    Ok(parsed) => parsed
    Err(err) => return Err(err)
  }
  if parsed.scheme.to_lower() != scheme {
    return Err(InvalidUrl("Only " + scheme + " proxies are supported"))
  }
  // `Url` cannot distinguish an absent query/fragment from an empty one, so
  // also reject the raw delimiters. This catches URLs such as
  // `http://proxy.example?` and `http://proxy.example#` that parse to an
  // empty query/fragment but still contain those components.
  if url.contains("?") || url.contains("#") || parsed.path != "/" ||
    parsed.query.length() > 0 || parsed.fragment.length() > 0 {
    return Err(InvalidUrl("Proxy URL must not include a path, query, or fragment"))
  }
  let authorization = match proxy_userinfo(url) {
    Some(userinfo) => Some("Basic " + proxy_basic_authorization(userinfo))
    None => None
  }
  Ok(Proxy::{ url: parsed, authorization })
}

/// Create an HTTP proxy from an `http://`
/// `[user:password@]host[:port]` URL.
pub fn Proxy::new(url : String) -> Result[Proxy, HttpError] {
  proxy_from_url(url, "http")
}

/// Create an HTTPS proxy from an `https://`
/// `[user:password@]host[:port]` URL. The connection to the proxy is
/// protected with TLS before any proxy request is sent.
pub fn Proxy::new_https(url : String) -> Result[Proxy, HttpError] {
  proxy_from_url(url, "https")
}

/// Create a proxy that authenticates with the given credentials.
pub fn Proxy::new_with_basic_auth(
  host : String,
  port : Int,
  username : String,
  password : String,
) -> Result[Proxy, HttpError] {
  let url = Url::new("http", host, port)
  if !valid_tcp_host(url.host) {
    return Err(InvalidUrl("Invalid proxy host"))
  }
  if !valid_tcp_port(url.port) {
    return Err(InvalidUrl("Invalid proxy port"))
  }
  let encoded = @base64.encode(@utf8.encode(username + ":" + password))
  Ok(Proxy::{ url, authorization: Some("Basic " + encoded) })
}

/// Host and port of the proxy server.
pub fn Proxy::authority(self : Proxy) -> String {
  self.url.authority()
}

/// Whether the connection to the proxy itself must use TLS.
pub fn Proxy::is_secure(self : Proxy) -> Bool {
  self.url.scheme.to_lower() == "https"
}

/// Authorization header value for the proxy, if credentials were supplied.
pub fn Proxy::authorization(self : Proxy) -> String? {
  self.authorization
}
