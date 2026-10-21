#cfg(target="native")
fn fuzz_read_file(path : String) -> String? {
  let capacity = 16 * 1024 * 1024
  let output = Bytes::new(capacity)
  let length = feather_read_file(@utf8.encode(path), output, capacity)
  if length < 0 {
    return None
  }
  Some(@utf8.decode_lossy(output.exact_view(start=0, end=length)))
}

#cfg(target="native")
fn fuzz_hex(text : String) -> Bytes {
  let out = Buffer(size_hint=text.length() / 2)
  let mut i = 0
  while i + 1 < text.length() {
    let hi = text.get_char(i).unwrap()
    let lo = text.get_char(i + 1).unwrap()
    let mut h = 0
    let mut l = 0
    if hi >= '0' && hi <= '9' { h = hi.to_int() - '0'.to_int() }
    else if hi >= 'a' && hi <= 'f' { h = hi.to_int() - 'a'.to_int() + 10 }
    else if hi >= 'A' && hi <= 'F' { h = hi.to_int() - 'A'.to_int() + 10 }
    if lo >= '0' && lo <= '9' { l = lo.to_int() - '0'.to_int() }
    else if lo >= 'a' && lo <= 'f' { l = lo.to_int() - 'a'.to_int() + 10 }
    else if lo >= 'A' && lo <= 'F' { l = lo.to_int() - 'A'.to_int() + 10 }
    out.write_byte((h * 16 + l).to_byte())
    i = i + 2
  }
  out.to_bytes()
}

#cfg(target="native")
test "inflate differential fuzz" {
  let text = match fuzz_read_file("/tmp/inflate_fuzz.txt") {
    Some(text) => text
    None => { assert_true(false); return }
  }
  let mut line_no = 0
  for line in text.split("\n") {
    if line.length() == 0 {
      continue
    }
    line_no = line_no + 1
    let parts = line.split("|").collect()
    if parts.length() != 3 {
      println("bad line " + line_no.to_string())
      assert_true(false)
    }
    let kind = parts[0].to_owned()
    let compressed = fuzz_hex(parts[1].to_owned())
    let expected = fuzz_hex(parts[2].to_owned())
    let decoded = match kind {
      "gzip" => gunzip(compressed, 1000000)
      "zlib" | "raw" => inflate(compressed, 1000000)
      _ => { println("bad kind " + kind); assert_true(false); continue }
    }
    match decoded {
      Ok(decoded) =>
        if decoded != expected {
          println("mismatch line " + line_no.to_string() + " kind " + kind +
            " got " + decoded.length().to_string() + " expected " + expected.length().to_string())
          assert_true(false)
        }
      Err(err) => {
        println("error line " + line_no.to_string() + " kind " + kind + " " + @debug.to_string(err))
        assert_true(false)
      }
    }
  }
  println("fuzz cases " + line_no.to_string())
}
