/**
 * tls_awr_shim.h — BoringSSL TLS shim API for AWR Phase 3.
 *
 * Provides a thin C interface over BoringSSL that the Zig tls_conn.zig
 * wrapper calls via @cImport. All functions return 1 on success, 0 on error
 * (matching BoringSSL conventions), except read/write which return byte count
 * or a negative error code.
 */
#ifndef AWR_TLS_SHIM_H
#define AWR_TLS_SHIM_H

#include <stddef.h>
#include <stdint.h>

/* Opaque types — Zig only holds pointers to these. */
typedef struct ssl_ctx_st awr_ssl_ctx_t;
typedef struct ssl_st     awr_ssl_t;

#ifdef __cplusplus
extern "C" {
#endif

/* ── Context lifecycle ──────────────────────────────────────────────────── */

/**
 * awr_tls_ctx_new — allocate and configure a shared SSL_CTX.
 *
 * Configures:
 *   - AWR cipher suite list (15 entries — Chrome 132 minus deprecated 3DES)
 *   - Supported groups: X25519MLKEM768, x25519, P-256, P-384
 *   - ALPN protos: h2, http/1.1
 *   - Signature algorithms matching Chrome 132
 *   - Peer certificate verification enabled (SSL_VERIFY_PEER)
 *
 * Returns a new SSL_CTX on success, NULL on failure.
 * Call awr_tls_load_ca_bundle() after this to load CA certificates.
 */
awr_ssl_ctx_t *awr_tls_ctx_new(void);

/** awr_tls_ctx_free — release an SSL_CTX returned by awr_tls_ctx_new. */
void awr_tls_ctx_free(awr_ssl_ctx_t *ctx);

/**
 * awr_tls_load_ca_bundle — load PEM-encoded CA certificates into ctx.
 *
 * pem_data: pointer to PEM bytes (e.g. from @embedFile)
 * pem_len:  length of the PEM buffer
 *
 * Walks the PEM buffer and adds each certificate to ctx's X509_STORE.
 * Returns 1 if at least one certificate was loaded, 0 on error.
 */
int awr_tls_load_ca_bundle(awr_ssl_ctx_t *ctx,
                            const uint8_t *pem_data, size_t pem_len);

/** awr_tls_set_alpn_http11_only — restrict ALPN to HTTP/1.1 only. Returns 1 on success. */
int awr_tls_set_alpn_http11_only(awr_ssl_ctx_t *ctx);

/** awr_tls_load_default_paths — load system default CA certificate paths. */
int awr_tls_load_default_paths(awr_ssl_ctx_t *ctx);

/* ── Connection lifecycle ───────────────────────────────────────────────── */

/**
 * awr_tls_conn_new — perform a TLS handshake on an existing TCP socket fd.
 *
 * ctx:      SSL_CTX from awr_tls_ctx_new (shared across connections)
 * fd:       connected, blocking TCP socket file descriptor
 * hostname: null-terminated hostname for SNI and certificate verification
 *
 * Also calls SSL_add_application_settings on the SSL object to configure ALPS
 * for "h2" with AWR's encoded H2 SETTINGS payload.
 *
 * Returns a new SSL* (already past SSL_connect) on success, NULL on failure.
 */
awr_ssl_t *awr_tls_conn_new(awr_ssl_ctx_t *ctx, int fd, const char *hostname);

/** awr_tls_conn_free — release an SSL* returned by awr_tls_conn_new. */
void awr_tls_conn_free(awr_ssl_t *ssl);

/* ── I/O ────────────────────────────────────────────────────────────────── */

/**
 * awr_tls_conn_read — read up to len bytes from an established TLS connection.
 * Returns bytes read (>0), 0 on clean EOF, or -1 on error.
 */
int awr_tls_conn_read(awr_ssl_t *ssl, uint8_t *buf, int len);

/**
 * awr_tls_conn_write — write len bytes to an established TLS connection.
 * Returns bytes written (>0) or -1 on error.
 */
int awr_tls_conn_write(awr_ssl_t *ssl, const uint8_t *buf, int len);

/** awr_tls_conn_pending — return decrypted bytes already buffered by TLS. */
int awr_tls_conn_pending(const awr_ssl_t *ssl);

/* ── ALPN result ────────────────────────────────────────────────────────── */

/**
 * awr_tls_alpn_result — return the negotiated ALPN protocol string.
 *
 * out_proto: set to a pointer into BoringSSL's internal buffer (no copy)
 * out_len:   set to the length of the protocol string
 *
 * If ALPN was not negotiated, *out_proto is set to NULL and *out_len to 0.
 */
void awr_tls_alpn_result(const awr_ssl_t *ssl,
                          const uint8_t **out_proto, unsigned int *out_len);

/* ── ALPS settings encoding (exposed for testing) ───────────────────────── */

/**
 * awr_h2_alps_settings_len — returns the byte length of the encoded ALPS
 * H2 settings payload.
 */
size_t awr_h2_alps_settings_len(void);

/**
 * awr_h2_alps_encode_settings — encode AWR's H2 SETTINGS into buf.
 *
 * buf must be at least awr_h2_alps_settings_len() bytes.
 * Encodes: HEADER_TABLE_SIZE=65536, INITIAL_WINDOW_SIZE=6291456,
 *          MAX_HEADER_LIST_SIZE=262144 as 6-byte key-value pairs.
 */
void awr_h2_alps_encode_settings(uint8_t *buf);

#ifdef __cplusplus
}
#endif

#endif /* AWR_TLS_SHIM_H */
