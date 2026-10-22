///|
test "FEATHER_NO_PROXY list is split and trimmed" {
  let patterns = split_proxy_bypass(" example.com, ,api.example.net:8080,")
  assert_eq(patterns, ["example.com", "api.example.net:8080"])
  assert_eq(split_proxy_bypass(""), [])
}
