///|
test "IPv4 literals reject leading-zero octets" {
  for value in [
    "http://[::ffff:192.168.001.1]/",
    "http://[::ffff:01.2.3.4]/",
    "http://[::ffff:1.2.3.04]/",
  ] {
    assert_true(Url::parse(value) is Err(_))
  }
  for value in [
    "http://[::ffff:192.168.1.1]/",
    "http://[::ffff:0.0.0.0]/",
    "http://[::ffff:255.255.255.255]/",
  ] {
    assert_true(Url::parse(value) is Ok(_))
  }
}
