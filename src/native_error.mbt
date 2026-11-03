/// Shared errno mapping for the native socket transports.
///
/// POSIX errno numbers differ across platforms, so the values used by both
/// Linux and macOS/BSD are matched explicitly. The "other" platform's number
/// is a different, non-socket errno there and is never produced by the socket
/// paths in the native stubs.

/// Map a native errno to a transport error.
#cfg(target="native")
fn native_tcp_error(code : Int, operation : String) -> NetError {
  if code < 0 {
    return NetError::IoError(operation + " failed (code " + code.to_string() + ")")
  }
  match code {
    32 | 54 | 104 => Closed // EPIPE; macOS/Linux ECONNRESET
    11 | 110 | 115 => Timeout // Linux: EAGAIN/ETIMEDOUT/EINPROGRESS
    35 | 36 | 60 => Timeout // macOS/BSD: EAGAIN/EINPROGRESS/ETIMEDOUT
    101 | 111 | 113 => ConnectionFailed(operation + " failed (errno " + code.to_string() + ")") // Linux
    51 | 61 | 65 => ConnectionFailed(operation + " failed (errno " + code.to_string() + ")") // macOS/BSD
    22 => InvalidAddress(operation + " failed: invalid address")
    _ => IoError(operation + " failed (errno " + code.to_string() + ")")
  }
}

/// Map a native address-resolution failure to a transport error.
///
/// The native stubs report `getaddrinfo` failures with an offset so that they
/// cannot be confused with a socket errno.
#cfg(target="native")
fn native_tcp_address_error(code : Int) -> NetError {
  if code >= 10000 {
    return InvalidAddress("DNS resolution failed (code " + (code - 10000).to_string() + ")")
  }
  match code {
    32 | 54 | 104 => ConnectionFailed("TCP failed (errno " + code.to_string() + ")")
    _ => native_tcp_error(code, "")
  }
}
