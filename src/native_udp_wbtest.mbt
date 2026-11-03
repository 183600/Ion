///|
#cfg(target="native")
test "native UDP datagram round-trips a payload over loopback" {
  let datagram = NativeUdpDatagram::open().unwrap()
  let port = datagram.local_port()
  assert_true(port > 0)
  let payload = "hello udp"
  match datagram.send_to(@utf8.encode(payload), "127.0.0.1", port) {
    Ok(_) => ()
    Err(_) => {
      let _ = datagram.close()
      fail("the datagram could not be sent to the loopback address")
    }
  }
  let buffer = @buffer.new(size_hint=64)
  let packet = match datagram.receive_from(buffer) {
    Ok(packet) => packet
    Err(_) => {
      let _ = datagram.close()
      fail("the datagram was not received")
    }
  }
  assert_eq(packet.length, payload.length())
  assert_eq(packet.address, "127.0.0.1")
  assert_eq(packet.port, port)
  assert_eq(@utf8.decode_lossy(buffer.to_bytes()[:]), payload)
  let _ = datagram.close()
}

///|
#cfg(target="native")
test "native UDP datagram reports the sender of an unconnected datagram" {
  let sender = NativeUdpDatagram::open().unwrap()
  let receiver = NativeUdpDatagram::open().unwrap()
  let receiver_port = receiver.local_port()
  let sender_port = sender.local_port()
  assert_true(receiver_port > 0)
  assert_true(sender_port > 0)
  assert_true(sender_port != receiver_port)
  match sender.send_to(@utf8.encode("ping"), "127.0.0.1", receiver_port) {
    Ok(_) => ()
    Err(_) => {
      let _ = sender.close()
      let _ = receiver.close()
      fail("the datagram could not be sent to the loopback address")
    }
  }
  let buffer = @buffer.new(size_hint=64)
  let packet = match receiver.receive_from(buffer) {
    Ok(packet) => packet
    Err(_) => {
      let _ = sender.close()
      let _ = receiver.close()
      fail("the datagram was not received")
    }
  }
  assert_eq(@utf8.decode_lossy(buffer.to_bytes()[:]), "ping")
  assert_eq(packet.address, "127.0.0.1")
  assert_eq(packet.port, sender_port)
  let _ = sender.close()
  let _ = receiver.close()
}

///|
#cfg(target="native")
test "native UDP datagram accepts a connected peer" {
  let datagram = NativeUdpDatagram::open().unwrap()
  let port = datagram.local_port()
  match datagram.connect("127.0.0.1", port) {
    Ok(_) => ()
    Err(_) => {
      let _ = datagram.close()
      fail("the datagram socket could not connect to itself")
    }
  }
  match datagram.send_to(@utf8.encode("connected"), "127.0.0.1", port) {
    Ok(_) => ()
    Err(_) => {
      let _ = datagram.close()
      fail("a connected datagram could not be sent")
    }
  }
  let buffer = @buffer.new(size_hint=64)
  let packet = match datagram.receive_from(buffer) {
    Ok(packet) => packet
    Err(_) => {
      let _ = datagram.close()
      fail("the datagram was not received")
    }
  }
  assert_eq(@utf8.decode_lossy(buffer.to_bytes()[:]), "connected")
  assert_eq(packet.port, port)
  let _ = datagram.close()
}

///|
#cfg(target="native")
test "native UDP datagram rejects invalid ports and closed sockets" {
  let datagram = NativeUdpDatagram::open().unwrap()
  assert_true(
    datagram.send_to(@utf8.encode("x"), "127.0.0.1", 0) is
    Err(InvalidAddress(_)),
  )
  assert_true(
    datagram.connect("127.0.0.1", 70000) is Err(InvalidAddress(_)),
  )
  let _ = datagram.close()
  assert_true(datagram.send_to(@utf8.encode("x"), "127.0.0.1", 53) is Err(Closed))
  assert_true(datagram.receive_from(@buffer.new(size_hint=16)) is Err(Closed))
  assert_true(datagram.connect("127.0.0.1", 53) is Err(Closed))
  assert_true(datagram.set_timeout(10) is Err(Closed))
  assert_eq(datagram.local_port(), 0)
}

///|
#cfg(target="native")
test "native UDP datagram times out when no peer answers" {
  let datagram = NativeUdpDatagram::with_timeout(50).unwrap()
  // Port 1 on the loopback interface has no listener, so the receive blocks
  // until the socket deadline expires.
  let result = datagram.receive_from(@buffer.new(size_hint=64))
  assert_true(result is Err(Timeout))
  let _ = datagram.close()
}

///|
#cfg(target="native")
test "native UDP peer descriptions split into address and port" {
  assert_eq(native_udp_split_peer("1.2.3.4:53"), ("1.2.3.4", 53))
  assert_eq(native_udp_split_peer("[::1]:53"), ("::1", 53))
  assert_eq(native_udp_split_peer("[fe80::1%3]:5353"), ("fe80::1%3", 5353))
  assert_eq(native_udp_split_peer("127.0.0.1"), ("127.0.0.1", 0))
}
