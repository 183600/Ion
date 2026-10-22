/// SOCKS5 client handshake (RFC 1928) and username/password authentication
/// (RFC 1929).
///
/// The handshake runs once on a freshly dialed proxy connection and returns
/// any bytes that were read past the final reply. Those bytes belong to the
/// tunnelled protocol and must be replayed before reading from the socket
/// again, exactly like the leftovers from an HTTP `CONNECT` response.

const SOCKS5_VERSION : Int = 5
const SOCKS5_AUTH_VERSION : Int = 1
const SOCKS5_AUTH_NONE : Int = 0
const SOCKS5_AUTH_USERNAME_PASSWORD : Int = 2
const SOCKS5_AUTH_UNACCEPTABLE : Int = 0xff

const SOCKS5_CMD_CONNECT : Int = 1
const SOCKS5_ATYP_IPV4 : Int = 1
const SOCKS5_ATYP_DOMAIN : Int = 3
const SOCKS5_ATYP_IPV6 : Int = 4

const SOCKS5_REPLY_SUCCEEDED : Int = 0

/// Validate the byte-oriented credentials used by the SOCKS5 username/password
/// sub-negotiation. RFC 1929 length prefixes are one octet and the protocol
/// does not allow an empty user name or password.
fn socks5_credentials_valid(
  username : Bytes,
  password : Bytes,
) -> Result[Unit, HttpError] {
  if username.length() == 0 || username.length() > 255 {
    return Err(InvalidUrl("SOCKS5 username must be 1-255 bytes"))
  }
  if password.length() == 0 || password.length() > 255 {
    return Err(InvalidUrl("SOCKS5 password must be 1-255 bytes"))
  }
  Ok(())
}

/// A buffered reader for the fixed-size SOCKS5 reply fields. A single socket
/// read can return more than one field (or the first tunnelled bytes), so the
/// reader keeps the excess rather than losing data that belongs to the
/// protocol running through the tunnel.
struct Socks5Reader {
  stream : &Stream
  mut pending : Bytes
  mut offset : Int
}

fn Socks5Reader::new(stream : &Stream) -> Socks5Reader {
  Socks5Reader::{ stream, pending: b"", offset: 0 }
}

fn Socks5Reader::fill(self : Socks5Reader) -> Result[Unit, HttpError] {
  let buffer = Buffer(size_hint=512)
  let count = match self.stream.read(buffer) {
    Ok(count) => count
    Err(err) => return Err(http_error_from_net(err))
  }
  if count < 0 {
    return Err(NetworkError(ReadError("invalid SOCKS5 read count")))
  }
  if count == 0 {
    return Err(NetworkError(ConnectionFailed(
      "SOCKS5 proxy closed the connection during the handshake",
    )))
  }
  let data = buffer.to_bytes()
  if data.length() == 0 {
    return Err(NetworkError(ReadError("SOCKS5 proxy returned no data")))
  }
  self.pending = data
  self.offset = 0
  Ok(())
}

fn Socks5Reader::read_exact(
  self : Socks5Reader,
  length : Int,
) -> Result[Bytes, HttpError] {
  let output = Buffer(size_hint=length)
  while output.length() < length {
    if self.offset >= self.pending.length() {
      match self.fill() {
        Ok(_) => ()
        Err(err) => return Err(err)
      }
    }
    let available = self.pending.length() - self.offset
    let remaining = length - output.length()
    let take = if available < remaining { available } else { remaining }
    output.write_bytes(self.pending.exact_view(
      start=self.offset,
      end=self.offset + take,
    ))
    self.offset = self.offset + take
  }
  Ok(output.to_bytes())
}

fn Socks5Reader::read_byte(self : Socks5Reader) -> Result[Int, HttpError] {
  let byte = match self.read_exact(1) {
    Ok(value) => value
    Err(err) => return Err(err)
  }
  Ok(byte[0].to_int())
}

fn Socks5Reader::leftover(self : Socks5Reader) -> Bytes {
  if self.offset >= self.pending.length() {
    b""
  } else {
    self.pending.exact_view(start=self.offset, end=self.pending.length()).to_owned()
  }
}

fn socks5_send(stream : &Stream, data : Bytes) -> Result[Unit, HttpError] {
  match write_all(stream, data) {
    Ok(_) => ()
    Err(err) => return Err(http_error_from_net(err))
  }
  match stream.flush() {
    Ok(_) => Ok(())
    Err(err) => Err(http_error_from_net(err))
  }
}

fn socks5_append_port(output : Buffer, port : Int) -> Unit {
  output.write_byte(((port >> 8) & 0xff).to_byte())
  output.write_byte((port & 0xff).to_byte())
}

/// Append the destination address in the form the proxy understands. Callers
/// choose whether a domain name is resolved locally (`socks5`) or passed
/// through for the proxy to resolve (`socks5h`); IPv4 and IPv6 literals always
/// use their binary address forms.
fn socks5_append_target(
  output : Buffer,
  host : String,
  port : Int,
  bracketed : Bool,
) -> Result[Unit, HttpError] {
  if port < 1 || port > 65535 {
    return Err(InvalidUrl("Invalid SOCKS5 target port"))
  }
  if !bracketed && is_ipv4_literal(host) {
    let address = match bypass_ipv4_value(host) {
      Some(address) => address
      None => return Err(InvalidUrl("Invalid SOCKS5 target address"))
    }
    output.write_byte(SOCKS5_ATYP_IPV4.to_byte())
    output.write_byte(((address >> 24) & 0xff).to_byte())
    output.write_byte(((address >> 16) & 0xff).to_byte())
    output.write_byte(((address >> 8) & 0xff).to_byte())
    output.write_byte((address & 0xff).to_byte())
  } else if is_ipv6_literal_with_zone(host) {
    let bytes = match bypass_ipv6_bytes(host) {
      Some(bytes) => bytes
      None => return Err(InvalidUrl("Invalid SOCKS5 target address"))
    }
    output.write_byte(SOCKS5_ATYP_IPV6.to_byte())
    output.write_bytes(bytes)
  } else {
    // Bracketed IPvFuture literals are not expressible in SOCKS5 and must not
    // be mistaken for a DNS name with the same text.
    if bracketed {
      return Err(InvalidUrl("Unsupported SOCKS5 target address"))
    }
    let name = @utf8.encode(host)
    if name.length() == 0 || name.length() > 255 {
      return Err(InvalidUrl("Invalid SOCKS5 target host name"))
    }
    output.write_byte(SOCKS5_ATYP_DOMAIN.to_byte())
    output.write_byte(name.length().to_byte())
    output.write_bytes(name)
  }
  socks5_append_port(output, port)
  Ok(())
}

fn socks5_reply_error(code : Int) -> HttpError {
  match code {
    1 => NetworkError(ConnectionFailed("SOCKS5 proxy reported a general failure"))
    2 => NetworkError(ConnectionFailed("SOCKS5 proxy denied the connection"))
    3 => NetworkError(ConnectionFailed("SOCKS5 proxy reported network unreachable"))
    4 => NetworkError(ConnectionFailed("SOCKS5 proxy reported host unreachable"))
    5 => NetworkError(ConnectionFailed("SOCKS5 proxy reported connection refused"))
    6 => NetworkError(ConnectionFailed("SOCKS5 proxy reported TTL expired"))
    7 => ProtocolError("SOCKS5 proxy does not support CONNECT")
    8 => ProtocolError("SOCKS5 proxy does not support the target address type")
    _ => ProtocolError("SOCKS5 proxy returned error " + code.to_string())
  }
}

fn socks5_discard_bound_address(
  reader : Socks5Reader,
  address_type : Int,
) -> Result[Unit, HttpError] {
  if address_type == SOCKS5_ATYP_IPV4 {
    match reader.read_exact(4) {
      Ok(_) => ()
      Err(err) => return Err(err)
    }
  } else if address_type == SOCKS5_ATYP_IPV6 {
    match reader.read_exact(16) {
      Ok(_) => ()
      Err(err) => return Err(err)
    }
  } else if address_type == SOCKS5_ATYP_DOMAIN {
    let length = match reader.read_byte() {
      Ok(length) => length
      Err(err) => return Err(err)
    }
    if length == 0 {
      return Err(ProtocolError("SOCKS5 proxy returned an empty bound address"))
    }
    match reader.read_exact(length) {
      Ok(_) => ()
      Err(err) => return Err(err)
    }
  } else {
    return Err(ProtocolError("SOCKS5 proxy returned an invalid address type"))
  }
  match reader.read_exact(2) {
    Ok(_) => Ok(())
    Err(err) => Err(err)
  }
}

/// Establish a SOCKS5 CONNECT tunnel to `host:port` on an already-connected
/// proxy stream. Returns any bytes read past the reply, which the caller must
/// replay into the tunnel.
fn socks5_connect(
  stream : &Stream,
  host : String,
  port : Int,
  bracketed : Bool,
  credentials : (Bytes, Bytes)?,
) -> Result[Bytes, HttpError] {
  let reader = Socks5Reader::new(stream)
  let greeting = Buffer(size_hint=4)
  greeting.write_byte(SOCKS5_VERSION.to_byte())
  match credentials {
    Some(_) => {
      greeting.write_byte(2)
      greeting.write_byte(SOCKS5_AUTH_NONE.to_byte())
      greeting.write_byte(SOCKS5_AUTH_USERNAME_PASSWORD.to_byte())
    }
    None => {
      greeting.write_byte(1)
      greeting.write_byte(SOCKS5_AUTH_NONE.to_byte())
    }
  }
  match socks5_send(stream, greeting.to_bytes()) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }

  let choice = match reader.read_exact(2) {
    Ok(choice) => choice
    Err(err) => return Err(err)
  }
  if choice[0].to_int() != SOCKS5_VERSION {
    return Err(ProtocolError("SOCKS5 proxy returned an invalid version"))
  }
  let selected_method = choice[1].to_int()
  if selected_method == SOCKS5_AUTH_NONE {
    ()
  } else if selected_method == SOCKS5_AUTH_USERNAME_PASSWORD {
    let (username, password) = match credentials {
      Some(credentials) => credentials
      None => {
        return Err(ProtocolError(
          "SOCKS5 proxy requires username/password authentication",
        ))
      }
    }
    match socks5_credentials_valid(username, password) {
      Ok(_) => ()
      Err(err) => return Err(err)
    }
    let auth = Buffer(size_hint=username.length() + password.length() + 3)
    auth.write_byte(SOCKS5_AUTH_VERSION.to_byte())
    auth.write_byte(username.length().to_byte())
    auth.write_bytes(username)
    auth.write_byte(password.length().to_byte())
    auth.write_bytes(password)
    match socks5_send(stream, auth.to_bytes()) {
      Ok(_) => ()
      Err(err) => return Err(err)
    }
    let reply = match reader.read_exact(2) {
      Ok(reply) => reply
      Err(err) => return Err(err)
    }
    if reply[0].to_int() != SOCKS5_AUTH_VERSION || reply[1].to_int() != 0 {
      return Err(ProtocolError("SOCKS5 proxy authentication failed"))
    }
  } else if selected_method == SOCKS5_AUTH_UNACCEPTABLE {
    return Err(ProtocolError(
      "SOCKS5 proxy rejected all offered authentication methods",
    ))
  } else {
    return Err(ProtocolError(
      "SOCKS5 proxy selected an unsupported authentication method",
    ))
  }

  let request = Buffer(size_hint=host.length() + 8)
  request.write_byte(SOCKS5_VERSION.to_byte())
  request.write_byte(SOCKS5_CMD_CONNECT.to_byte())
  request.write_byte(0)
  match socks5_append_target(request, host, port, bracketed) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  match socks5_send(stream, request.to_bytes()) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }

  let head = match reader.read_exact(4) {
    Ok(head) => head
    Err(err) => return Err(err)
  }
  if head[0].to_int() != SOCKS5_VERSION {
    return Err(ProtocolError("SOCKS5 proxy returned an invalid version"))
  }
  if head[2].to_int() != 0 {
    return Err(ProtocolError("SOCKS5 proxy returned an invalid reserved field"))
  }
  let reply = head[1].to_int()
  if reply != SOCKS5_REPLY_SUCCEEDED {
    return Err(socks5_reply_error(reply))
  }
  match socks5_discard_bound_address(reader, head[3].to_int()) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  Ok(reader.leftover())
}
