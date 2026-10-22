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
  credentials.write_bytes(percent_decode_bytes(user))
  credentials.write_byte(b':')
  credentials.write_bytes(percent_decode_bytes(password))
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
    Some(userinfo) =>
      if userinfo.length() > 0 {
        Some("Basic " + proxy_basic_authorization(userinfo))
      } else {
        None
      }
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
/// clients and tools.
fn proxy_from_env_url(value : String) -> Result[Proxy, HttpError] {
  let lower = value.to_lower()
  if lower.has_prefix("https://") {
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
  }
  match candidate {
    Some(value) =>
      match proxy_from_env_url(value) {
        Ok(proxy) => Ok(Some(proxy))
        Err(err) => Err(err)
      }
    None => Ok(None)
  }
}

/// Resolve the proxy configured through the standard environment variables for
/// `url`: `HTTPS_PROXY` for HTTPS, `http_proxy` (and `HTTP_PROXY` outside CGI)
/// for HTTP, with `ALL_PROXY` as a fallback. Values without a scheme are
/// treated as plain HTTP proxies. `NO_PROXY` is not applied here; combine the
/// result with `Proxy::no_proxy_from_env` and `Connector::with_proxy_bypass`.
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
