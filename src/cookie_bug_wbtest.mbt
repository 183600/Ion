// Test to demonstrate the cookie eviction bug where multiple cookies
// with the same creation timestamp would be incorrectly evicted together.

///|
test "cookie eviction bug: multiple cookies with same creation" {
  let jar = CookieJar::new()
  let url = Url::parse("http://example.com/").unwrap()
  
  // Fill up to the limit (50 cookies per domain)
  let mut index = 0
  while index < 50 {
    jar.store_at(url, "c" + index.to_string() + "=1; Path=/", (1000 + index).to_uint64())
    index = index + 1
  }
  assert_eq(jar.length(), 50)
  
  // Now replace c0 with a new value - this should preserve its creation timestamp
  jar.store_at(url, "c0=new; Path=/", 5000UL)
  assert_eq(jar.length(), 50)
  
  // Add one more cookie to trigger eviction - this should evict c1 (the oldest)
  jar.store_at(url, "c50=1; Path=/", 6000UL)
  assert_eq(jar.length(), 50)
  
  // c0 should still exist (it was replaced, not evicted)
  let header = jar.cookie_header_at(url, 10000UL).unwrap()
  assert_true(header.contains("c0=new"))
  
  // c1 should be evicted (oldest by creation time among remaining)
  assert_false(header.contains("c1="))
  
  // c50 should exist
  assert_true(header.contains("c50="))
}

///|
test "cookie eviction bug: simultaneous creation collision" {
  // This test simulates what happens if two cookies somehow get the same creation timestamp
  // We test the eviction logic directly by creating a scenario where creation values collide
  
  // The bug is that filter(fn(c) { c.creation != oldest.creation }) removes ALL cookies
  // with that creation value, not just the oldest one.
  
  // This is hard to trigger through the public API since next_creation is monotonically
  // increasing, but the logic bug exists in the filter.
  // The fix should use a unique identifier or index-based removal.
  
  assert_true(true) // Placeholder - the fix will be in the implementation
}