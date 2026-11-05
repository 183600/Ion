///|
test "idna_lowercase converts uppercase ASCII to lowercase" {
  assert_eq(idna_lowercase("EXAMPLE"), "example")
  assert_eq(idna_lowercase("Example.COM"), "example.com")
  assert_eq(idna_lowercase("EXAMPLE.COM"), "example.com")
  assert_eq(idna_lowercase("HTTP://EXAMPLE.COM/"), "http://example.com/")
}

///|
test "idna_lowercase leaves lowercase unchanged" {
  assert_eq(idna_lowercase("example"), "example")
  assert_eq(idna_lowercase("example.com"), "example.com")
  assert_eq(idna_lowercase("mixed-case"), "mixed-case")
}

///|
test "idna_lowercase handles Greek capital letters" {
  assert_eq(idna_lowercase("ΑΒΓΔΕΖΗΘ"), "αβγδεζηθ")
  assert_eq(idna_lowercase("ΑΒΓ.ΔΕΖ"), "αβγ.δεζ")
}

///|
test "idna_lowercase handles Russian Cyrillic capitals" {
  assert_eq(idna_lowercase("АБВГДЕЖ"), "абвгдеж")
  assert_eq(idna_lowercase("АБВГ.ДЕЖ"), "абвг.деж")
}

///|
test "idna_lowercase handles uppercase Korean Hangul" {
  assert_eq(idna_lowercase("안녕하세요"), "안녕하세요")
}

///|
test "idna_lowercase handles Greek sigma at word end" {
  assert_eq(idna_lowercase("Σ"), "σ")
  assert_eq(idna_lowercase("ΣΣ"), "σσ")
  assert_eq(idna_lowercase("TEST.Σ"), "test.σ")
}

///|
test "idna_lowercase handles Turkish dotted I (becomes i + combining dot)" {
  let lower = idna_lowercase("İ")
  assert_true(lower.has_prefix("i"))
}

///|
test "idna_lowercase leaves non-letter Unicode unchanged" {
  assert_eq(idna_lowercase("测试"), "测试")
  assert_eq(idna_lowercase("テスト"), "テスト")
}