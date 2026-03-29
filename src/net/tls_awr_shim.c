/**
 * tls_awr_shim.c — BoringSSL TLS shim for AWR Phase 3.
 *
 * Thin C layer over BoringSSL. All TLS configuration is centralised here so
 * that the Zig tls_conn.zig wrapper stays clean of @cImport complexity.
 *
 * AWR cipher policy:
 *   Chrome 132 list (16 entries) minus TLS_RSA_WITH_3DES_EDE_CBC_SHA (0x000A).
 *   3DES is deprecated by RFC 8996 (March 2021); a new browser must not offer
 *   it. Removing it changes AWR's JA4 cipher hash away from Chrome 132.
 *
 * AWR ALPS policy:
 *   ALPS is configured per SSL* (not SSL_CTX*) via SSL_add_application_settings.
 *   The settings payload encodes three H2 SETTINGS key-value pairs:
 *     HEADER_TABLE_SIZE   (0x0001) = 65536
 *     INITIAL_WINDOW_SIZE (0x0004) = 6291456
 *     MAX_HEADER_LIST_SIZE(0x0006) = 262144
 *   Each entry is 2 bytes (ID, big-endian) + 4 bytes (value, big-endian) = 18 bytes total.
 */

#include "tls_awr_shim.h"
#include <openssl/ssl.h>
#include <openssl/pem.h>
#include <openssl/x509.h>
#include <openssl/err.h>
#include <openssl/bio.h>
#include <openssl/nid.h>
#include <stdlib.h>
#include <string.h>

/* ── AWR cipher string ───────────────────────────────────────────────────
 * 15 entries: Chrome 132 list with TLS_RSA_WITH_3DES_EDE_CBC_SHA removed.
 * TLS 1.3 ciphers are part of the BoringSSL default for TLS 1.3; the string
 * below controls TLS 1.2 and below. BoringSSL will include TLS 1.3 ciphers
 * automatically regardless of the cipher list string.
 *
 * Note: TLS 1.3 ciphers (0x1301–0x1303) cannot be disabled via cipher list
 * in BoringSSL — they are always offered. The 15-entry AWR list refers to the
 * full cipher list including TLS 1.3 ciphers, consistent with fingerprint.zig.
 */
static const char AWR_CIPHER_LIST[] =
    "ECDHE-ECDSA-AES128-GCM-SHA256:"
    "ECDHE-RSA-AES128-GCM-SHA256:"
    "ECDHE-ECDSA-AES256-GCM-SHA384:"
    "ECDHE-RSA-AES256-GCM-SHA384:"
    "ECDHE-ECDSA-CHACHA20-POLY1305:"
    "ECDHE-RSA-CHACHA20-POLY1305:"
    "ECDHE-RSA-AES128-SHA:"
    "ECDHE-RSA-AES256-SHA:"
    "AES128-GCM-SHA256:"
    "AES256-GCM-SHA384:"
    "AES128-SHA:"
    "AES256-SHA";
/* 3DES (TLS-RSA-WITH-3DES-EDE-CBC-SHA) intentionally omitted. */

/* ── AWR supported groups ────────────────────────────────────────────────
 * X25519MLKEM768 first (hybrid PQ key share), then classical fallbacks.
 * NID_X25519MLKEM768 = 965 per BoringSSL nid.h.
 */
static const int AWR_CURVES[] = {
    NID_X25519MLKEM768,  /* 0x11EC — post-quantum hybrid */
    NID_X25519,          /* x25519 */
    NID_X9_62_prime256v1, /* P-256 / secp256r1 */
    NID_secp384r1,        /* P-384 */
};
#define AWR_CURVES_LEN ((int)(sizeof(AWR_CURVES) / sizeof(AWR_CURVES[0])))

/* ── AWR ALPN wire encoding ──────────────────────────────────────────────
 * Length-prefixed protocol list: \x02h2\x08http/1.1
 */
static const uint8_t AWR_ALPN_PROTOS[] = {
    0x02, 'h', '2',
    0x08, 'h', 't', 't', 'p', '/', '1', '.', '1',
};
#define AWR_ALPN_PROTOS_LEN ((unsigned int)sizeof(AWR_ALPN_PROTOS))

/* ── Chrome 132 signature algorithms ────────────────────────────────────
 * Textual form accepted by SSL_CTX_set1_sigalgs_list.
 */
static const char AWR_SIGALGS[] =
    "ecdsa_secp256r1_sha256:"
    "rsa_pss_rsae_sha256:"
    "rsa_pkcs1_sha256:"
    "ecdsa_secp384r1_sha384:"
    "rsa_pss_rsae_sha384:"
    "rsa_pkcs1_sha384:"
    "rsa_pss_rsae_sha512:"
    "rsa_pkcs1_sha512";

/* ── ALPS H2 settings payload ────────────────────────────────────────────
 * 3 settings × 6 bytes = 18 bytes.
 * Layout per RFC 7540 §6.5: ID(2) || Value(4), big-endian.
 */
#define ALPS_ENTRY_COUNT 3
#define ALPS_ENTRY_SIZE  6
#define ALPS_BUF_SIZE    (ALPS_ENTRY_COUNT * ALPS_ENTRY_SIZE)  /* 18 */

typedef struct { uint16_t id; uint32_t val; } alps_entry_t;

static const alps_entry_t AWR_ALPS_SETTINGS[ALPS_ENTRY_COUNT] = {
    { 0x0001, 65536   },  /* HEADER_TABLE_SIZE    */
    { 0x0004, 6291456 },  /* INITIAL_WINDOW_SIZE  */
    { 0x0006, 262144  },  /* MAX_HEADER_LIST_SIZE */
};

size_t awr_h2_alps_settings_len(void) { return ALPS_BUF_SIZE; }

void awr_h2_alps_encode_settings(uint8_t *buf) {
    for (int i = 0; i < ALPS_ENTRY_COUNT; i++) {
        uint8_t *p = buf + i * ALPS_ENTRY_SIZE;
        p[0] = (uint8_t)(AWR_ALPS_SETTINGS[i].id >> 8);
        p[1] = (uint8_t)(AWR_ALPS_SETTINGS[i].id & 0xff);
        p[2] = (uint8_t)(AWR_ALPS_SETTINGS[i].val >> 24);
        p[3] = (uint8_t)(AWR_ALPS_SETTINGS[i].val >> 16);
        p[4] = (uint8_t)(AWR_ALPS_SETTINGS[i].val >> 8);
        p[5] = (uint8_t)(AWR_ALPS_SETTINGS[i].val & 0xff);
    }
}

/* ── Context lifecycle ──────────────────────────────────────────────────── */

awr_ssl_ctx_t *awr_tls_ctx_new(void) {
    SSL_CTX *ctx = SSL_CTX_new(TLS_client_method());
    if (!ctx) return NULL;

    /* Cipher list (TLS 1.2 and below) */
    if (!SSL_CTX_set_cipher_list(ctx, AWR_CIPHER_LIST))
        goto fail;

    /* Supported groups / key share order */
    if (!SSL_CTX_set1_curves(ctx, AWR_CURVES, AWR_CURVES_LEN))
        goto fail;

    /* ALPN: offer h2 first, then http/1.1 */
    if (SSL_CTX_set_alpn_protos(ctx, AWR_ALPN_PROTOS, AWR_ALPN_PROTOS_LEN) != 0)
        goto fail;

    /* Signature algorithms */
    if (!SSL_CTX_set1_sigalgs_list(ctx, AWR_SIGALGS))
        goto fail;

    /* Require server certificate verification */
    SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);

    return (awr_ssl_ctx_t *)ctx;

fail:
    SSL_CTX_free(ctx);
    return NULL;
}

void awr_tls_ctx_free(awr_ssl_ctx_t *ctx) {
    SSL_CTX_free((SSL_CTX *)ctx);
}

/* ── CA bundle loading ─────────────────────────────────────────────────── */

int awr_tls_load_ca_bundle(awr_ssl_ctx_t *ctx,
                             const uint8_t *pem_data, size_t pem_len) {
    BIO *bio = BIO_new_mem_buf(pem_data, (int)pem_len);
    if (!bio) return 0;

    X509_STORE *store = SSL_CTX_get_cert_store((SSL_CTX *)ctx);
    int loaded = 0;
    X509 *cert;

    while ((cert = PEM_read_bio_X509(bio, NULL, NULL, NULL)) != NULL) {
        if (X509_STORE_add_cert(store, cert) == 1)
            loaded++;
        X509_free(cert);
    }

    /* PEM_read_bio_X509 sets a benign EOF error at end-of-bundle; clear it. */
    ERR_clear_error();

    BIO_free(bio);
    return loaded > 0 ? 1 : 0;
}

/* ── Connection lifecycle ───────────────────────────────────────────────── */

awr_ssl_t *awr_tls_conn_new(awr_ssl_ctx_t *ctx, int fd, const char *hostname) {
    SSL *ssl = SSL_new((SSL_CTX *)ctx);
    if (!ssl) return NULL;

    /* SNI + hostname verification */
    if (!SSL_set_tlsext_host_name(ssl, hostname))
        goto fail;
    if (!SSL_set1_host(ssl, hostname))
        goto fail;

    /* ALPS for h2 — must be set per-connection, not on SSL_CTX */
    {
        static const uint8_t h2_proto[] = { 'h', '2' };
        uint8_t alps_buf[ALPS_BUF_SIZE];
        awr_h2_alps_encode_settings(alps_buf);
        if (!SSL_add_application_settings(ssl, h2_proto, sizeof(h2_proto),
                                           alps_buf, ALPS_BUF_SIZE))
            goto fail;
    }

    /* Attach socket and perform blocking handshake */
    if (!SSL_set_fd(ssl, fd))
        goto fail;

    if (SSL_connect(ssl) != 1)
        goto fail;

    return (awr_ssl_t *)ssl;

fail:
    SSL_free(ssl);
    return NULL;
}

void awr_tls_conn_free(awr_ssl_t *ssl) {
    if (ssl) {
        SSL_shutdown((SSL *)ssl);
        SSL_free((SSL *)ssl);
    }
}

/* ── I/O ────────────────────────────────────────────────────────────────── */

int awr_tls_conn_read(awr_ssl_t *ssl, uint8_t *buf, int len) {
    int n = SSL_read((SSL *)ssl, buf, len);
    if (n > 0) return n;

    int err = SSL_get_error((SSL *)ssl, n);
    if (err == SSL_ERROR_ZERO_RETURN) return 0;  /* clean EOF */
    return -1;
}

int awr_tls_conn_write(awr_ssl_t *ssl, const uint8_t *buf, int len) {
    int n = SSL_write((SSL *)ssl, buf, len);
    return (n > 0) ? n : -1;
}

/* ── ALPN result ────────────────────────────────────────────────────────── */

void awr_tls_alpn_result(const awr_ssl_t *ssl,
                          const uint8_t **out_proto, unsigned int *out_len) {
    SSL_get0_alpn_selected((const SSL *)ssl, out_proto, out_len);
}
