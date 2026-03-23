/// tls_curl_shim.c — curl-impersonate bridge for AWR.
///
/// Wraps libcurl-impersonate's connect-only mode into a simple send/recv
/// interface suitable for Zig's @cImport boundary.
///
/// Design:
///   - Uses CURLOPT_CONNECT_ONLY=2 for raw TLS socket access
///   - Calls curl_easy_impersonate("chrome132", 1) to set TLS fingerprint
///   - Sends/receives via curl_easy_send/curl_easy_recv
///   - Tracks connection state internally to prevent double-cleanup
#include "tls_curl_shim.h"
#include <curl/curl.h>
#include <curl/easy.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

/// curl-impersonate adds this function. Declare it for the compiler.
extern CURLcode curl_easy_impersonate(CURL* curl, const char* target, int default_headers);

/// Connection state tracked internally.
typedef enum {
    AWR_STATE_NEW,
    AWR_STATE_CONNECTED,
    AWR_STATE_CLOSED,
} awr_conn_state;

struct awr_tls_ctx {
    CURL*              curl;
    char*              host;       /// owned copy of hostname for SNI
    uint16_t           port;
    awr_conn_state     state;
    awr_http_version   protocol;
};

/// Max wait time for connection in milliseconds.
#define AWR_CONNECT_TIMEOUT_MS 30000

/// Check if curl-impersonate is available.
/// Returns 1 if available, 0 otherwise.
static int has_curl_impersonate(void) {
    CURL* test = curl_easy_init();
    if (!test) return 0;
    curl_easy_cleanup(test);
    return 1;
}

awr_tls_ctx* awr_tls_init(const char* host, uint16_t port) {
    if (!has_curl_impersonate()) return NULL;

    awr_tls_ctx* ctx = (awr_tls_ctx*)malloc(sizeof(awr_tls_ctx));
    if (!ctx) return NULL;

    size_t host_len = strlen(host);
    char* host_copy = (char*)malloc(host_len + 1);
    if (!host_copy) {
        free(ctx);
        return NULL;
    }
    memcpy(host_copy, host, host_len + 1);

    ctx->curl     = NULL;
    ctx->host     = host_copy;
    ctx->port     = port;
    ctx->state    = AWR_STATE_NEW;
    ctx->protocol = AWR_HTTP_UNKNOWN;

    return ctx;
}

awr_tls_status awr_tls_handshake(awr_tls_ctx* ctx) {
    if (!ctx) return AWR_TLS_ALLOC_ERR;
    if (ctx->state == AWR_STATE_CONNECTED) return AWR_TLS_OK;
    if (ctx->state == AWR_STATE_CLOSED) return AWR_TLS_NOT_CONNECTED;

    CURL* curl = curl_easy_init();
    if (!curl) return AWR_TLS_ALLOC_ERR;

    ctx->curl = curl;

    /// Build the URL for curl to connect to.
    char url[512];
    snprintf(url, sizeof(url), "https://%s:%u/", ctx->host, ctx->port);

    /// Set Chrome 132 TLS fingerprint.
    /// curl_easy_impersonate sets TLS version, ciphers, curves, extensions,
    /// ALPN, HTTP/2 settings, pseudo-header order, and other fingerprinting
    /// parameters to match Chrome 132's behavior exactly.
    curl_easy_impersonate(curl, "chrome132", 1);

    /// Connect-only mode: we get raw TLS socket, not HTTP handling.
    curl_easy_setopt(curl, CURLOPT_CONNECT_ONLY, 2L);

    /// Target URL (host + port).
    curl_easy_setopt(curl, CURLOPT_URL, url);

    /// Verify TLS certificates.
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 2L);

    /// Connection timeout.
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT_MS, (long)AWR_CONNECT_TIMEOUT_MS);

    /// Perform the connection + TLS handshake.
    CURLcode res = curl_easy_perform(curl);
    if (res != CURLE_OK) {
        curl_easy_cleanup(curl);
        ctx->curl  = NULL;
        ctx->state = AWR_STATE_CLOSED;
        return AWR_TLS_HANDSHAKE_ERR;
    }

    /// Query negotiated protocol (ALPN result).
    long http_version = 0;
    curl_easy_getinfo(curl, CURLINFO_HTTP_VERSION, &http_version);
    switch (http_version) {
        case CURL_HTTP_VERSION_1_1:
            ctx->protocol = AWR_HTTP_1_1;
            break;
        case CURL_HTTP_VERSION_2:
        case CURL_HTTP_VERSION_2TLS:
        case CURL_HTTP_VERSION_2_PRIOR_KNOWLEDGE:
            ctx->protocol = AWR_HTTP_2;
            break;
        default:
            ctx->protocol = AWR_HTTP_UNKNOWN;
            break;
    }

    ctx->state = AWR_STATE_CONNECTED;
    return AWR_TLS_OK;
}

ssize_t awr_tls_send(awr_tls_ctx* ctx, const void* buf, size_t len) {
    if (!ctx || ctx->state != AWR_STATE_CONNECTED) return -1;
    if (!ctx->curl) return -1;

    size_t sent = 0;
    CURLcode res = curl_easy_send(ctx->curl, buf, len, &sent);
    if (res != CURLE_OK) {
        if (res == CURLE_AGAIN) return 0; /// Would block — no data sent yet
        return -1;
    }
    return (ssize_t)sent;
}

ssize_t awr_tls_recv(awr_tls_ctx* ctx, void* buf, size_t len) {
    if (!ctx || ctx->state != AWR_STATE_CONNECTED) return -1;
    if (!ctx->curl) return -1;

    size_t received = 0;
    CURLcode res = curl_easy_recv(ctx->curl, buf, len, &received);
    if (res != CURLE_OK) {
        if (res == CURLE_AGAIN) return 0; /// Would block — no data available
        return -1;
    }
    return (ssize_t)received;
}

awr_http_version awr_tls_negotiated_protocol(const awr_tls_ctx* ctx) {
    if (!ctx) return AWR_HTTP_UNKNOWN;
    return ctx->protocol;
}

int awr_tls_is_established(const awr_tls_ctx* ctx) {
    if (!ctx) return 0;
    return ctx->state == AWR_STATE_CONNECTED;
}

void awr_tls_close(awr_tls_ctx* ctx) {
    if (!ctx) return;

    if (ctx->curl) {
        curl_easy_cleanup(ctx->curl);
        ctx->curl = NULL;
    }

    if (ctx->host) {
        free(ctx->host);
        ctx->host = NULL;
    }

    ctx->state = AWR_STATE_CLOSED;
    free(ctx);
}
