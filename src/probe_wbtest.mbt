/// Temporary probe tests for auditing edge cases.
fn probe_result(value : Bool) -> String {
  if value {
    "ok"
  } else {
    "err"
  }
}

test "probe audit edge cases" {
  let show = fn(name : String, value : String) { println(name + " => " + value) }
  // URL userinfo validation
  show("userinfo %zz", probe_result(Url::parse("http://%zz@example.com/") is Ok(_)))
  show("userinfo backslash", probe_result(Url::parse("http://us\\er@example.com/") is Ok(_)))
  show("userinfo bracket", probe_result(Url::parse("http://us[er@example.com/") is Ok(_)))
  show("userinfo empty", probe_result(Url::parse("http://@example.com/") is Ok(_)))
  show("userinfo empty password", probe_result(Url::parse("http://user:@example.com/") is Ok(_)))
  // host percent escapes
  show("host %2F", probe_result(Url::parse("http://exa%2Fmple.com/") is Ok(_)))
  // port leading zeros
  show("port leading zero", probe_result(Url::parse("http://example.com:0080/") is Ok(_)))
  // form tilde
  let form = Request::new(POST, Url::new("http", "x", 80)).with_form([
    ("a", "~"),
    ("b", "*"),
    ("c", " "),
    ("d", "%"),
  ])
  show("form", @utf8.decode(form.body.unwrap()[:]))
  // redirect
  let base = Url::parse("http://example.com/dir/page?q=1").unwrap()
  match resolve_redirect_url(base, "?x=2") {
    Ok(u) => show("redir query", u.to_string())
    Err(_) => show("redir query", "err")
  }
  match resolve_redirect_url(base, "//other/x") {
    Ok(u) => show("redir scheme-relative", u.to_string())
    Err(_) => show("redir scheme-relative", "err")
  }
  match resolve_redirect_url(base, "HTTP://OTHER/x") {
    Ok(u) => show("redir abs upper", u.to_string())
    Err(_) => show("redir abs upper", "err")
  }
  match resolve_redirect_url(base, "next") {
    Ok(u) => show("redir relative", u.to_string())
    Err(_) => show("redir relative", "err")
  }
  // authority default port for scheme uppercase
  let up = Url::parse("HTTP://Example.COM:80/").unwrap()
  show("authority upper", up.authority())
  // response TE gzip chunked
  let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n"
  let codec = H1Codec::new(regression_mock_stream(raw, 0, 0))
  match codec.decode_response() {
    Ok(r) =>
      match r.read_body() {
        Ok(b) => show("te gzip chunked", @utf8.decode(b[:]))
        Err(_) => show("te gzip chunked", "body err")
      }
    Err(_) => show("te gzip chunked", "decode err")
  }
  // request CL with whitespace
  let stream = regression_mock_stream("", 0, 0)
  let codec2 = H1Codec::new(stream)
  let url = Url::parse("http://example.com/").unwrap()
  let req = Request::new(POST, url)
    .with_header("Content-Length", " 5 ")
    .with_body(@utf8.encode("hello"))
  show("cl spaces", probe_result(codec2.encode_request(req) is Ok(_)))
  show("wire", @utf8.decode(stream.output.to_bytes()[:]))
  // request Host with trailing dot
  let stream3 = regression_mock_stream("", 0, 0)
  let codec3 = H1Codec::new(stream3)
  show(
    "host dot",
    probe_result(codec3.encode_request(Request::new(GET, url).with_header("Host", "example.com.")) is Ok(_)),
  )
  // status line without reason
  let raw2 = "HTTP/1.1 200\r\nContent-Length: 0\r\n\r\n"
  show("status no reason", probe_result(H1Codec::new(regression_mock_stream(raw2, 0, 0)).decode_response() is Ok(_)))
  // 304 with body
  let raw3 = "HTTP/1.1 304 Not Modified\r\nContent-Length: 5\r\n\r\nhelloNEXT"
  let s3 = regression_mock_stream(raw3, 1, 0)
  let c3 = H1Codec::new(s3)
  match c3.decode_response() {
    Ok(r) => {
      let buf = @buffer.new(size_hint=8)
      show("304 read", r.body.read(buf).unwrap().to_string())
      show("304 offset", s3.offset.to_string())
    }
    Err(_) => show("304", "decode err")
  }
}
