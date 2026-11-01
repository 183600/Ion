/// A synchronous `HttpClient` backed by the browser `XMLHttpRequest` API.
///
/// JavaScript has no synchronous socket API, so this transport delegates the
/// complete request to the host. It is intended for workers, where synchronous
/// `XMLHttpRequest` is allowed, and for hosts that provide a compatible
/// implementation. TLS, redirects, cookies, and response decompression are
/// handled by the browser exactly as they are for `fetch`.
///
/// The returned `Response` exposes the decoded body. Browser-managed fields
/// such as `Content-Encoding`, `Content-Length`, and `Set-Cookie` are therefore
/// not forwarded as the client would see them on a raw socket.
pub struct BrowserFetchClient {
  max_response_body_bytes : Int
} derive(Eq, Debug)

/// A one-shot client using the browser transport. On targets without an
/// `XMLHttpRequest` implementation requests fail with a clear connection
/// error instead of silently falling back to a different transport.
pub fn default_browser_client() -> BrowserFetchClient {
  BrowserFetchClient::new()
}

///|
pub fn BrowserFetchClient::new() -> BrowserFetchClient {
  BrowserFetchClient::{ max_response_body_bytes: DEFAULT_MAX_BODY_BYTES }
}

///|
pub fn BrowserFetchClient::with_max_response_body_bytes(
  self : BrowserFetchClient,
  max_bytes : Int,
) -> BrowserFetchClient {
  BrowserFetchClient::{
    ..self,
    max_response_body_bytes: if max_bytes < 0 { 0 } else { max_bytes },
  }
}

#cfg(target="js")
extern "js" fn browser_fetch(
  method : String,
  url : String,
  headers : FixedArray[String],
  has_body : Bool,
  body_base64 : String,
) -> FixedArray[String] =
  #| (method, url, headers, hasBody, bodyBase64) => {
  #|   try {
  #|     const xhr = new XMLHttpRequest();
  #|     xhr.open(method, url, false);
  #|     let binaryMode = false;
  #|     try {
  #|       xhr.responseType = "arraybuffer";
  #|     } catch (_) {
  #|       binaryMode = true;
  #|       try {
  #|         xhr.overrideMimeType("text/plain; charset=x-user-defined");
  #|       } catch (_) {}
  #|     }
  #|     for (let index = 0; index + 1 < headers.length; index += 2) {
  #|       try {
  #|         xhr.setRequestHeader(headers[index], headers[index + 1]);
  #|       } catch (_) {}
  #|     }
  #|     let payload = null;
  #|     if (hasBody) {
  #|       const binary = atob(bodyBase64);
  #|       payload = new Uint8Array(binary.length);
  #|       for (let index = 0; index < binary.length; index++) {
  #|         payload[index] = binary.charCodeAt(index);
  #|       }
  #|     }
  #|     xhr.send(payload);
  #|     let bytes;
  #|     if (!binaryMode && xhr.response instanceof ArrayBuffer) {
  #|       bytes = new Uint8Array(xhr.response);
  #|     } else {
  #|       const text = xhr.responseText || "";
  #|       bytes = new Uint8Array(text.length);
  #|       for (let index = 0; index < text.length; index++) {
  #|         bytes[index] = text.charCodeAt(index) & 0xff;
  #|       }
  #|     }
  #|     let binary = "";
  #|     const chunk = 0x8000;
  #|     for (let offset = 0; offset < bytes.length; offset += chunk) {
  #|       binary += String.fromCharCode.apply(
  #|         null,
  #|         bytes.subarray(offset, offset + chunk),
  #|       );
  #|     }
  #|     const result = [
  #|       xhr.status === 0 ? "browser fetch failed" : "",
  #|       String(xhr.status),
  #|       xhr.responseURL || "",
  #|       btoa(binary),
  #|     ];
  #|     const rawHeaders = (xhr.getAllResponseHeaders() || "").trim();
  #|     if (rawHeaders.length > 0) {
  #|       for (const line of rawHeaders.split(/[\r\n]+/)) {
  #|         const colon = line.indexOf(":");
  #|         if (colon > 0) {
  #|           result.push(line.slice(0, colon).trim());
  #|           result.push(line.slice(colon + 1).trim());
  #|         }
  #|       }
  #|     }
  #|     return result;
  #|   } catch (error) {
  #|     return ["browser fetch failed: " + String(error), "0", "", ""];
  #|   }
  #| }

#cfg(not(target="js"))
fn browser_fetch(
  method : String,
  url : String,
  headers : FixedArray[String],
  has_body : Bool,
  body_base64 : String,
) -> FixedArray[String] {
  let _ = method
  let _ = url
  let _ = headers
  let _ = has_body
  let _ = body_base64
  [
    "browser fetch is only available on the JavaScript target", "0", "", "",
  ]
}

fn browser_fetch_headers(headers : Headers) -> FixedArray[String] {
  let values : Array[String] = []
  for header in headers.iter() {
    values.push(header.name)
    values.push(header.value)
  }
  FixedArray::from_array(values)
}

fn browser_fetch_response(
  result : FixedArray[String],
  max_body_bytes : Int,
) -> Result[Response, HttpError] {
  if result.length() < 4 {
    return Err(ProtocolError("browser fetch returned a malformed result"))
  }
  if result[0].length() > 0 {
    return Err(NetworkError(ConnectionFailed(result[0])))
  }
  let status = try {
    @string.parse_int(result[1][:])
  } catch {
    _ => return Err(ProtocolError("browser fetch returned an invalid status"))
  }
  if status < 100 || status > 599 {
    return Err(ProtocolError("browser fetch returned an invalid status"))
  }
  let body = try {
    @base64.decode(result[3])
  } catch {
    _ => return Err(ProtocolError("browser fetch returned an invalid body"))
  }
  if body.length() > max_body_bytes {
    return Err(NetworkError(ReadError("response body too large")))
  }
  let mut headers = Headers::new()
  let mut index = 4
  while index + 1 < result.length() {
    let name = result[index]
    let lower = name.to_lower()
    // The browser has already decoded the payload and manages cookies, so
    // these wire-level fields would describe a different representation.
    if lower != "content-encoding" && lower != "content-length" &&
      lower != "transfer-encoding" && lower != "set-cookie" {
      headers = headers.add(name, result[index + 1])
    }
    index = index + 2
  }
  let buffered = BufferedStream::new(body)
  let stream : &Stream = buffered
  let response = Response::new(status, headers, stream)
    .with_max_body_bytes(max_body_bytes)
  // `XMLHttpRequest.responseURL` reports the final URL after redirects. Fall
  // back to the caller-provided URL when the host does not expose it.
  if result[2].length() > 0 {
    match Url::parse(result[2]) {
      Ok(url) => return Ok(response.with_request_url(url))
      Err(_) => ()
    }
  }
  Ok(response)
}

fn browser_fetch_validate_url(url : Url) -> Result[Unit, HttpError] {
  let scheme = url.scheme.to_lower()
  if scheme != "http" && scheme != "https" {
    return Err(InvalidUrl("Only http and https schemes supported"))
  }
  if !valid_tcp_host(url.host) {
    return Err(InvalidUrl("Invalid host"))
  }
  if url.port < 1 || url.port > 65535 {
    return Err(InvalidUrl("Invalid port number"))
  }
  if !valid_url_path_chars(url.path) || !valid_url_query_chars(url.query) ||
    !valid_url_fragment_chars(url.fragment) {
    return Err(InvalidUrl("Invalid URL characters"))
  }
  Ok(())
}

pub impl HttpClient for BrowserFetchClient with fn request(
  self : BrowserFetchClient,
  request : Request,
) -> Result[Response, HttpError] {
  match browser_fetch_validate_url(request.url) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  if canonical_http_method(request.method) == CONNECT {
    return Err(ProtocolError("browser fetch cannot perform CONNECT"))
  }
  if request_requests_upgrade(request.headers) {
    return Err(ProtocolError("browser fetch cannot perform protocol upgrades"))
  }
  let body_base64 = match request.body {
    Some(body) => @base64.encode(body)
    None => ""
  }
  let result = browser_fetch(
    canonical_http_method(request.method).to_string(),
    request.url.to_string(),
    browser_fetch_headers(request.headers),
    request.body is Some(_),
    body_base64,
  )
  match browser_fetch_response(result, self.max_response_body_bytes) {
    Ok(response) =>
      if response.request_url() is None {
        Ok(response.with_request_url(request.url))
      } else {
        Ok(response)
      }
    Err(err) => Err(err)
  }
}
