/// Proxy configuration.
///
/// Feather supports `http://` and `https://` forward proxies as well as
/// `socks5://` / `socks5h://` tunnels. Plain HTTP requests are sent in
/// absolute-form through a forward proxy and HTTPS requests are tunnelled with
/// `CONNECT`. An `https://` proxy is reached over TLS before either form is
/// used, so the proxy connection itself is encrypted too. SOCKS5 proxies carry
/// both HTTP and HTTPS through a tunnel and resolve the target host themselves.
pub struct Proxy {
  url : Url
  authorization : String?
  // SOCKS5 username/password authentication is a byte-oriented sub-negotiation
  // and is not an HTTP Authorization header, so it is kept separately.
  socks_username : Bytes?
  socks_password : Bytes?
} derive(Eq, Debug)

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

fn proxy_basic_authorization(userinfo : String) -> Result[String, HttpError] {
  let (user, password) = match userinfo.find(":") {
    Some(index) => (
      userinfo[0:index].to_owned(),
      userinfo[index + 1:].to_owned(),
    )
    None => (userinfo, "")
  }
  let user = percent_decode_bytes(user)
  // Basic authentication splits decoded credentials at the first colon, so a
  // colon in the user-id would silently authenticate a different account.
  if bytes_contain_byte(user, b':') {
    return Err(InvalidUrl("Invalid username in proxy credentials"))
  }
  let credentials = Buffer(size_hint=user.length() + password.length() + 1)
  credentials.write_bytes(user)
  credentials.write_byte(b':')
  credentials.write_bytes(percent_decode_bytes(password))
  Ok(@base64.encode(credentials.to_bytes()))
}

fn proxy_socks5_credentials(userinfo : String) -> Result[(Bytes, Bytes), HttpError] {
  let (user, password) = match userinfo.find(":") {
    Some(index) => (
      userinfo[0:index].to_owned(),
      userinfo[index + 1:].to_owned(),
    )
    None => (userinfo, "")
  }
  let username = percent_decode_bytes(user)
  let password = percent_decode_bytes(password)
  match socks5_credentials_valid(username, password) {
    Ok(_) => Ok((username, password))
    Err(err) => Err(err)
  }
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
    Some(userinfo) =>
      if userinfo.length() > 0 {
        let encoded = match proxy_basic_authorization(userinfo) {
          Ok(value) => value
          Err(err) => return Err(err)
        }
        Some("Basic " + encoded)
      } else {
        None
      }
    None => None
  }
  Ok(Proxy::{
    url: parsed,
    authorization,
    socks_username: None,
    socks_password: None,
  })
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

/// Create a SOCKS5 proxy from a `socks5://` or `socks5h://`
/// `[user:password@]host[:port]` URL. The default port is 1080. `socks5h`
/// sends the target host name so DNS resolution happens on the proxy side;
/// plain `socks5` resolves locally and sends the resulting address.
pub fn Proxy::new_socks5(url : String) -> Result[Proxy, HttpError] {
  let scheme_end = match url.find("://") {
    Some(index) => index
    None => return Err(InvalidUrl("Invalid proxy URL"))
  }
  let scheme = url[0:scheme_end].to_owned().to_lower()
  if scheme != "socks5" && scheme != "socks5h" {
    return Err(InvalidUrl("Only socks5 and socks5h proxies are supported"))
  }
  let rest = url[scheme_end + 3:].to_owned()
  // Parse the authority with the regular HTTP URL parser so host, port and
  // userinfo validation stays in one place, then replace the scheme and apply
  // the SOCKS default port when the URL did not spell one out.
  let parsed = match Url::parse("http://" + rest) {
    Ok(parsed) => parsed
    Err(err) => return Err(err)
  }
  if rest.contains("?") || rest.contains("#") || parsed.path != "/" ||
    parsed.query.length() > 0 || parsed.fragment.length() > 0 {
    return Err(InvalidUrl("Proxy URL must not include a path, query, or fragment"))
  }
  let authority_end = match find_first_delimiter(rest) {
    Some(index) => index
    None => rest.length()
  }
  let authority = rest[0:authority_end].to_owned()
  let host_port = match authority.rev_find("@") {
    Some(index) => authority[index + 1:].to_owned()
    None => authority
  }
  let port_text : String? = if host_port.has_prefix("[") {
    match host_port.find("]") {
      Some(index) =>
        if index + 1 < host_port.length() &&
          host_port.get_char(index + 1) == Some(':') {
          Some(host_port[index + 2:].to_owned())
        } else {
          None
        }
      None => None
    }
  } else {
    match host_port.find(":") {
      Some(index) => Some(host_port[index + 1:].to_owned())
      None => None
    }
  }
  // An explicit empty port means the scheme default, as in RFC 3986, so only
  // a non-empty port overrides SOCKS5's 1080.
  let port = match port_text {
    Some(text) => if text.length() > 0 { parsed.port } else { 1080 }
    None => 1080
  }
  let (socks_username, socks_password) = match proxy_userinfo(url) {
    Some(userinfo) =>
      if userinfo.length() == 0 {
        (None, None)
      } else {
        match proxy_socks5_credentials(userinfo) {
          Ok(credentials) => (Some(credentials.0), Some(credentials.1))
          Err(err) => return Err(err)
        }
      }
    None => (None, None)
  }
  Ok(Proxy::{
    url: Url::{ ..parsed, scheme, port },
    authorization: None,
    socks_username,
    socks_password,
  })
}

/// Create a SOCKS5 proxy with username/password authentication.
pub fn Proxy::new_socks5_with_auth(
  host : String,
  port : Int,
  username : String,
  password : String,
) -> Result[Proxy, HttpError] {
  let url = Url::new("socks5", host, port)
  if !valid_tcp_host(url.host) {
    return Err(InvalidUrl("Invalid proxy host"))
  }
  if !valid_tcp_port(url.port) {
    return Err(InvalidUrl("Invalid proxy port"))
  }
  let username = @utf8.encode(username)
  let password = @utf8.encode(password)
  match socks5_credentials_valid(username, password) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  Ok(Proxy::{
    url,
    authorization: None,
    socks_username: Some(username),
    socks_password: Some(password),
  })
}

/// Parse a proxy URL, accepting the schemes Feather can route through. A bare
/// `host:port` value selects an HTTP proxy, matching the convention used by
/// the standard proxy environment variables.
pub fn Proxy::parse(url : String) -> Result[Proxy, HttpError] {
  let url = url.trim().to_owned()
  let lower = url.to_lower()
  if lower.has_prefix("socks5://") || lower.has_prefix("socks5h://") {
    Proxy::new_socks5(url)
  } else if lower.has_prefix("https://") {
    Proxy::new_https(url)
  } else if lower.has_prefix("http://") {
    Proxy::new(url)
  } else if lower.contains("://") {
    Proxy::new(url)
  } else {
    Proxy::new("http://" + url)
  }
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
  if bytes_contain_byte(@utf8.encode(username), b':') {
    return Err(InvalidUrl("Invalid username in proxy credentials"))
  }
  let encoded = @base64.encode(@utf8.encode(username + ":" + password))
  Ok(Proxy::{
    url,
    authorization: Some("Basic " + encoded),
    socks_username: None,
    socks_password: None,
  })
}

/// Host and port of the proxy server.
pub fn Proxy::authority(self : Proxy) -> String {
  self.url.authority()
}

/// Whether the connection to the proxy itself must use TLS.
pub fn Proxy::is_secure(self : Proxy) -> Bool {
  self.url.scheme.to_lower() == "https"
}

/// Whether this proxy is a SOCKS5 tunnel.
pub fn Proxy::is_socks5(self : Proxy) -> Bool {
  let scheme = self.url.scheme.to_lower()
  scheme == "socks5" || scheme == "socks5h"
}

/// Whether this is a SOCKS5 proxy that resolves destination names on the proxy
/// side (`socks5h`). Plain `socks5` resolves names locally and sends an
/// address, matching the convention used by curl and other clients.
pub fn Proxy::is_socks5h(self : Proxy) -> Bool {
  self.url.scheme.to_lower() == "socks5h"
}

/// SOCKS5 username/password credentials, if configured.
pub fn Proxy::socks_credentials(self : Proxy) -> (Bytes, Bytes)? {
  match (self.socks_username, self.socks_password) {
    (Some(username), Some(password)) => Some((username, password))
    _ => None
  }
}

/// Authorization header value for the proxy, if credentials were supplied.
pub fn Proxy::authorization(self : Proxy) -> String? {
  self.authorization
}

fn proxy_env_value(
  names : Array[String],
  lookup : (String) -> String?,
) -> String? {
  for name in names {
    match lookup(name) {
      Some(value) =>
        if value.trim().length() > 0 {
          return Some(value.trim().to_owned())
        }
      None => ()
    }
  }
  None
}

/// Parse a proxy URL from an environment variable. A bare `host:port` value is
/// treated as an HTTP proxy, matching the convention used by common HTTP
/// clients and tools. SOCKS5 URLs are only accepted from `ALL_PROXY`, the
/// conventional fallback variable for every protocol; `HTTPS_PROXY` and
/// `http_proxy` stay limited to HTTP(S) proxies so their meaning cannot
/// change silently.
fn proxy_from_env_url(value : String, allow_socks : Bool) -> Result[Proxy, HttpError] {
  let lower = value.to_lower()
  if lower.has_prefix("socks5://") || lower.has_prefix("socks5h://") {
    if allow_socks {
      Proxy::new_socks5(value)
    } else {
      Err(InvalidUrl("SOCKS5 proxy URLs are only supported in ALL_PROXY"))
    }
  } else if lower.has_prefix("https://") {
    Proxy::new_https(value)
  } else if lower.contains("://") {
    Proxy::new(value)
  } else {
    Proxy::new("http://" + value)
  }
}

fn proxy_from_env_lookup(
  url : Url,
  lookup : (String) -> String?,
) -> Result[Proxy?, HttpError] {
  let mut candidate : String? = None
  let mut allow_socks = false
  if url.is_secure() {
    candidate = proxy_env_value(["HTTPS_PROXY", "https_proxy"], lookup)
  } else {
    candidate = proxy_env_value(["http_proxy"], lookup)
    // CGI variables are attacker-controlled and must not select the proxy.
    // Uppercase HTTP_PROXY is therefore only honoured outside a CGI
    // environment, matching the convention used by curl.
    if candidate is None && lookup("REQUEST_METHOD") is None {
      candidate = proxy_env_value(["HTTP_PROXY"], lookup)
    }
  }
  if candidate is None {
    candidate = proxy_env_value(["ALL_PROXY", "all_proxy"], lookup)
    if candidate is Some(_) {
      allow_socks = true
    }
  }
  match candidate {
    Some(value) =>
      match proxy_from_env_url(value, allow_socks) {
        Ok(proxy) => Ok(Some(proxy))
        Err(err) => Err(err)
      }
    None => Ok(None)
  }
}

/// Resolve the proxy configured through the standard environment variables for
/// `url`: `HTTPS_PROXY` for HTTPS, `http_proxy` (and `HTTP_PROXY` outside CGI)
/// for HTTP, with `ALL_PROXY` as a fallback. Values without a scheme are
/// treated as plain HTTP proxies. `ALL_PROXY` also accepts `socks5://` and
/// `socks5h://` URLs; the scheme-specific variables reject them. `NO_PROXY` is
/// not applied here; combine the result with `Proxy::no_proxy_from_env` and
/// `Connector::with_proxy_bypass`.
pub fn Proxy::from_env(url : Url) -> Result[Proxy?, HttpError] {
  proxy_from_env_lookup(url, @env.get_env_var)
}

fn proxy_no_proxy_lookup(lookup : (String) -> String?) -> Array[String] {
  let value = match proxy_env_value(["NO_PROXY", "no_proxy"], lookup) {
    Some(value) => value
    None => return []
  }
  let patterns : Array[String] = []
  for part in value.split(",") {
    let pattern = part.trim()
    if pattern.length() > 0 {
      patterns.push(pattern.to_owned())
    }
  }
  patterns
}

/// The `NO_PROXY` / `no_proxy` exclusion list from the environment. The
/// patterns use the syntax accepted by `Connector::with_proxy_bypass`.
pub fn Proxy::no_proxy_from_env() -> Array[String] {
  proxy_no_proxy_lookup(@env.get_env_var)
}
