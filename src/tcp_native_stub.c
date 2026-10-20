#include <moonbit.h>

#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
#include <arpa/inet.h>

#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif

#define FEATHER_GAI_BASE 10000

static int feather_set_timeout(int fd, int32_t timeout_ms) {
  if (timeout_ms <= 0) {
    return 0;
  }
  struct timeval tv;
  tv.tv_sec = timeout_ms / 1000;
  tv.tv_usec = (timeout_ms % 1000) * 1000;
  if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)) < 0) {
    return -errno;
  }
  if (setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv)) < 0) {
    return -errno;
  }
  return 0;
}

MOONBIT_FFI_EXPORT
int32_t feather_tcp_connect(moonbit_bytes_t host, int32_t port, int32_t timeout_ms) {
  int32_t host_len = Moonbit_array_length(host);
  if (host_len <= 0 || host_len >= 1024 || port < 1 || port > 65535) {
    return -EINVAL;
  }
  char name[1024];
  memcpy(name, host, (size_t)host_len);
  name[host_len] = '\0';
  if (strchr(name, '\0') != name + host_len) {
    return -EINVAL;
  }

  char service[16];
  snprintf(service, sizeof(service), "%d", (int)port);

  struct addrinfo hints;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_protocol = IPPROTO_TCP;

  struct addrinfo *result = NULL;
  int gai = getaddrinfo(name, service, &hints, &result);
  if (gai != 0) {
    return -(FEATHER_GAI_BASE + gai);
  }

  int last_error = EHOSTUNREACH;
  int fd = -1;
  for (struct addrinfo *entry = result; entry != NULL; entry = entry->ai_next) {
    fd = socket(entry->ai_family, entry->ai_socktype, entry->ai_protocol);
    if (fd < 0) {
      last_error = errno;
      continue;
    }

    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
      last_error = errno;
      close(fd);
      fd = -1;
      continue;
    }

    int connected = 0;
    if (connect(fd, entry->ai_addr, entry->ai_addrlen) == 0) {
      connected = 1;
    } else if (errno == EINPROGRESS) {
      struct pollfd pfd;
      pfd.fd = fd;
      pfd.events = POLLOUT;
      pfd.revents = 0;
      int poll_timeout = timeout_ms > 0 ? timeout_ms : -1;
      int ready;
      do {
        ready = poll(&pfd, 1, poll_timeout);
      } while (ready < 0 && errno == EINTR);
      if (ready == 0) {
        last_error = ETIMEDOUT;
      } else if (ready < 0) {
        last_error = errno;
      } else {
        int socket_error = 0;
        socklen_t error_len = sizeof(socket_error);
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &socket_error, &error_len) < 0) {
          last_error = errno;
        } else if (socket_error != 0) {
          last_error = socket_error;
        } else {
          connected = 1;
        }
      }
    } else {
      last_error = errno;
    }

    if (!connected) {
      close(fd);
      fd = -1;
      continue;
    }

    if (fcntl(fd, F_SETFL, flags) < 0) {
      last_error = errno;
      close(fd);
      fd = -1;
      continue;
    }

    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    if (feather_set_timeout(fd, timeout_ms) < 0) {
      last_error = errno;
      close(fd);
      fd = -1;
      continue;
    }

    freeaddrinfo(result);
    return fd;
  }

  freeaddrinfo(result);
  return -last_error;
}

MOONBIT_FFI_EXPORT
int32_t feather_tcp_read(int32_t fd, moonbit_bytes_t buffer, int32_t capacity) {
  if (fd < 0) {
    return -EBADF;
  }
  if (capacity <= 0) {
    return 0;
  }
  for (;;) {
    ssize_t count = recv(fd, buffer, (size_t)capacity, 0);
    if (count < 0) {
      if (errno == EINTR) {
        continue;
      }
      return -errno;
    }
    return (int32_t)count;
  }
}

MOONBIT_FFI_EXPORT
int32_t feather_tcp_write(int32_t fd, moonbit_bytes_t buffer, int32_t length) {
  if (fd < 0) {
    return -EBADF;
  }
  if (length <= 0) {
    return 0;
  }
  for (;;) {
    ssize_t count = send(fd, buffer, (size_t)length, MSG_NOSIGNAL);
    if (count < 0) {
      if (errno == EINTR) {
        continue;
      }
      return -errno;
    }
    return (int32_t)count;
  }
}

MOONBIT_FFI_EXPORT
int32_t feather_tcp_close(int32_t fd) {
  if (fd < 0) {
    return 0;
  }
  if (close(fd) < 0) {
    return -errno;
  }
  return 0;
}

MOONBIT_FFI_EXPORT
int32_t feather_tcp_set_timeout(int32_t fd, int32_t timeout_ms) {
  if (fd < 0) {
    return -EBADF;
  }
  return feather_set_timeout(fd, timeout_ms);
}

MOONBIT_FFI_EXPORT
int32_t feather_tcp_is_alive(int32_t fd) {
  if (fd < 0) {
    return -EBADF;
  }
  struct pollfd pfd;
  pfd.fd = fd;
  pfd.events = POLLIN;
  pfd.revents = 0;
  int ready;
  do {
    ready = poll(&pfd, 1, 0);
  } while (ready < 0 && errno == EINTR);
  if (ready < 0) {
    return -errno;
  }
  if (ready == 0) {
    return 1;
  }
  if ((pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
    return 0;
  }
  if ((pfd.revents & POLLIN) != 0) {
    char peek;
    ssize_t count = recv(fd, &peek, 1, MSG_PEEK | MSG_DONTWAIT);
    if (count == 0) {
      return 0;
    }
    if (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
      return 0;
    }
  }
  return 1;
}

static int feather_append_address(char *output, int32_t capacity, int32_t offset, const char *text) {
  int32_t length = (int32_t)strlen(text);
  int32_t needed = length + (offset > 0 ? 1 : 0);
  if (offset + needed > capacity) {
    return -ENOSPC;
  }
  if (offset > 0) {
    output[offset++] = '\n';
  }
  memcpy(output + offset, text, (size_t)length);
  return offset + length;
}

MOONBIT_FFI_EXPORT
int32_t feather_tcp_resolve(moonbit_bytes_t host, moonbit_bytes_t output, int32_t capacity) {
  int32_t host_len = Moonbit_array_length(host);
  if (host_len <= 0 || host_len >= 1024) {
    return -EINVAL;
  }
  char name[1024];
  memcpy(name, host, (size_t)host_len);
  name[host_len] = '\0';

  struct addrinfo hints;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_protocol = IPPROTO_TCP;

  struct addrinfo *result = NULL;
  int gai = getaddrinfo(name, NULL, &hints, &result);
  if (gai != 0) {
    return -(FEATHER_GAI_BASE + gai);
  }

  char *buffer = (char *)output;
  int32_t offset = 0;
  for (struct addrinfo *entry = result; entry != NULL; entry = entry->ai_next) {
    char text[INET6_ADDRSTRLEN];
    const void *address = NULL;
    if (entry->ai_family == AF_INET) {
      address = &((struct sockaddr_in *)entry->ai_addr)->sin_addr;
    } else if (entry->ai_family == AF_INET6) {
      address = &((struct sockaddr_in6 *)entry->ai_addr)->sin6_addr;
    } else {
      continue;
    }
    if (inet_ntop(entry->ai_family, address, text, sizeof(text)) == NULL) {
      continue;
    }
    int next = feather_append_address(buffer, capacity, offset, text);
    if (next < 0) {
      freeaddrinfo(result);
      return next;
    }
    offset = next;
  }

  freeaddrinfo(result);
  return offset;
}
