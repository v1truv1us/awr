/// tls_curl_shim.h — C-ABI boundary for curl-impersonate TLS connections.
///
/// This header provides a minimal, opaque API that wraps libcurl-impersonate
/// for use from Zig via @cImport.  The shim owns the curl handle and exposes
/// only the primitives the AWR TLS abstraction needs:
///   - init / handshake (connect)
///   - send / recv (data exchange)
///   - negotiated protocol query
///   - close / cleanup
///
/// The Zig layer in tls.zig remains the source of truth for state transitions
/// and error mapping.

#ifndef TLS_CURL_SHIM_H
#define TLS_CURL_SHIM_H

#include <stddef.h>
#include <stdint.h>
#include <unistd.h>

/// Opaque handle returned by awr_tls_init.
typedef struct awr_tls_ctx awr_tls_ctx;

/// Status codes returned by shim functions.
typedef enum {
    AWR_TLS_OK              = 0,
    AWR_TLS_HANDSHAKE_ERR   = 1,
    AWR_TLS_SEND_ERR        = 2,
    AWR_TLS_RECV_ERR        = 3,
    AWR_TLS_TIMEOUT         = 4,
    AWR_TLS_NOT_CONNECTED   = 5,
    AWR_TLS_ALLOC_ERR       = 6,
} awr_tls_status;

/// Negotiated HTTP protocol after ALPN.
typedef enum {
    AWR_HTTP_1_1 = 0,
    AWR_HTTP_2   = 1,
    AWR_HTTP_UNKNOWN = 2,
} awr_http_version;

/// Create a new TLS context targeting `host:port` with the Chrome 132 profile.
/// Returns NULL on allocation failure.
/// Call awr_tls_handshake() to establish the connection.
awr_tls_ctx* awr_tls_init(const char* host, uint16_t port);

/// Perform TLS handshake using curl-impersonate.
/// Returns AWR_TLS_OK on success, error code on failure.
/// The connection must be in init state (fresh from awr_tls_init).
awr_tls_status awr_tls_handshake(awr_tls_ctx* ctx);

/// Send data over the established TLS connection.
/// Returns number of bytes sent, or <= 0 on error.
ssize_t awr_tls_send(awr_tls_ctx* ctx, const void* buf, size_t len);

/// Receive data from the established TLS connection.
/// Returns number of bytes read, or <= 0 on error.
ssize_t awr_tls_recv(awr_tls_ctx* ctx, void* buf, size_t len);

/// Query the negotiated HTTP version (after ALPN handshake).
/// Returns AWR_HTTP_UNKNOWN if not yet negotiated.
awr_http_version awr_tls_negotiated_protocol(const awr_tls_ctx* ctx);

/// Check if the connection is established and usable.
int awr_tls_is_established(const awr_tls_ctx* ctx);

/// Close and free all resources.
/// Safe to call on a NULL pointer.
void awr_tls_close(awr_tls_ctx* ctx);

#endif /* TLS_CURL_SHIM_H */
