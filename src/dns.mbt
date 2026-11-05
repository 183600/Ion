///|
/// DNS resolver using the UDP transport (RFC 1035).
///
/// This module provides a blocking DNS client that can resolve A (IPv4) and
/// AAAA (IPv6) records using a `Datagram` transport. It is useful when the
/// platform's `getaddrinfo` is unavailable or when finer control over DNS
/// queries is needed.
///
/// Queries use a configurable timeout and retry with exponential backoff.
/// Raw response messages can be decoded with `dns_parse_response`, for
/// example to inspect the answer sections of a custom exchange.
const DNS_PORT : Int32 = 53

///|
const DNS_MAX_MESSAGE_SIZE : Int32 = 512

///|
const DNS_DEFAULT_TIMEOUT_MS : Int32 = 5000

///|
const DNS_DEFAULT_RETRIES : Int32 = 3

///|
const DNS_HEADER_SIZE : Int32 = 12

///|
#derive(Eq, Debug)
pub enum DnsError {
  TransportError(NetError)
  InvalidName
  ServerFailure
  NameError
  NotImplemented
  Refused
  Timeout
  NoAnswer
  MalformedResponse
}

///|
#derive(Eq, Debug)
pub enum DnsRecordType {
  A
  AAAA
  /// Any other RR type (CNAME, NS, SOA, OPT, ...). RFC 1034 §6.2 requires a
  /// resolver to tolerate records it does not care about: unknown types are
  /// parsed so their rdata can be skipped and are filtered out of results by
  /// the record-type comparison.
  Other(Int32)
}

///|
pub fn DnsRecordType::code(typ : DnsRecordType) -> Int32 {
  match typ {
    A => 1
    AAAA => 28
    Other(code) => code
  }
}

///|
#derive(Eq, Debug)
pub struct DnsRecord {
  name : String
  typ : DnsRecordType
  class : Int32
  ttl : Int32
  data : Bytes
}

///|
#derive(Eq, Debug)
pub struct DnsResponse {
  id : Int32
  response_code : Int32
  questions : List[DnsRecord]
  answers : List[DnsRecord]
  authorities : List[DnsRecord]
  additionals : List[DnsRecord]
}

///|
fn dns_normalize_name(name : String) -> Result[String, DnsError] {
  if name.length() == 0 {
    return Err(InvalidName)
  }
  let name = name.to_lower()
  if is_ip_literal(name) {
    return Err(InvalidName)
  }
  if idna_needs_conversion(name) {
    match idna_host_to_ascii(name) {
      Some(ascii) => Ok(ascii)
      None => Err(InvalidName)
    }
  } else {
    Ok(name)
  }
}

///|
fn dns_name_encode(name : String) -> Result[Bytes, DnsError] {
  if name.length() > 255 {
    return Err(InvalidName)
  }
  let output = Buffer(size_hint=name.length() + 2)
  for label in name.split(".") {
    let label = label.to_owned()
    if label.length() == 0 || label.length() > 63 {
      return Err(InvalidName)
    }
    output.write_byte(label.length().to_byte())
    output.write_bytes(@utf8.encode(label))
  }
  output.write_byte(0)
  Ok(output.to_bytes())
}

///|
fn dns_name_decode(
  data : Bytes,
  offset : Int32,
) -> Result[(String, Int32), DnsError] {
  let mut result = ""
  let mut pos = offset
  let mut jumped = false
  let mut original_pos = offset
  let visited : Array[Int32] = []
  while true {
    if pos >= data.length() {
      return Err(MalformedResponse)
    }
    let length = data[pos].to_int()
    if length == 0 {
      pos = pos + 1
      break
    }
    if (length & 0xC0) == 0xC0 {
      if pos + 1 >= data.length() {
        return Err(MalformedResponse)
      }
      let pointer = ((length & 0x3F) << 8) | data[pos + 1].to_int()
      if !jumped {
        original_pos = pos + 2
        jumped = true
      }
      if visited.contains(pointer) {
        return Err(MalformedResponse)
      }
      pos = pointer
      continue
    }
    pos = pos + 1
    if pos + length > data.length() {
      return Err(MalformedResponse)
    }
    let label = @utf8.decode_lossy(data.exact_view(start=pos, end=pos + length))
    if result.length() > 0 {
      result = result + "."
    }
    result = result + label
    pos = pos + length
  }
  let final_pos = if jumped { original_pos } else { pos }
  Ok((result, final_pos))
}

///|
fn dns_build_question(
  name : String,
  typ : DnsRecordType,
) -> Result[Bytes, DnsError] {
  let name = match dns_normalize_name(name) {
    Ok(n) => n
    Err(e) => return Err(e)
  }
  let encoded = match dns_name_encode(name) {
    Ok(e) => e
    Err(err) => return Err(err)
  }
  let output = Buffer(size_hint=encoded.length() + 4)
  output.write_bytes(encoded)
  let type_code = DnsRecordType::code(typ)
  output.write_byte(((type_code >> 8) & 0xFF).to_byte())
  output.write_byte((type_code & 0xFF).to_byte())
  output.write_byte(0)
  output.write_byte(1)
  Ok(output.to_bytes())
}

///|
fn dns_parse_record(
  data : Bytes,
  offset : Int32,
) -> Result[(DnsRecord, Int32), DnsError] {
  let (name, pos) = match dns_name_decode(data, offset) {
    Ok(r) => r
    Err(err) => return Err(err)
  }
  if pos + 10 > data.length() {
    return Err(MalformedResponse)
  }
  let typ_code = (data[pos].to_int() << 8) | data[pos + 1].to_int()
  let class = (data[pos + 2].to_int() << 8) | data[pos + 3].to_int()
  let ttl = (data[pos + 4].to_int() << 24) |
    (data[pos + 5].to_int() << 16) |
    (data[pos + 6].to_int() << 8) |
    data[pos + 7].to_int()
  let rdlength = (data[pos + 8].to_int() << 8) | data[pos + 9].to_int()
  let rdata_start = pos + 10
  if rdata_start + rdlength > data.length() {
    return Err(MalformedResponse)
  }
  let rdata = data
    .exact_view(start=rdata_start, end=rdata_start + rdlength)
    .to_owned()
  let typ = match typ_code {
    1 => A
    28 => AAAA
    // Answer, authority, and additional sections routinely carry record types
    // a stub resolver does not need (CNAME chains, NS/SOA delegation data,
    // EDNS OPT). Skipping them is required; failing the whole response would
    // break resolution of common names.
    other => Other(other)
  }
  let record = DnsRecord::{ name, typ, class, ttl, data: rdata, }
  Ok((record, rdata_start + rdlength))
}

///|
/// Decode a DNS response message (RFC 1035 §4.1): the fixed 12-byte header,
/// the question section, and the answer, authority, and additional sections.
/// Replies with a non-zero RCODE map to their `DnsError`; structurally invalid
/// messages are `MalformedResponse`.
pub fn dns_parse_response(data : Bytes) -> Result[DnsResponse, DnsError] {
  if data.length() < DNS_HEADER_SIZE {
    return Err(MalformedResponse)
  }
  let id = (data[0].to_int() << 8) | data[1].to_int()
  let flags = (data[2].to_int() << 8) | data[3].to_int()
  let qr = (flags >> 15) & 1
  let rcode = flags & 0xF
  let qdcount = (data[4].to_int() << 8) | data[5].to_int()
  let ancount = (data[6].to_int() << 8) | data[7].to_int()
  let nscount = (data[8].to_int() << 8) | data[9].to_int()
  let arcount = (data[10].to_int() << 8) | data[11].to_int()
  if qr != 1 {
    return Err(MalformedResponse)
  }
  if rcode != 0 {
    return Err(
      match rcode {
        1 => ServerFailure
        2 => ServerFailure
        3 => NameError
        4 => NotImplemented
        5 => Refused
        _ => ServerFailure
      },
    )
  }
  let mut pos = DNS_HEADER_SIZE
  let questions : Array[DnsRecord] = []
  let mut i = 0
  while i < qdcount {
    let (name, next) = match dns_name_decode(data, pos) {
      Ok(r) => r
      Err(err) => return Err(err)
    }
    if next + 4 > data.length() {
      return Err(MalformedResponse)
    }
    let typ_code = (data[next].to_int() << 8) | data[next + 1].to_int()
    let class = (data[next + 2].to_int() << 8) | data[next + 3].to_int()
    let typ = match typ_code {
      1 => A
      28 => AAAA
      _ => return Err(NotImplemented)
    }
    questions.push(DnsRecord::{ name, typ, class, ttl: 0, data: b"", })
    pos = next + 4
    i = i + 1
  }
  let answers : Array[DnsRecord] = []
  i = 0
  while i < ancount {
    let (record, next) = match dns_parse_record(data, pos) {
      Ok(r) => r
      Err(err) => return Err(err)
    }
    answers.push(record)
    pos = next
    i = i + 1
  }
  let authorities : Array[DnsRecord] = []
  i = 0
  while i < nscount {
    let (record, next) = match dns_parse_record(data, pos) {
      Ok(r) => r
      Err(err) => return Err(err)
    }
    authorities.push(record)
    pos = next
    i = i + 1
  }
  let additionals : Array[DnsRecord] = []
  i = 0
  while i < arcount {
    let (record, next) = match dns_parse_record(data, pos) {
      Ok(r) => r
      Err(err) => return Err(err)
    }
    additionals.push(record)
    pos = next
    i = i + 1
  }
  Ok(DnsResponse::{
    id,
    response_code: rcode,
    questions: @list.List(questions),
    answers: @list.List(answers),
    authorities: @list.List(authorities),
    additionals: @list.List(additionals),
  })
}

///|
pub struct DnsResolver {
  transport : &Datagram
  server : String
  port : Int32
  timeout_ms : Int32
  retries : Int32
}

///|
pub fn DnsResolver::new(transport : &Datagram, server : String) -> DnsResolver {
  DnsResolver::with_options(
    transport,
    server,
    DNS_DEFAULT_TIMEOUT_MS,
    DNS_DEFAULT_RETRIES,
  )
}

///|
pub fn DnsResolver::with_options(
  transport : &Datagram,
  server : String,
  timeout_ms : Int32,
  retries : Int32,
) -> DnsResolver {
  let server = if is_ip_literal(server) || !idna_needs_conversion(server) {
    server
  } else {
    match idna_host_to_ascii(server) {
      Some(ascii) => ascii
      None => server
    }
  }
  DnsResolver::{
    transport,
    server,
    port: DNS_PORT,
    timeout_ms: if timeout_ms < 0 {
      0
    } else {
      timeout_ms
    },
    retries: if retries < 0 {
      0
    } else {
      retries
    },
  }
}

///|
pub fn DnsResolver::with_port(self : DnsResolver, port : Int32) -> DnsResolver {
  DnsResolver::{
    ..self,
    port: if port < 1 || port > 65535 {
      DNS_PORT
    } else {
      port
    },
  }
}

///|
pub fn DnsResolver::with_timeout(
  self : DnsResolver,
  timeout_ms : Int32,
) -> DnsResolver {
  DnsResolver::{
    ..self,
    timeout_ms: if timeout_ms < 0 {
      0
    } else {
      timeout_ms
    },
  }
}

///|
pub fn DnsResolver::with_retries(
  self : DnsResolver,
  retries : Int32,
) -> DnsResolver {
  DnsResolver::{ ..self, retries: if retries < 0 { 0 } else { retries }, }
}

///|
fn DnsResolver::query_one(
  self : DnsResolver,
  name : String,
  typ : DnsRecordType,
) -> Result[List[Bytes], DnsError] {
  let query_id = @env.rand(2)
  let id = if query_id is Some(bytes) && bytes.length() == 2 {
    (bytes[0].to_int() << 8) | bytes[1].to_int()
  } else {
    (@env.now() & 0xFFFF).to_int()
  }
  let question = match dns_build_question(name, typ) {
    Ok(q) => q
    Err(err) => return Err(err)
  }
  let header = Buffer(size_hint=DNS_HEADER_SIZE)
  header.write_byte(((id >> 8) & 0xFF).to_byte())
  header.write_byte((id & 0xFF).to_byte())
  header.write_byte(0x01)
  header.write_byte(0x00)
  header.write_byte(0)
  header.write_byte(1)
  header.write_byte(0)
  header.write_byte(0)
  header.write_byte(0)
  header.write_byte(0)
  header.write_byte(0)
  header.write_byte(0)
  let query = Buffer(size_hint=header.to_bytes().length() + question.length())
  query.write_bytes(header.to_bytes())
  query.write_bytes(question)
  let query_bytes = query.to_bytes()
  let mut attempt = 0
  let mut delay_ms = 100
  while attempt <= self.retries {
    attempt = attempt + 1
    match self.transport.connect(self.server, self.port) {
      Ok(_) => ()
      Err(err) => return Err(TransportError(err))
    }
    let send_result = self.transport.send_to(
      query_bytes,
      self.server,
      self.port,
    )
    if send_result is Err(err) {
      return Err(TransportError(err))
    }
    let timeout_ms = if self.timeout_ms <= 0 { 5000 } else { self.timeout_ms }
    match self.transport.set_timeout(timeout_ms) {
      Ok(_) => ()
      Err(err) => return Err(TransportError(err))
    }
    let buffer = Buffer(size_hint=DNS_MAX_MESSAGE_SIZE)
    let recv_result = self.transport.receive_from(buffer)
    match recv_result {
      Ok(packet) => {
        if packet.address != self.server || packet.port != self.port {
          continue
        }
        let response_data = buffer.to_bytes()
        let response_bytes = response_data
          .exact_view(start=0, end=packet.length)
          .to_owned()
        match dns_parse_response(response_bytes) {
          Ok(response) => {
            if response.id != id {
              continue
            }
            let results : Array[Bytes] = []
            for answer in response.answers {
              if answer.typ == typ {
                if (typ == A && answer.data.length() == 4) ||
                  (typ == AAAA && answer.data.length() == 16) {
                  results.push(answer.data)
                }
              }
            }
            if results.length() == 0 {
              return Err(NoAnswer)
            }
            return Ok(@list.List(results))
          }
          Err(err) => return Err(err)
        }
      }
      Err(err) => {
        if attempt > self.retries {
          return Err(TransportError(err))
        }
        let end = @env.now() + delay_ms.to_uint64()
        while @env.now() < end {
          ()
        }
        delay_ms = delay_ms * 2
      }
    }
  }
  Err(Timeout)
}

///|
pub fn DnsResolver::resolve_a(
  self : DnsResolver,
  name : String,
) -> Result[List[String], DnsError] {
  let results = match self.query_one(name, A) {
    Ok(r) => r
    Err(err) => return Err(err)
  }
  let addresses : Array[String] = []
  for data in results {
    let ip = data[0].to_int().to_string() +
      "." +
      data[1].to_int().to_string() +
      "." +
      data[2].to_int().to_string() +
      "." +
      data[3].to_int().to_string()
    addresses.push(ip)
  }
  Ok(@list.List(addresses))
}

///|
pub fn DnsResolver::resolve_aaaa(
  self : DnsResolver,
  name : String,
) -> Result[List[String], DnsError] {
  let results = match self.query_one(name, AAAA) {
    Ok(r) => r
    Err(err) => return Err(err)
  }
  let addresses : Array[String] = []
  for data in results {
    let parts : Array[String] = []
    let mut i = 0
    while i < 16 {
      let word = (data[i].to_int() << 8) | data[i + 1].to_int()
      parts.push(word.to_string(radix=16))
      i = i + 2
    }
    addresses.push(parts.join(":"))
  }
  Ok(@list.List(addresses))
}

///|
pub fn DnsResolver::resolve(
  self : DnsResolver,
  name : String,
) -> Result[List[String], DnsError] {
  let a_results = match self.resolve_a(name) {
    Ok(r) => r
    Err(_) => @list.List([])
  }
  let aaaa_results = match self.resolve_aaaa(name) {
    Ok(r) => r
    Err(_) => @list.List([])
  }
  let combined : Array[String] = []
  for addr in a_results {
    combined.push(addr)
  }
  for addr in aaaa_results {
    combined.push(addr)
  }
  if combined.length() == 0 {
    Err(NoAnswer)
  } else {
    Ok(@list.List(combined))
  }
}
