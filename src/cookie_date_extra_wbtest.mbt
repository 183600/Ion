test "cookie expiry consumes repeated time tokens" {
  let url = Url::parse("https://example.com/").unwrap()
  let expected = CookieJar::new()
  expected.store_at(
    url,
    "a=1; Expires=Wed, 21 Oct 2030 08:49:37 GMT; Path=/",
    0,
  )
  let with_extra_time = CookieJar::new()
  with_extra_time.store_at(
    url,
    "b=1; Expires=Wed, 07:28:00 21 Oct 2030 08:49:37 GMT; Path=/",
    0,
  )
  let expected_cookie = expected.cookies().nth(0).unwrap()
  let actual_cookie = with_extra_time.cookies().nth(0).unwrap()
  assert_eq(actual_cookie.expires_at_ms, expected_cookie.expires_at_ms)
}
