#include <moonbit.h>

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#define FEATHER_GAI_BASE 10000

// Copy a borrowed MoonBit byte string into a NUL-terminated C buffer.
static int32_t feather_udp_copy_host(moonbit_bytes_t host, char *out, int32_t capacity) {
  int32_t length = Moonbit_array_length(host);
  if (length <= 0 || length >= capacity) {
    return -EINVAL;
  }
  if (memchr(host, '\0', (size_t)length) != NULL) {
    return -EINVAL;
  }
  memcpy(out, host, (size_t)length);
  out[length] = '\0';
  return length;
}

// The address family of the socket, so that IPv4 destinations can be mapped
// onto a dual-stack IPv6 socket.
static int feather_udp_socket_family(int32_t fd) {
  struct sockaddr_storage addr;
  socklen_t length = sizeof(addr);
  if (getsockname(fd, (struct sockaddr *)&addr, &length) < 0) {
    return -1;
  }
  return (int)addr.ss_family;
}

static int feather_udp_resolve(const char *host, int port, struct sockaddr_storage *out, socklen_t *out_len) {
  char service[16];
  snprintf(service, sizeof(service), "%d", port);

  struct addrinfo hints;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_DGRAM;
  hints.ai_protocol = IPPROTO_UDP;

  struct addrinfo *result = NULL;
  int gai = getaddrinfo(host, service, &hints, &result);
  if (gai != 0) {
    int code = gai < 0 ? -gai : gai;
    return -(FEATHER_GAI_BASE + code);
  }
  memcpy(out, result->ai_addr, result->ai_addrlen);
  *out_len = result->ai_addrlen;
  freeaddrinfo(result);
  return 0;
}

// Build the destination address for `host:port`, matching the socket family.
// An IPv4 destination on a dual-stack socket is mapped to ::ffff:a.b.c.d.
static int feather_udp_target(int32_t fd, const char *host, int port, struct sockaddr_storage *out, socklen_t *out_len) {
  struct sockaddr_storage addr;
  socklen_t addr_len = 0;
  int result = feather_udp_resolve(host, port, &addr, &addr_len);
  if (result != 0) {
    return result;
  }
  int family = feather_udp_socket_family(fd);
  if (family < 0) {
    return -errno;
  }
  if (family == AF_INET6 && addr.ss_family == AF_INET) {
    struct sockaddr_in6 mapped;
    memset(&mapped, 0, sizeof(mapped));
    struct sockaddr_in *in = (struct sockaddr_in *)&addr;
    mapped.sin6_family = AF_INET6;
    mapped.sin6_port = in->sin_port;
    uint8_t *bytes = (uint8_t *)&mapped.sin6_addr;
    bytes[10] = 0xff;
    bytes[11] = 0xff;
    memcpy(bytes + 12, &in->sin_addr, 4);
    memcpy(out, &mapped, sizeof(mapped));
    *out_len = sizeof(mapped);
    return 0;
  }
  if (addr.ss_family != family) {
    return -EAFNOSUPPORT;
  }
  memcpy(out, &addr, addr_len);
  *out_len = addr_len;
  return 0;
}

static int feather_udp_set_timeout(int fd, int32_t timeout_ms) {
  struct timeval tv;
  if (timeout_ms <= 0) {
    tv.tv_sec = 0;
    tv.tv_usec = 0;
  } else {
    tv.tv_sec = timeout_ms / 1000;
    tv.tv_usec = (timeout_ms % 1000) * 1000;
  }
  if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)) < 0) {
    return -errno;
  }
  if (setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv)) < 0) {
    return -errno;
  }
  return 0;
}

MOONBIT_FFI_EXPORT
int32_t feather_udp_open(void) {
  // Prefer a dual-stack socket so that both IPv4 and IPv6 peers are reachable
  // from the same descriptor. Hosts without IPv6 fall back to IPv4 only.
  int fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP);
  if (fd >= 0) {
    int off = 0;
    if (setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, sizeof(off)) == 0) {
      return fd;
    }
    close(fd);
  }
  fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
  if (fd < 0) {
    return -errno;
  }
  return fd;
}

MOONBIT_FFI_EXPORT
int32_t feather_udp_connect(int32_t fd, moonbit_bytes_t host, int32_t port) {
  if (fd < 0) {
    return -EBADF;
  }
  if (port < 1 || port > 65535) {
    return -EINVAL;
  }
  char name[1024];
  int32_t length = feather_udp_copy_host(host, name, (int32_t)sizeof(name));
  if (length < 0) {
    return length;
  }
  struct sockaddr_storage addr;
  socklen_t addr_len = 0;
  int result = feather_udp_target(fd, name, port, &addr, &addr_len);
  if (result != 0) {
    return result;
  }
  if (connect(fd, (struct sockaddr *)&addr, addr_len) < 0) {
    return -errno;
  }
  return 0;
}

MOONBIT_FFI_EXPORT
int32_t feather_udp_send_to(int32_t fd, moonbit_bytes_t payload, int32_t length, moonbit_bytes_t host, int32_t port) {
  if (fd < 0) {
    return -EBADF;
  }
  if (length < 0 || length > Moonbit_array_length(payload)) {
    return -EINVAL;
  }
  if (port < 1 || port > 65535) {
    return -EINVAL;
  }
  char name[1024];
  int32_t copied = feather_udp_copy_host(host, name, (int32_t)sizeof(name));
  if (copied < 0) {
    return copied;
  }
  struct sockaddr_storage addr;
  socklen_t addr_len = 0;
  int result = feather_udp_target(fd, name, port, &addr, &addr_len);
  if (result != 0) {
    return result;
  }
  ssize_t sent = sendto(fd, payload, (size_t)length, 0, (struct sockaddr *)&addr, addr_len);
  if (sent < 0) {
    return -errno;
  }
  return (int32_t)sent;
}

// Receive one datagram and report the sender as a NUL-terminated "host:port"
// string, with IPv6 literals bracketed.
MOONBIT_FFI_EXPORT
int32_t feather_udp_recv_from(int32_t fd, moonbit_bytes_t buffer, int32_t capacity, moonbit_bytes_t output, int32_t output_capacity) {
  if (fd < 0) {
    return -EBADF;
  }
  if (capacity < 0 || capacity > Moonbit_array_length(buffer)) {
    return -EINVAL;
  }
  if (output_capacity < 2 || output_capacity > Moonbit_array_length(output)) {
    return -EINVAL;
  }
  struct sockaddr_storage addr;
  socklen_t addr_len = sizeof(addr);
  ssize_t received = recvfrom(fd, buffer, (size_t)capacity, 0, (struct sockaddr *)&addr, &addr_len);
  if (received < 0) {
    return -errno;
  }

  const void *address = NULL;
  int port = 0;
  int ipv6 = 0;
  unsigned int scope_id = 0;
  if (addr.ss_family == AF_INET) {
    struct sockaddr_in *inet = (struct sockaddr_in *)&addr;
    address = &inet->sin_addr;
    port = ntohs(inet->sin_port);
  } else if (addr.ss_family == AF_INET6) {
    struct sockaddr_in6 *inet6 = (struct sockaddr_in6 *)&addr;
    address = &inet6->sin6_addr;
    port = ntohs(inet6->sin6_port);
    ipv6 = 1;
    scope_id = inet6->sin6_scope_id;
  } else {
    return -EAFNOSUPPORT;
  }

  char host[INET6_ADDRSTRLEN];
  if (inet_ntop(addr.ss_family, address, host, sizeof(host)) == NULL) {
    return -errno;
  }
  char text[INET6_ADDRSTRLEN + 32];
  int written;
  if (ipv6 && scope_id != 0) {
    written = snprintf(text, sizeof(text), "[%s%%%u]:%d", host, scope_id, port);
  } else {
    written = snprintf(text, sizeof(text), ipv6 ? "[%s]:%d" : "%s:%d", host, port);
  }
  if (written < 0 || written >= (int)sizeof(text)) {
    return -EIO;
  }
  // The peer string plus its terminator must fit in the caller's buffer.
  if (written + 1 > output_capacity) {
    return -ENOSPC;
  }
  memcpy(output, text, (size_t)written);
  output[written] = '\0';
  return (int32_t)received;
}

MOONBIT_FFI_EXPORT
int32_t feather_udp_set_timeout(int32_t fd, int32_t timeout_ms) {
  if (fd < 0) {
    return -EBADF;
  }
  return feather_udp_set_timeout(fd, timeout_ms);
}

MOONBIT_FFI_EXPORT
int32_t feather_udp_close(int32_t fd) {
  if (fd < 0) {
    return 0;
  }
  if (close(fd) < 0) {
    return -errno;
  }
  return 0;
}

MOONBIT_FFI_EXPORT
int32_t feather_udp_local_port(int32_t fd) {
  if (fd < 0) {
    return -EBADF;
  }
  struct sockaddr_storage addr;
  socklen_t length = sizeof(addr);
  if (getsockname(fd, (struct sockaddr *)&addr, &length) < 0) {
    return -errno;
  }
  if (addr.ss_family == AF_INET) {
    return ntohs(((struct sockaddr_in *)&addr)->sin_port);
  }
  if (addr.ss_family == AF_INET6) {
    return ntohs(((struct sockaddr_in6 *)&addr)->sin6_port);
  }
  return -EAFNOSUPPORT;
}
