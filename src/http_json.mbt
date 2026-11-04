/// JSON helpers for request and response bodies.
///
/// The helpers build on `moonbitlang/core/json`, so the whole `Json` value
/// model (objects, arrays, numbers, strings, booleans and null) is available
/// to callers. JSON bodies are always encoded as UTF-8, as required by
/// RFC 8259.

///|
/// The media type used for JSON request bodies.
pub const JSON_CONTENT_TYPE : String = "application/json"

///|
/// Parse a JSON document. The text must be a single JSON value; trailing
/// content is rejected.
pub fn parse_json(text : String) -> Result[Json, HttpError] {
  Ok(@json.parse(text)) catch {
    err => Err(ProtocolError("invalid JSON: " + err.to_string()))
  }
}

///|
/// Serialize a JSON value into compact text.
pub fn stringify_json(json : Json) -> String {
  json.stringify()
}

///|
/// Read the response body, decode any `Content-Encoding`, and parse the
/// result as JSON. The response's body limit bounds the decoded payload.
pub fn Response::json(self : Response) -> Result[Json, HttpError] {
  self.json_with_limit(self.max_body_bytes)
}

///|
/// Like `json`, but bounds the decoded body by `max_bytes` before parsing.
pub fn Response::json_with_limit(
  self : Response,
  max_bytes : Int32,
) -> Result[Json, HttpError] {
  let body = match self.read_body_decoded_with_limit(max_bytes) {
    Ok(body) => body
    Err(err) => return Err(err)
  }
  let text = @utf8.decode(body) catch {
    _ => return Err(ProtocolError("response body is not valid UTF-8"))
  }
  parse_json(text)
}

///|
/// Read the response body and decode it into `T`. `T` must implement
/// `FromJson`, for example a type with `derive(FromJson)`.
pub fn[T : FromJson] Response::json_as(self : Response) -> Result[T, HttpError] {
  let json = match self.json() {
    Ok(json) => json
    Err(err) => return Err(err)
  }
  Ok(@json.from_json(json)) catch {
    err => Err(ProtocolError("invalid JSON: " + err.to_string()))
  }
}

///|
/// Attach a JSON document as the request body and set the `Content-Type`
/// header to `application/json`. An explicit `Content-Type` set by the caller
/// is preserved.
pub fn Request::with_json(self : Request, json : Json) -> Request {
  self.with_json_text(stringify_json(json))
}

///|
/// Attach a JSON document given as text. The text is sent verbatim, so it
/// must already be valid JSON.
pub fn Request::with_json_text(self : Request, text : String) -> Request {
  let request = self.with_body(@utf8.encode(text))
  if request.get_header("Content-Type") is None {
    request.set_header("Content-Type", JSON_CONTENT_TYPE)
  } else {
    request
  }
}

///|
/// Attach any JSON-serializable value as the request body.
pub fn[T : ToJson] Request::with_json_value(
  self : Request,
  value : T,
) -> Request {
  self.with_json(value.to_json())
}

///|
/// Send a JSON document with `POST` and parse the response as JSON.
pub fn UnifiedClient::post_json(
  self : UnifiedClient,
  url : String,
  json : Json,
) -> Result[Response, HttpError] {
  let request = match Request::from_url(POST, url) {
    Ok(request) => request.with_json(json)
    Err(err) => return Err(err)
  }
  self.request(request)
}

///|
/// Send a JSON document given as text with `POST`.
pub fn UnifiedClient::post_json_text(
  self : UnifiedClient,
  url : String,
  text : String,
) -> Result[Response, HttpError] {
  let request = match Request::from_url(POST, url) {
    Ok(request) => request.with_json_text(text)
    Err(err) => return Err(err)
  }
  self.request(request)
}
