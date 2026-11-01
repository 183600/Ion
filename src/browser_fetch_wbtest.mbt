fn browser_test_result(
  error : String,
  status : String,
  body : Bytes,
  headers : Array[(String, String)],
) -> FixedArray[String] {
  let values : Array[String] = [
    error,
    status,
    "",
    @base64.encode(body),
  ]
  for header in headers {
    let (name, value) = header
    values.push(name)
    values.push(value)
  }
  FixedArray::from_array(values)
}

///|
test "browser fetch builds a response from the host result" {
  let response = browser_fetch_response(
    browser_test_result("", "200", b"hello", [
      ("Content-Type", "text/plain"),
      ("Content-Encoding", "gzip"),
      ("Content-Length", "5"),
      ("Transfer-Encoding", "chunked"),
      ("X-Test", "one"),
    ]),
    1024,
  ).unwrap()
  assert_eq(response.version, "HTTP/1.1")
  assert_eq(response.status, 200)
  assert_eq(response.get_header("Content-Type"), Some("text/plain"))
  assert_eq(response.get_header("Content-Encoding"), None)
  assert_eq(response.get_header("Content-Length"), None)
  assert_eq(response.get_header("Transfer-Encoding"), None)
  assert_eq(response.get_header("X-Test"), Some("one"))
  assert_eq(response.read_body().unwrap(), b"hello")
}

///|
test "browser fetch propagates host failures" {
  let response = browser_fetch_response(
    browser_test_result("network down", "0", b"", []),
    1024,
  )
  match response {
    Err(NetworkError(ConnectionFailed(message))) =>
      assert_eq(message, "network down")
    _ => fail("a browser fetch failure was not propagated")
  }
}

///|
test "browser fetch validates malformed host results" {
  assert_true(browser_fetch_response(FixedArray::from_array(["ok"]), 1024) is
    Err(ProtocolError(_)))
  let invalid_status = FixedArray::from_array(["", "none", "", ""])
  assert_true(browser_fetch_response(invalid_status, 1024) is
    Err(ProtocolError(_)))
  let invalid_body = FixedArray::from_array(["", "200", "", "not base64!"])
  assert_true(browser_fetch_response(invalid_body, 1024) is Err(ProtocolError(_)))
  let out_of_range = FixedArray::from_array(["", "600", "", ""])
  assert_true(browser_fetch_response(out_of_range, 1024) is Err(ProtocolError(_)))
}

///|
test "browser fetch enforces the configured body limit" {
  let response = browser_fetch_response(
    browser_test_result("", "200", b"hello", []),
    4,
  )
  match response {
    Err(NetworkError(ReadError(message))) =>
      assert_eq(message, "response body too large")
    _ => fail("an oversized browser response was accepted")
  }
}

///|
#cfg(not(target="js"))
test "browser fetch client reports a missing host implementation" {
  let client = BrowserFetchClient::new()
  let request = Request::from_url(GET, "http://example.com/").unwrap()
  match client.request(request) {
    Err(NetworkError(ConnectionFailed(message))) =>
      assert_eq(message, "browser fetch is only available on the JavaScript target")
    _ => fail("browser fetch unexpectedly succeeded off the JavaScript target")
  }
}

///|
test "browser fetch client rejects tunnels and upgrades before dispatch" {
  let client = BrowserFetchClient::new()
  let url = Url::parse("http://example.com/").unwrap()
  match client.request(Request::new(CONNECT, url)) {
    Err(ProtocolError(message)) =>
      assert_eq(message, "browser fetch cannot perform CONNECT")
    _ => fail("browser fetch accepted CONNECT")
  }
  let upgrade = Request::new(GET, url).with_upgrade("websocket")
  match client.request(upgrade) {
    Err(ProtocolError(message)) =>
      assert_eq(message, "browser fetch cannot perform protocol upgrades")
    _ => fail("browser fetch accepted a protocol upgrade")
  }
}

#cfg(target="js")
extern "js" fn browser_test_install_mock(fail : Bool) -> Unit =
  #| (fail) => {
  #|   globalThis.__featherBrowserTest = { fail, request: null };
  #|   globalThis.XMLHttpRequest = class {
  #|     constructor() {
  #|       this.method = "";
  #|       this.url = "";
  #|       this.async = true;
  #|       this.headers = [];
  #|       this.status = 0;
  #|       this.statusText = "";
  #|       this.response = null;
  #|       this.responseText = "";
  #|       this.responseType = "";
  #|     }
  #|     open(method, url, async) {
  #|       this.method = method;
  #|       this.url = url;
  #|       this.async = async;
  #|     }
  #|     setRequestHeader(name, value) {
  #|       this.headers.push([name, value]);
  #|     }
  #|     overrideMimeType(_) {}
  #|     send(body) {
  #|       const state = globalThis.__featherBrowserTest;
  #|       let bodyBase64 = "";
  #|       if (body) {
  #|         let binary = "";
  #|         for (let index = 0; index < body.length; index++) {
  #|           binary += String.fromCharCode(body[index]);
  #|         }
  #|         bodyBase64 = btoa(binary);
  #|       }
  #|       state.request = {
  #|         method: this.method,
  #|         url: this.url,
  #|         async: this.async,
  #|         headers: this.headers,
  #|         bodyBase64,
  #|       };
  #|       if (state.fail) {
  #|         throw new Error("boom");
  #|       }
  #|       this.status = 201;
  #|       this.statusText = "Created";
  #|       this.response = Uint8Array.from([104, 101, 108, 108, 111]).buffer;
  #|     }
  #|     getAllResponseHeaders() {
  #|       return "Content-Type: text/plain\r\nX-Test: one\r\n";
  #|     }
  #|   };
  #| }

#cfg(target="js")
extern "js" fn browser_test_last_request() -> FixedArray[String] =
  #| () => {
  #|   const request = globalThis.__featherBrowserTest.request;
  #|   const result = [
  #|     request.method,
  #|     request.url,
  #|     String(request.async),
  #|     request.bodyBase64,
  #|   ];
  #|   for (const [name, value] of request.headers) {
  #|     result.push(name);
  #|     result.push(value);
  #|   }
  #|   return result;
  #| }

#cfg(target="js")
extern "js" fn browser_test_cleanup() -> Unit =
  #| () => {
  #|   delete globalThis.XMLHttpRequest;
  #|   delete globalThis.__featherBrowserTest;
  #| }

#cfg(target="js")
test "browser fetch forwards a request through XMLHttpRequest" {
  browser_test_install_mock(false)
  let request = Request::from_url(POST, "http://example.com/upload")
    .unwrap()
    .with_header("X-Request", "yes")
    .with_body(b"body")
  let response = BrowserFetchClient::new().request(request).unwrap()
  assert_eq(response.status, 201)
  assert_eq(response.get_header("Content-Type"), Some("text/plain"))
  assert_eq(response.get_header("X-Test"), Some("one"))
  assert_eq(response.request_url(), Some(Url::parse("http://example.com/upload").unwrap()))
  assert_eq(response.read_body().unwrap(), b"hello")
  let info = browser_test_last_request()
  assert_eq(info[0], "POST")
  assert_eq(info[1], "http://example.com/upload")
  assert_eq(info[2], "false")
  assert_eq(info[3], @base64.encode(b"body"))
  assert_eq(info[4], "X-Request")
  assert_eq(info[5], "yes")
  browser_test_cleanup()
}

#cfg(target="js")
test "browser fetch reports XMLHttpRequest send failures" {
  browser_test_install_mock(true)
  let request = Request::from_url(GET, "http://example.com/").unwrap()
  match BrowserFetchClient::new().request(request) {
    Err(NetworkError(ConnectionFailed(message))) =>
      assert_true(message.has_prefix("browser fetch failed:"))
    _ => fail("an XMLHttpRequest failure was not reported")
  }
  browser_test_cleanup()
}

#cfg(target="js")
test "one-shot helpers use the browser transport on JavaScript" {
  browser_test_install_mock(false)
  let response = get("http://example.com/one-shot").unwrap()
  assert_eq(response.status, 201)
  assert_eq(response.read_body().unwrap(), b"hello")
  let info = browser_test_last_request()
  assert_eq(info[0], "GET")
  assert_eq(info[1], "http://example.com/one-shot")
  assert_eq(info[2], "false")
  browser_test_cleanup()
}

#cfg(target="js")
test "unified client uses the browser transport on JavaScript" {
  browser_test_install_mock(false)
  let client = UnifiedClient::new()
    .with_default_header("X-Default", "yes")
    .with_max_response_body_bytes(1024)
  let response = client.get("http://example.com/client").unwrap()
  assert_eq(response.status, 201)
  assert_eq(response.get_header("X-Test"), Some("one"))
  assert_eq(response.read_body().unwrap(), b"hello")
  let info = browser_test_last_request()
  assert_eq(info[0], "GET")
  assert_eq(info[1], "http://example.com/client")
  assert_eq(info[2], "false")
  let mut found_default = false
  let mut index = 4
  while index + 1 < info.length() {
    if info[index] == "X-Default" && info[index + 1] == "yes" {
      found_default = true
    }
    index = index + 2
  }
  assert_true(found_default)
  browser_test_cleanup()
}

#cfg(target="js")
test "unified client applies the browser response body limit" {
  browser_test_install_mock(false)
  let client = UnifiedClient::new().with_max_response_body_bytes(4)
  match client.get("http://example.com/too-large") {
    Err(NetworkError(ReadError(message))) =>
      assert_eq(message, "response body too large")
    _ => fail("an oversized unified browser response was accepted")
  }
  browser_test_cleanup()
}

///|
test "browser fetch keeps the final response URL" {
  let result = FixedArray::from_array([
    "",
    "200",
    "https://example.com/final",
    @base64.encode(b"ok"),
  ])
  let response = browser_fetch_response(result, 1024).unwrap()
  assert_eq(
    response.request_url(),
    Some(Url::parse("https://example.com/final").unwrap()),
  )
}
