#include <moonbit.h>

#include <arpa/inet.h>
#include <errno.h>
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>
#include <stdint.h>
#include <string.h>

#ifndef TLS1_3_VERSION
#define TLS1_3_VERSION 0x0304
#endif

typedef struct {
  SSL_CTX *ctx;
  SSL *ssl;
  int ready;
  int last_error;
  int verify_error;
  unsigned long library_error;
} FeatherTls;

static void feather_tls_finalize(void *pointer) {
  FeatherTls *tls = (FeatherTls *)pointer;
  if (tls->ssl != NULL) {
    SSL_free(tls->ssl);
    tls->ssl = NULL;
  }
  if (tls->ctx != NULL) {
    SSL_CTX_free(tls->ctx);
    tls->ctx = NULL;
  }
}

static void feather_tls_record_error(FeatherTls *tls) {
  tls->library_error = ERR_get_error();
  tls->verify_error = tls->ssl != NULL ? (int)SSL_get_verify_result(tls->ssl) : 0;
}

MOONBIT_FFI_EXPORT
FeatherTls *feather_tls_new(
  moonbit_bytes_t server_name,
  moonbit_bytes_t alpn,
  int32_t alpn_length,
  int32_t verify,
  int32_t min_version,
  moonbit_bytes_t roots,
  int32_t roots_length,
  moonbit_bytes_t certificate,
  int32_t certificate_length,
  moonbit_bytes_t private_key,
  int32_t private_key_length
) {
  FeatherTls *tls = (FeatherTls *)moonbit_make_external_object(
    feather_tls_finalize, sizeof(FeatherTls));
  memset(tls, 0, sizeof(FeatherTls));

  int32_t name_length = Moonbit_array_length(server_name);
  if (name_length <= 0 || name_length >= 1024) {
    tls->last_error = -EINVAL;
    return tls;
  }
  char name[1024];
  memcpy(name, server_name, (size_t)name_length);
  name[name_length] = '\0';

  OPENSSL_init_ssl(
    OPENSSL_INIT_LOAD_SSL_STRINGS | OPENSSL_INIT_LOAD_CRYPTO_STRINGS, NULL);
  tls->ctx = SSL_CTX_new(TLS_client_method());
  if (tls->ctx == NULL) {
    feather_tls_record_error(tls);
    return tls;
  }

#ifdef SSL_OP_IGNORE_UNEXPECTED_EOF
  SSL_CTX_set_options(tls->ctx, SSL_OP_IGNORE_UNEXPECTED_EOF);
#endif

  int version = min_version == 0 ? TLS1_2_VERSION : TLS1_3_VERSION;
  if (SSL_CTX_set_min_proto_version(tls->ctx, version) != 1) {
    feather_tls_record_error(tls);
    return tls;
  }
  SSL_CTX_set_verify(tls->ctx, verify != 0 ? SSL_VERIFY_PEER : SSL_VERIFY_NONE, NULL);
  if (verify != 0) {
    SSL_CTX_set_default_verify_paths(tls->ctx);
  }

  if (roots_length > 0) {
    BIO *root_bio = BIO_new_mem_buf(roots, roots_length);
    if (root_bio == NULL) {
      feather_tls_record_error(tls);
      return tls;
    }
    X509_STORE *store = SSL_CTX_get_cert_store(tls->ctx);
    for (;;) {
      X509 *root = PEM_read_bio_X509(root_bio, NULL, NULL, NULL);
      if (root == NULL) {
        ERR_clear_error();
        break;
      }
      X509_STORE_add_cert(store, root);
      X509_free(root);
    }
    BIO_free(root_bio);
  }

  if (certificate_length > 0 && private_key_length > 0) {
    BIO *cert_bio = BIO_new_mem_buf(certificate, certificate_length);
    BIO *key_bio = BIO_new_mem_buf(private_key, private_key_length);
    if (cert_bio == NULL || key_bio == NULL) {
      if (cert_bio != NULL) BIO_free(cert_bio);
      if (key_bio != NULL) BIO_free(key_bio);
      feather_tls_record_error(tls);
      return tls;
    }
    X509 *client_certificate = PEM_read_bio_X509(cert_bio, NULL, NULL, NULL);
    EVP_PKEY *client_key = PEM_read_bio_PrivateKey(key_bio, NULL, NULL, NULL);
    BIO_free(cert_bio);
    BIO_free(key_bio);
    if (client_certificate == NULL || client_key == NULL) {
      if (client_certificate != NULL) X509_free(client_certificate);
      if (client_key != NULL) EVP_PKEY_free(client_key);
      feather_tls_record_error(tls);
      return tls;
    }
    int cert_ok = SSL_CTX_use_certificate(tls->ctx, client_certificate);
    int key_ok = SSL_CTX_use_PrivateKey(tls->ctx, client_key);
    X509_free(client_certificate);
    EVP_PKEY_free(client_key);
    if (cert_ok != 1 || key_ok != 1 || SSL_CTX_check_private_key(tls->ctx) != 1) {
      feather_tls_record_error(tls);
      return tls;
    }
  }

  tls->ssl = SSL_new(tls->ctx);
  if (tls->ssl == NULL) {
    feather_tls_record_error(tls);
    return tls;
  }

  if (SSL_set_tlsext_host_name(tls->ssl, name) != 1) {
    feather_tls_record_error(tls);
    return tls;
  }

  if (verify != 0) {
    X509_VERIFY_PARAM *param = SSL_get0_param(tls->ssl);
    X509_VERIFY_PARAM_set_hostflags(param, X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS);
    struct in_addr ipv4;
    struct in6_addr ipv6;
    if (inet_pton(AF_INET, name, &ipv4) == 1 ||
        inet_pton(AF_INET6, name, &ipv6) == 1) {
      if (X509_VERIFY_PARAM_set1_ip_asc(param, name) != 1) {
        feather_tls_record_error(tls);
        return tls;
      }
    } else if (SSL_set1_host(tls->ssl, name) != 1) {
      feather_tls_record_error(tls);
      return tls;
    }
  }

  if (alpn_length > 0) {
    if (SSL_set_alpn_protos(tls->ssl, alpn, (unsigned int)alpn_length) != 0) {
      feather_tls_record_error(tls);
      return tls;
    }
  }

  BIO *read_bio = BIO_new(BIO_s_mem());
  BIO *write_bio = BIO_new(BIO_s_mem());
  if (read_bio == NULL || write_bio == NULL) {
    if (read_bio != NULL) BIO_free(read_bio);
    if (write_bio != NULL) BIO_free(write_bio);
    feather_tls_record_error(tls);
    return tls;
  }
  BIO_set_mem_eof_return(read_bio, -1);
  SSL_set_bio(tls->ssl, read_bio, write_bio);
  SSL_set_connect_state(tls->ssl);

  tls->ready = 1;
  return tls;
}

MOONBIT_FFI_EXPORT
int32_t feather_tls_ready(FeatherTls *tls) {
  return tls != NULL && tls->ready;
}

MOONBIT_FFI_EXPORT
int32_t feather_tls_handshake(FeatherTls *tls) {
  if (tls == NULL || tls->ssl == NULL) {
    return -3;
  }
  int result = SSL_do_handshake(tls->ssl);
  if (result == 1) {
    return 1;
  }
  int error = SSL_get_error(tls->ssl, result);
  if (error == SSL_ERROR_WANT_READ) {
    return 0;
  }
  if (error == SSL_ERROR_WANT_WRITE) {
    return 2;
  }
  if (error == SSL_ERROR_ZERO_RETURN) {
    return -2;
  }
  feather_tls_record_error(tls);
  return -1;
}

MOONBIT_FFI_EXPORT
int32_t feather_tls_read(FeatherTls *tls, moonbit_bytes_t buffer, int32_t capacity) {
  if (tls == NULL || tls->ssl == NULL || capacity <= 0) {
    return -3;
  }
  int result = SSL_read(tls->ssl, buffer, capacity);
  if (result > 0) {
    return result;
  }
  int error = SSL_get_error(tls->ssl, result);
  if (error == SSL_ERROR_WANT_READ) {
    return -1;
  }
  if (error == SSL_ERROR_WANT_WRITE) {
    return -2;
  }
  if (error == SSL_ERROR_ZERO_RETURN) {
    return 0;
  }
  if (error == SSL_ERROR_SYSCALL && result == 0 && ERR_peek_error() == 0) {
    return 0;
  }
  feather_tls_record_error(tls);
  return -3;
}

MOONBIT_FFI_EXPORT
int32_t feather_tls_write(
  FeatherTls *tls,
  moonbit_bytes_t buffer,
  int32_t offset,
  int32_t length
) {
  if (tls == NULL || tls->ssl == NULL || offset < 0 || length <= 0) {
    return -3;
  }
  int result = SSL_write(tls->ssl, buffer + offset, length);
  if (result > 0) {
    return result;
  }
  int error = SSL_get_error(tls->ssl, result);
  if (error == SSL_ERROR_WANT_READ) {
    return -1;
  }
  if (error == SSL_ERROR_WANT_WRITE) {
    return -2;
  }
  feather_tls_record_error(tls);
  return -3;
}

MOONBIT_FFI_EXPORT
int32_t feather_tls_receive_pending(FeatherTls *tls, moonbit_bytes_t buffer, int32_t capacity) {
  if (tls == NULL || tls->ssl == NULL || capacity <= 0) {
    return -1;
  }
  BIO *write_bio = SSL_get_wbio(tls->ssl);
  int pending = (int)BIO_pending(write_bio);
  if (pending <= 0) {
    return 0;
  }
  if (pending > capacity) {
    pending = capacity;
  }
  return BIO_read(write_bio, buffer, pending);
}

MOONBIT_FFI_EXPORT
int32_t feather_tls_send_input(FeatherTls *tls, moonbit_bytes_t buffer, int32_t length) {
  if (tls == NULL || tls->ssl == NULL || length <= 0) {
    return -1;
  }
  BIO *read_bio = SSL_get_rbio(tls->ssl);
  return BIO_write(read_bio, buffer, length);
}

MOONBIT_FFI_EXPORT
int32_t feather_tls_shutdown(FeatherTls *tls) {
  if (tls == NULL || tls->ssl == NULL) {
    return -1;
  }
  int result = SSL_shutdown(tls->ssl);
  if (result >= 0) {
    return 1;
  }
  int error = SSL_get_error(tls->ssl, result);
  if (error == SSL_ERROR_WANT_READ || error == SSL_ERROR_WANT_WRITE) {
    return 0;
  }
  return -1;
}

MOONBIT_FFI_EXPORT
int32_t feather_tls_verify_error(FeatherTls *tls) {
  return tls != NULL ? tls->verify_error : 0;
}

MOONBIT_FFI_EXPORT
int32_t feather_tls_alpn(FeatherTls *tls, moonbit_bytes_t buffer, int32_t capacity) {
  if (tls == NULL || tls->ssl == NULL || capacity <= 0) {
    return 0;
  }
  const unsigned char *protocol = NULL;
  unsigned int length = 0;
  SSL_get0_alpn_selected(tls->ssl, &protocol, &length);
  if (protocol == NULL || length == 0) {
    return 0;
  }
  if ((int32_t)length > capacity) {
    length = (unsigned int)capacity;
  }
  memcpy(buffer, protocol, length);
  return (int32_t)length;
}

MOONBIT_FFI_EXPORT
int32_t feather_tls_last_error_message(
  FeatherTls *tls,
  moonbit_bytes_t buffer,
  int32_t capacity
) {
  if (tls == NULL || capacity <= 0) {
    return 0;
  }
  const char *message = NULL;
  char verify_buffer[256];
  if (tls->verify_error != 0) {
    message = X509_verify_cert_error_string(tls->verify_error);
  }
  if (message == NULL && tls->library_error != 0) {
    ERR_error_string_n(tls->library_error, verify_buffer, sizeof(verify_buffer));
    message = verify_buffer;
  }
  if (message == NULL) {
    message = "TLS operation failed";
  }
  int32_t length = (int32_t)strlen(message);
  if (length > capacity) {
    length = capacity;
  }
  memcpy(buffer, message, (size_t)length);
  return length;
}
