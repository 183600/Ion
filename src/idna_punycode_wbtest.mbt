test "Punycode encoding matches RFC 3492 sample vectors" {
  for (input, expected) in [
    ("bücher", "xn--bcher-kva"),
    ("ñandú", "xn--and-6ma2c"),
    ("3年b組金八先生", "xn--3b-ww4c5e180e575a65lsy2b"),
    ("他们为什么不说中文", "xn--ihqwcrb4cv8a8dqg056pqjye"),
    ("ليهمابتكلموشعربي؟", "xn--egbpdaj6bu4bxfgehfvwxn"),
  ] {
    assert_eq(idna_host_to_ascii(input), Some(expected))
  }
}

test "canonical A-labels with basic code points are accepted" {
  for host in [
    "xn--and-6ma2c.example",
    "xn--3b-ww4c5e180e575a65lsy2b.example",
    "xn--bcher-kva.example",
    "xn--ihqwcrb4cv8a8dqg056pqjye.example",
  ] {
    let url = Url::parse("http://" + host + "/").unwrap()
    assert_eq(url.host, host)
  }
}
