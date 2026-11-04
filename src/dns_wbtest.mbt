///|
/// Outcomes queued on the mock datagram: each `receive_from` consumes one.
enum DnsMockReply {
  Packet(Bytes, String, Int32)
  Fail(NetError)
  /// Build the payload at receive time; the argument is the transaction id
  /// taken from the query the resolver last sent.
  Respond((Int32) -> (Bytes, String, Int32))
}

///|
/// In-memory datagram transport recording everything the resolver does.
struct DnsMockDatagram {
  mut connect_calls : Int32
  mut connect_address : String
  mut connect_port : Int32
  mut connect_error : NetError?
  sent_queries : Array[Bytes]
  sent_targets : Array[String]
  sent_ports : Array[Int32]
  timeouts : Array[Int32]
  replies : Array[DnsMockReply]
  mut reply_index : Int32
}

///|
fn DnsMockDatagram::new() -> DnsMockDatagram {
  DnsMockDatagram::{
    connect_calls: 0,
    connect_address: "",
    connect_port: 0,
    connect_error: None,
    sent_queries: [],
    sent_targets: [],
    sent_ports: [],
    timeouts: [],
    replies: [],
    reply_index: 0,
  }
}

///|
fn DnsMockDatagram::queue(
  self : DnsMockDatagram,
  payload : Bytes,
  address : String,
  port : Int32,
) -> Unit {
  self.replies.push(Packet(payload, address, port))
}

///|
/// Queue a reply built from the transaction id of the outgoing query. The
/// answer arrives from the same address and port the query was sent to.
fn DnsMockDatagram::queue_response(
  self : DnsMockDatagram,
  build : (Int32) -> Bytes,
) -> Unit {
  let transport = self
  self.replies.push(
    Respond(fn(id) {
      let port = transport.sent_ports[transport.sent_ports.length() - 1]
      (build(id), DNS_MOCK_SERVER, port)
    }),
  )
}

///|
fn DnsMockDatagram::queue_failure(self : DnsMockDatagram, error : NetError) -> Unit {
  self.replies.push(Fail(error))
}

///|
fn DnsMockDatagram::last_query_id(self : DnsMockDatagram) -> Int32 {
  let query = self.sent_queries[self.sent_queries.length() - 1]
  (query[0].to_int() << 8) | query[1].to_int()
}

///|
impl Datagram for DnsMockDatagram with fn send_to(
  self,
  payload : Bytes,
  address : String,
  port : Int32,
) -> Result[Unit, NetError] {
  self.sent_queries.push(payload)
  self.sent_targets.push(address + ":" + port.to_string())
  self.sent_ports.push(port)
  Ok(())
}

///|
impl Datagram for DnsMockDatagram with fn receive_from(
  self,
  buffer : Buffer,
) -> Result[DatagramPacket, NetError] {
  if self.reply_index >= self.replies.length() {
    return Err(NetError::Timeout)
  }
  match self.replies[self.reply_index] {
    Packet(payload, address, port) => {
      self.reply_index = self.reply_index + 1
      buffer.write_bytes(payload)
      Ok(DatagramPacket::{ length: payload.length(), address, port })
    }
    Fail(error) => {
      self.reply_index = self.reply_index + 1
      Err(error)
    }
    Respond(build) => {
      self.reply_index = self.reply_index + 1
      let (payload, address, port) = build(self.last_query_id())
      buffer.write_bytes(payload)
      Ok(DatagramPacket::{ length: payload.length(), address, port })
    }
  }
}

///|
impl Datagram for DnsMockDatagram with fn connect(
  self,
  address : String,
  port : Int32,
) -> Result[Unit, NetError] {
  self.connect_calls = self.connect_calls + 1
  self.connect_address = address
  self.connect_port = port
  match self.connect_error {
    Some(error) => Err(error)
    None => Ok(())
  }
}

///|
impl Datagram for DnsMockDatagram with fn set_timeout(
  self,
  timeout_ms : Int32,
) -> Result[Unit, NetError] {
  self.timeouts.push(timeout_ms)
  Ok(())
}

///|
impl Datagram for DnsMockDatagram with fn close(
  _self : DnsMockDatagram,
) -> Result[Unit, NetError] {
  Ok(())
}

///|
const DNS_MOCK_SERVER : String = "192.0.2.53"

///|
fn dns_mock_resolver(transport : DnsMockDatagram) -> DnsResolver {
  DnsResolver::new(transport, DNS_MOCK_SERVER)
}

///|
/// Encoded wire form of "example.com" (labels + root).
fn dns_example_com_name() -> Bytes {
  b"\x07example\x03com\x00"
}

///|
fn dns_write_name(out : Buffer, name : String) -> Unit {
  for label in name.split(".") {
    out.write_byte(label.length().to_byte())
    out.write_bytes(@utf8.encode(label))
  }
  out.write_byte(0)
}

///|
/// Build a QR=1 response with one echoed A question for `name`, the supplied
/// answer-section records, and the given transaction id.
fn dns_build_response(
  id : Int32,
  name : String,
  rcode : Int32,
  answers : Array[Bytes],
) -> Bytes {
  let out = Buffer(size_hint=128)
  out.write_byte(((id >> 8) & 0xFF).to_byte())
  out.write_byte((id & 0xFF).to_byte())
  out.write_byte(0x80) // QR = 1, opcode 0, AA/TC/RD clear
  out.write_byte((rcode & 0xF).to_byte())
  out.write_byte(0)
  out.write_byte(1) // QDCOUNT = 1
  out.write_byte(0)
  out.write_byte(answers.length().to_byte()) // ANCOUNT
  out.write_byte(0) // NSCOUNT = 0
  out.write_byte(0)
  out.write_byte(0) // ARCOUNT = 0
  out.write_byte(0)
  dns_write_name(out, name)
  out.write_byte(0)
  out.write_byte(1) // QTYPE = A
  out.write_byte(0)
  out.write_byte(1) // QCLASS = IN
  for answer in answers {
    out.write_bytes(answer)
  }
  out.to_bytes()
}

///|
/// One resource record with the given name, type, TTL, and rdata.
fn dns_record(name : String, typ : Int32, ttl : Int32, rdata : Bytes) -> Bytes {
  let out = Buffer(size_hint=32)
  dns_write_name(out, name)
  out.write_byte(((typ >> 8) & 0xFF).to_byte())
  out.write_byte((typ & 0xFF).to_byte())
  out.write_byte(0)
  out.write_byte(1) // CLASS = IN
  out.write_byte(((ttl >> 24) & 0xFF).to_byte())
  out.write_byte(((ttl >> 16) & 0xFF).to_byte())
  out.write_byte(((ttl >> 8) & 0xFF).to_byte())
  out.write_byte((ttl & 0xFF).to_byte())
  out.write_byte(((rdata.length() >> 8) & 0xFF).to_byte())
  out.write_byte((rdata.length() & 0xFF).to_byte())
  out.write_bytes(rdata)
  out.to_bytes()
}

///|
/// A resource record whose name is a compression pointer to the question at
/// offset 12 (the first name in a standard one-question message).
fn dns_pointed_record(typ : Int32, ttl : Int32, rdata : Bytes) -> Bytes {
  let out = Buffer(size_hint=32)
  out.write_byte(0xC0)
  out.write_byte(0x0C)
  out.write_byte(((typ >> 8) & 0xFF).to_byte())
  out.write_byte((typ & 0xFF).to_byte())
  out.write_byte(0)
  out.write_byte(1) // CLASS = IN
  out.write_byte(((ttl >> 24) & 0xFF).to_byte())
  out.write_byte(((ttl >> 16) & 0xFF).to_byte())
  out.write_byte(((ttl >> 8) & 0xFF).to_byte())
  out.write_byte((ttl & 0xFF).to_byte())
  out.write_byte(((rdata.length() >> 8) & 0xFF).to_byte())
  out.write_byte((rdata.length() & 0xFF).to_byte())
  out.write_bytes(rdata)
  out.to_bytes()
}

///|
test "dns query puts the question on the wire with RD and IN class" {
  let transport = DnsMockDatagram::new()
  transport.queue_response(fn(id) { dns_build_response(id, "example.com", 0, []) })
  let resolver = dns_mock_resolver(transport)
  // The queued response carries no A record, so resolution reports NoAnswer;
  // the assertions below inspect the query the resolver sent.
  assert_true(resolver.resolve_a("example.com") is Err(NoAnswer))
  assert_eq(transport.connect_calls, 1)
  assert_eq(transport.connect_address, DNS_MOCK_SERVER)
  assert_eq(transport.connect_port, 53)
  assert_eq(transport.sent_queries.length(), 1)
  assert_eq(transport.sent_targets[0], DNS_MOCK_SERVER + ":53")
  assert_eq(transport.timeouts, [5000])
  let query = transport.sent_queries[0]
  assert_eq((query[2].to_int() << 8) | query[3].to_int(), 0x0100) // RD set
  assert_eq((query[4].to_int() << 8) | query[5].to_int(), 1) // QDCOUNT = 1
  assert_eq((query[6].to_int() << 8) | query[7].to_int(), 0) // ANCOUNT = 0
  assert_eq((query[8].to_int() << 8) | query[9].to_int(), 0) // NSCOUNT = 0
  assert_eq((query[10].to_int() << 8) | query[11].to_int(), 0) // ARCOUNT = 0
  let name = dns_example_com_name()
  let mut i = 0
  while i < name.length() {
    assert_eq(query[12 + i].to_int(), name[i].to_int())
    i = i + 1
  }
  let question_end = 12 + name.length()
  assert_eq(query[question_end].to_int(), 0) // QTYPE = A
  assert_eq(query[question_end + 1].to_int(), 1)
  assert_eq(query[question_end + 2].to_int(), 0) // QCLASS = IN
  assert_eq(query[question_end + 3].to_int(), 1)
}

///|
test "dns resolver parses A answers behind a CNAME chain" {
  let transport = DnsMockDatagram::new()
  // The answer section holds a CNAME whose rdata is a pointer to the question
  // name, followed by the actual A record: the resolver must skip the CNAME
  // instead of failing the whole response.
  let cname = dns_pointed_record(5, 600, b"\xc0\x0c")
  let address = dns_pointed_record(1, 3600, b"\x5d\xb8\xd8\x22")
  transport.queue_response(fn(id) {
    dns_build_response(id, "example.com", 0, [cname, address])
  })
  let resolver = dns_mock_resolver(transport)
  let result = resolver.resolve_a("example.com")
  assert_true(
    result is Ok(addresses) && addresses == @list.List(["93.184.216.34"]),
  )
}

///|
test "dns resolver returns every A record in answer order" {
  let transport = DnsMockDatagram::new()
  let first = dns_pointed_record(1, 300, b"\x01\x02\x03\x04")
  let second = dns_record("example.com", 1, 300, b"\x05\x06\x07\x08")
  transport.queue_response(fn(id) {
    dns_build_response(id, "example.com", 0, [first, second])
  })
  let resolver = dns_mock_resolver(transport)
  let result = resolver.resolve_a("example.com")
  assert_true(
    result is Ok(addresses) &&
    addresses == @list.List(["1.2.3.4", "5.6.7.8"]),
  )
}

///|
test "dns resolver decodes AAAA records" {
  let transport = DnsMockDatagram::new()
  let record = dns_pointed_record(
    28,
    7200,
    b"\x20\x01\x0d\xb8\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01",
  )
  transport.queue_response(fn(id) {
    dns_build_response(id, "example.com", 0, [record])
  })
  let resolver = dns_mock_resolver(transport)
  let result = resolver.resolve_aaaa("example.com")
  assert_true(
    result is Ok(addresses) &&
    addresses == @list.List(["2001:db8:0:0:0:0:0:1"]),
  )
}

///|
test "dns resolver skips delegation and EDNS records in trailing sections" {
  let transport = DnsMockDatagram::new()
  let answer = dns_pointed_record(1, 60, b"\xc0\x00\x02\x01")
  // An NS record in the authority section and an OPT (EDNS0) pseudo-record in
  // the additional section must both parse without aborting the response.
  let authority = dns_record("example.com", 2, 86400, b"\xc0\x0c")
  let opt = Buffer(size_hint=16)
  opt.write_byte(0) // root name
  opt.write_byte(0)
  opt.write_byte(41) // OPT
  opt.write_byte(0)
  opt.write_byte(0)
  opt.write_byte(0)
  opt.write_byte(0)
  opt.write_byte(0)
  opt.write_byte(0)
  opt.write_byte(0)
  opt.write_byte(0) // rdlength = 0
  transport.queue_response(fn(id) {
    let out = Buffer(size_hint=128)
    out.write_bytes(dns_build_response(id, "example.com", 0, [answer]))
    out.write_bytes(authority)
    out.write_bytes(opt.to_bytes())
    out.to_bytes()
  })
  let resolver = dns_mock_resolver(transport)
  let result = resolver.resolve_a("example.com")
  assert_true(result is Ok(addresses) && addresses == @list.List(["192.0.2.1"]))
}

///|
test "dns resolver maps rcodes to distinct errors" {
  let rcodes = [(2, ServerFailure), (3, NameError), (4, NotImplemented), (5, Refused)]
  for pair in rcodes {
    let (rcode, expected) = pair
    let transport = DnsMockDatagram::new()
    transport.queue_response(fn(id) {
      dns_build_response(id, "example.com", rcode, [])
    })
    let resolver = dns_mock_resolver(transport)
    assert_true(resolver.resolve_a("example.com") is Err(error) && error == expected)
  }
}

///|
test "dns resolver ignores replies from a different source" {
  let transport = DnsMockDatagram::new()
  let record = dns_pointed_record(1, 60, b"\x5d\xb8\xd8\x22")
  transport.queue(
    dns_build_response(0x1234, "example.com", 0, [record]),
    "203.0.113.9",
    53,
  )
  let resolver = DnsResolver::new(transport, DNS_MOCK_SERVER).with_retries(0)
  assert_true(resolver.resolve_a("example.com") is Err(Timeout))
}

///|
test "dns resolver ignores replies with a mismatched transaction id" {
  let transport = DnsMockDatagram::new()
  let record = dns_pointed_record(1, 60, b"\x5d\xb8\xd8\x22")
  transport.queue_response(fn(id) {
    dns_build_response((id + 1) & 0xFFFF, "example.com", 0, [record])
  })
  let resolver = DnsResolver::new(transport, DNS_MOCK_SERVER).with_retries(0)
  assert_true(resolver.resolve_a("example.com") is Err(Timeout))
}

///|
test "dns resolver retries after a transient receive failure" {
  let transport = DnsMockDatagram::new()
  transport.queue_failure(NetError::Timeout)
  let record = dns_pointed_record(1, 60, b"\x5d\xb8\xd8\x22")
  transport.queue_response(fn(id) {
    dns_build_response(id, "example.com", 0, [record])
  })
  let resolver = DnsResolver::new(transport, DNS_MOCK_SERVER).with_retries(1)
  let result = resolver.resolve_a("example.com")
  assert_true(
    result is Ok(addresses) && addresses == @list.List(["93.184.216.34"]),
  )
  assert_eq(transport.sent_queries.length(), 2)
  assert_eq(transport.timeouts, [5000, 5000])
}

///|
test "dns resolver wraps transport connect failures" {
  let transport = DnsMockDatagram::new()
  transport.connect_error = Some(NetError::IoError("no route to host"))
  let resolver = dns_mock_resolver(transport)
  assert_true(
    resolver.resolve_a("example.com")
    is Err(TransportError(NetError::IoError("no route to host"))),
  )
  assert_eq(transport.sent_queries.length(), 0)
}

///|
test "dns resolver combines A then AAAA results" {
  let transport = DnsMockDatagram::new()
  let v4 = dns_pointed_record(1, 60, b"\x01\x02\x03\x04")
  let v6 = dns_pointed_record(
    28,
    60,
    b"\x20\x01\x0d\xb8\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01",
  )
  transport.queue_response(fn(id) {
    dns_build_response(id, "example.com", 0, [v4])
  })
  transport.queue_response(fn(id) {
    dns_build_response(id, "example.com", 0, [v6])
  })
  let resolver = dns_mock_resolver(transport)
  let result = resolver.resolve("example.com")
  assert_true(
    result is Ok(addresses) &&
    addresses == @list.List(["1.2.3.4", "2001:db8:0:0:0:0:0:1"]),
  )
  // Both queries hit the transport independently.
  assert_eq(transport.sent_queries.length(), 2)
}

///|
test "dns resolver reports NoAnswer when no family resolves" {
  let transport = DnsMockDatagram::new()
  transport.queue_response(fn(id) { dns_build_response(id, "example.com", 0, []) })
  transport.queue_response(fn(id) { dns_build_response(id, "example.com", 0, []) })
  let resolver = dns_mock_resolver(transport)
  assert_true(resolver.resolve("example.com") is Err(NoAnswer))
}

///|
test "dns resolver keeps the default port unless a valid one is set" {
  let transport = DnsMockDatagram::new()
  transport.queue_response(fn(id) { dns_build_response(id, "example.com", 0, []) })
  let resolver = DnsResolver::new(transport, DNS_MOCK_SERVER).with_port(7053)
  assert_true(resolver.resolve_a("example.com") is Err(NoAnswer))
  assert_eq(transport.connect_port, 7053)
  assert_eq(transport.sent_targets[0], DNS_MOCK_SERVER + ":7053")

  let fallback = DnsMockDatagram::new()
  fallback.queue_response(fn(id) { dns_build_response(id, "example.com", 0, []) })
  let resolver = DnsResolver::new(fallback, DNS_MOCK_SERVER).with_port(0)
  assert_true(resolver.resolve_a("example.com") is Err(NoAnswer))
  assert_eq(fallback.connect_port, 53)
}

///|
test "dns response parser rejects malformed packets" {
  // Shorter than the fixed 12-byte header.
  assert_true(dns_parse_response(b"\x00\x00") is Err(MalformedResponse))
  // A packet that is a query (QR = 0), not a response.
  let query = dns_build_response(1, "example.com", 0, [])
  let flipped = Buffer(size_hint=query.length())
  flipped.write_byte(query[0])
  flipped.write_byte(query[1])
  flipped.write_byte(0x00) // QR = 0
  flipped.write_byte(query[3])
  flipped.write_bytes(query[4:query.length()].to_bytes())
  assert_true(dns_parse_response(flipped.to_bytes()) is Err(MalformedResponse))
  // FORMERR (rcode 1) surfaces as a server failure.
  assert_true(
    dns_parse_response(dns_build_response(1, "example.com", 1, []))
    is Err(ServerFailure),
  )
  // An answer whose rdata claims to extend past the end of the packet.
  let overlong = Buffer(size_hint=16)
  overlong.write_byte(0xC0)
  overlong.write_byte(0x0C)
  overlong.write_byte(0)
  overlong.write_byte(1) // A
  overlong.write_byte(0)
  overlong.write_byte(1)
  overlong.write_byte(0)
  overlong.write_byte(0)
  overlong.write_byte(0)
  overlong.write_byte(60)
  overlong.write_byte(0)
  overlong.write_byte(16) // rdlength = 16 but no rdata bytes follow
  assert_true(
    dns_parse_response(
      dns_build_response(1, "example.com", 0, [overlong.to_bytes()]),
    )
    is Err(MalformedResponse),
  )
  // A pointer that jumps past the end of the packet.
  let dangling = Buffer(size_hint=16)
  dangling.write_byte(0xC0)
  dangling.write_byte(0xF0)
  dangling.write_byte(0)
  dangling.write_byte(1)
  dangling.write_byte(0)
  dangling.write_byte(1)
  dangling.write_byte(0)
  dangling.write_byte(0)
  dangling.write_byte(0)
  dangling.write_byte(60)
  dangling.write_byte(0)
  dangling.write_byte(4)
  dangling.write_byte(1)
  dangling.write_byte(2)
  dangling.write_byte(3)
  dangling.write_byte(4)
  assert_true(
    dns_parse_response(
      dns_build_response(1, "example.com", 0, [dangling.to_bytes()]),
    )
    is Err(MalformedResponse),
  )
}

///|
test "dns response parser keeps compressed names and unknown rr types" {
  let cname = dns_pointed_record(5, 600, b"\xc0\x0c")
  let address = dns_pointed_record(1, 3600, b"\x5d\xb8\xd8\x22")
  let response = dns_build_response(1, "example.com", 0, [cname, address])
  let parsed = dns_parse_response(response).unwrap()
  assert_eq(parsed.id, 1)
  assert_eq(parsed.response_code, 0)
  assert_eq(parsed.questions.length(), 1)
  let question = parsed.questions.nth(0).unwrap()
  assert_eq(question.name, "example.com")
  assert_eq(parsed.answers.length(), 2)
  let cname_record = parsed.answers.nth(0).unwrap()
  assert_eq(cname_record.name, "example.com")
  assert_eq(cname_record.typ, Other(5))
  assert_eq(DnsRecordType::code(cname_record.typ), 5)
  assert_eq(cname_record.ttl, 600)
  let address_record = parsed.answers.nth(1).unwrap()
  assert_eq(address_record.typ, A)
  assert_eq(address_record.ttl, 3600)
  assert_eq(address_record.data.length(), 4)
}

///|
test "dns name encoder rejects invalid labels and oversized names" {
  assert_eq(dns_name_encode("example.com").unwrap(), dns_example_com_name())
  assert_true(dns_name_encode("") is Err(InvalidName))
  assert_true(dns_name_encode(".") is Err(InvalidName))
  assert_true(dns_name_encode("example..com") is Err(InvalidName))
  let long_label = Buffer(size_hint=64)
  let mut i = 0
  while i < 64 {
    long_label.write_byte(b'a')
    i = i + 1
  }
  assert_true(
    dns_name_encode(@utf8.decode_lossy(long_label.to_bytes()[:])) is Err(InvalidName),
  )
  let long_name = Buffer(size_hint=260)
  let mut j = 0
  while j < 256 {
    long_name.write_byte(b'a')
    j = j + 1
  }
  long_name.write_byte(b'.')
  long_name.write_byte(b'c')
  long_name.write_byte(b'o')
  long_name.write_byte(b'm')
  assert_true(
    dns_name_encode(@utf8.decode_lossy(long_name.to_bytes()[:])) is Err(InvalidName),
  )
}
