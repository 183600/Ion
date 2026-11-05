///|
test "is_decimal_digits validates decimal strings" {
  assert_true(is_decimal_digits("0"))
  assert_true(is_decimal_digits("123"))
  assert_true(is_decimal_digits("0123"))
  assert_false(is_decimal_digits(""))
  assert_false(is_decimal_digits("12a"))
  assert_false(is_decimal_digits("12.3"))
  assert_false(is_decimal_digits("-123"))
}

///|
test "is_hex_digits validates hex strings" {
  assert_true(is_hex_digits("0"))
  assert_true(is_hex_digits("abc"))
  assert_true(is_hex_digits("ABC"))
  assert_true(is_hex_digits("1a2B3c"))
  assert_false(is_hex_digits(""))
  assert_false(is_hex_digits("12g"))
  assert_false(is_hex_digits("12.3"))
}

///|
test "is_unreserved_char matches RFC 3986 unreserved" {
  assert_true(is_unreserved_char('a'))
  assert_true(is_unreserved_char('Z'))
  assert_true(is_unreserved_char('0'))
  assert_true(is_unreserved_char('-'))
  assert_true(is_unreserved_char('.'))
  assert_true(is_unreserved_char('_'))
  assert_true(is_unreserved_char('~'))
  assert_false(is_unreserved_char('!'))
  assert_false(is_unreserved_char('@'))
  assert_false(is_unreserved_char(' '))
}

///|
test "is_sub_delim_char matches RFC 3986 sub-delims" {
  assert_true(is_sub_delim_char('!'))
  assert_true(is_sub_delim_char('$'))
  assert_true(is_sub_delim_char('&'))
  assert_true(is_sub_delim_char('\''))
  assert_true(is_sub_delim_char('('))
  assert_true(is_sub_delim_char(')'))
  assert_true(is_sub_delim_char('*'))
  assert_true(is_sub_delim_char('+'))
  assert_true(is_sub_delim_char(','))
  assert_true(is_sub_delim_char(';'))
  assert_true(is_sub_delim_char('='))
  assert_false(is_sub_delim_char('a'))
  assert_false(is_sub_delim_char(':'))
  assert_false(is_sub_delim_char('/'))
}

///|
test "is_hex_char identifies hex digits" {
  assert_true(is_hex_char('0'))
  assert_true(is_hex_char('9'))
  assert_true(is_hex_char('a'))
  assert_true(is_hex_char('f'))
  assert_true(is_hex_char('A'))
  assert_true(is_hex_char('F'))
  assert_false(is_hex_char('g'))
  assert_false(is_hex_char('G'))
  assert_false(is_hex_char(':'))
}

///|
test "hex_char_value returns correct values" {
  assert_eq(hex_char_value('0'), 0)
  assert_eq(hex_char_value('9'), 9)
  assert_eq(hex_char_value('a'), 10)
  assert_eq(hex_char_value('f'), 15)
  assert_eq(hex_char_value('A'), 10)
  assert_eq(hex_char_value('F'), 15)
  assert_eq(hex_char_value('g'), -1)
  assert_eq(hex_char_value(':'), -1)
}

///|
test "percent_decode_bytes decodes valid escapes" {
  assert_eq(percent_decode_bytes("hello%20world"), @utf8.encode("hello world"))
  assert_eq(percent_decode_bytes("%41%42%43"), @utf8.encode("ABC"))
  assert_eq(percent_decode_bytes("%2F"), @utf8.encode("/"))
  // Malformed escapes are left untouched
  assert_eq(percent_decode_bytes("%ZZ"), @utf8.encode("%ZZ"))
  assert_eq(percent_decode_bytes("%"), @utf8.encode("%"))
  assert_eq(percent_decode_bytes("%2"), @utf8.encode("%2"))
}

///|
test "is_numeric_dotted_host identifies dotted decimal hosts" {
  assert_true(is_numeric_dotted_host("1.2.3.4"))
  assert_true(is_numeric_dotted_host("192.168.0.1"))
  assert_true(is_numeric_dotted_host("0.0.0.0"))
  assert_true(is_numeric_dotted_host("255.255.255.255"))
  assert_true(is_numeric_dotted_host("01.02.03.04")) // leading zeros allowed (not validated)
  assert_true(is_numeric_dotted_host("1.2.3")) // only checks digits and dots
  assert_true(is_numeric_dotted_host("1.2.3.4.5")) // only checks digits and dots
  assert_true(is_numeric_dotted_host("1.2.3.")) // trailing dot allowed
  assert_true(is_numeric_dotted_host(".1.2.3")) // leading dot allowed
  assert_false(is_numeric_dotted_host(""))
  assert_false(is_numeric_dotted_host("a.b.c.d"))
}

///|
test "is_ipv4_literal validates IPv4 literals strictly" {
  assert_true(is_ipv4_literal("0.0.0.0"))
  assert_true(is_ipv4_literal("127.0.0.1"))
  assert_true(is_ipv4_literal("192.168.0.1"))
  assert_true(is_ipv4_literal("255.255.255.255"))
  // Leading zeros rejected
  assert_false(is_ipv4_literal("01.2.3.4"))
  assert_false(is_ipv4_literal("1.02.3.4"))
  // Out of range rejected
  assert_false(is_ipv4_literal("256.0.0.0"))
  assert_false(is_ipv4_literal("1.256.0.0"))
  // Wrong format
  assert_false(is_ipv4_literal(""))
  assert_false(is_ipv4_literal("1.2.3"))
  assert_false(is_ipv4_literal("1.2.3.4.5"))
  assert_false(is_ipv4_literal("a.b.c.d"))
}

///|
test "is_zone_id validates IPv6 zone identifiers" {
  assert_true(is_zone_id("eth0"))
  assert_true(is_zone_id("enp3s0"))
  assert_true(is_zone_id("1"))
  assert_true(is_zone_id("25eth0")) // percent-encoded percent sign
  assert_true(is_zone_id("%31"))   // percent-encoded '1'
  assert_false(is_zone_id(""))
  assert_false(is_zone_id(" "))
  assert_false(is_zone_id("eth%")) // incomplete percent encoding
  assert_false(is_zone_id("eth%GG")) // invalid hex
}

///|
test "is_ipv6_literal validates IPv6 literals" {
  assert_true(is_ipv6_literal("::1"))
  assert_true(is_ipv6_literal("::"))
  assert_true(is_ipv6_literal("fe80::1"))
  assert_true(is_ipv6_literal("2001:db8::1"))
  assert_true(is_ipv6_literal("::ffff:192.0.2.1")) // IPv4-mapped
  assert_true(is_ipv6_literal("2001:db8:0:0:0:0:0:1"))
  // Invalid
  assert_false(is_ipv6_literal(""))
  assert_false(is_ipv6_literal(":::1"))
  assert_false(is_ipv6_literal("2001:db8:::1"))
  assert_false(is_ipv6_literal("2001:db8:0:0:0:0:0:0:1")) // too many groups
  assert_false(is_ipv6_literal("gggg::1")) // invalid hex
}

///|
test "is_ipvfuture_literal validates IPvFuture literals" {
  assert_true(is_ipvfuture_literal("v1.foo"))
  assert_true(is_ipvfuture_literal("V1.foo"))
  assert_true(is_ipvfuture_literal("v12.abc-def"))
  assert_true(is_ipvfuture_literal("v1..foo")) // dot allowed in suffix
  assert_true(is_ipvfuture_literal("v1.foo.bar")) // multiple dots allowed
  assert_true(is_ipvfuture_literal("v1.g")) // 'g' is unreserved in suffix
  assert_false(is_ipvfuture_literal(""))
  assert_false(is_ipvfuture_literal("v1")) // no dot
  assert_false(is_ipvfuture_literal("v.foo")) // no version
  assert_false(is_ipvfuture_literal("x1.foo")) // doesn't start with v/V
  assert_false(is_ipvfuture_literal("v1.")) // empty suffix
  assert_false(is_ipvfuture_literal("vg.foo")) // 'g' not hex in version
}

///|
test "is_ipv6_literal_with_zone validates IPv6 with zone" {
  assert_true(is_ipv6_literal_with_zone("fe80::1%eth0"))
  assert_true(is_ipv6_literal_with_zone("fe80::1%25eth0")) // percent-encoded %
  assert_false(is_ipv6_literal_with_zone("[fe80::1%eth0]")) // bracketed not handled
  assert_false(is_ipv6_literal_with_zone(""))
  assert_false(is_ipv6_literal_with_zone("%eth0")) // no address
  assert_false(is_ipv6_literal_with_zone("fe80::1%")) // empty zone
  assert_false(is_ipv6_literal_with_zone("fe80::1%eth%")) // incomplete encoding
}

///|
test "is_ip_literal identifies IP literals" {
  assert_true(is_ip_literal("::1"))
  assert_true(is_ipv6_literal("fe80::1"))
  assert_true(is_ip_literal("v1.foo"))
  assert_false(is_ip_literal("[::1]")) // bracketed not handled
  assert_false(is_ip_literal("[fe80::1%eth0]")) // bracketed not handled
  assert_false(is_ip_literal("example.com"))
  assert_false(is_ip_literal("192.168.0.1")) // IPv4 not an IP literal in this context
}

///|
test "lowercase_host_preserving_zone lowercases host but preserves zone case" {
  assert_eq(lowercase_host_preserving_zone("EXAMPLE.COM"), "example.com")
  assert_eq(lowercase_host_preserving_zone("Example.Com"), "example.com")
  assert_eq(lowercase_host_preserving_zone("[::1]"), "[::1]")
  assert_eq(lowercase_host_preserving_zone("[FE80::1%ETH0]"), "[fe80::1%ETH0]")
  assert_eq(lowercase_host_preserving_zone("fe80::1%ETH0"), "fe80::1%ETH0")
  assert_eq(lowercase_host_preserving_zone("[v1.FOO]"), "[v1.foo]") // IPvFuture lowercased
  // Trailing dot preserved
  assert_eq(lowercase_host_preserving_zone("example.com."), "example.com.")
}