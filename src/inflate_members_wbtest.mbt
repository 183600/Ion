fn gzip_member_ints(ints : Array[Int]) -> Bytes {
  let output = Buffer(size_hint=ints.length())
  for value in ints {
    output.write_byte(value.to_byte())
  }
  output.to_bytes()
}

/// A gzip payload may contain many concatenated members. Decoding each member
/// must continue from a view of the remaining input rather than copying the
/// whole tail every time; this exercises a long member chain and confirms the
/// offsets are still tracked correctly.
test "gzip decodes a long concatenated member chain" {
  // Minimal empty member produced by a standard gzip encoder.
  let empty = gzip_member_ints([
    31, 139, 8, 0, 0, 0, 0, 0, 2, 3, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  ])
  // Final member carrying "done".
  let done = gzip_member_ints([
    31, 139, 8, 0, 0, 0, 0, 0, 2, 3, 75, 201, 207, 75, 5, 0, 171, 224, 45,
    16, 4, 0, 0, 0,
  ])
  let input = Buffer(size_hint=empty.length() * 20000 + done.length())
  let mut index = 0
  while index < 20000 {
    input.write_bytes(empty)
    index = index + 1
  }
  input.write_bytes(done)
  assert_eq(gunzip(input.to_bytes(), 16).unwrap(), b"done")
}
