/**
 * h2_shim.h — Thin C wrapper around nghttp2 for AWR Phase 1.
 *
 * Design goals:
 *   - One active GET request per session (Phase 1 — single-stream).
 *   - Caller drives I/O via pluggable send/recv callbacks.
 *   - No threading; loop driven from Zig event loop (Phase 2: libxev).
 *   - Chrome-132 SETTINGS submitted automatically on session creation.
 */
#pragma once
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ── I/O callbacks ────────────────────────────────────────────────────────
 *
 * send_cb: write |len| bytes of |data| to socket.
 *          Return bytes written (>0), or -1 on fatal error.
 *
 * recv_cb: read up to |len| bytes into |buf|.
 *          Return bytes read (>0), 0 on EAGAIN/EWOULDBLOCK, -2 on EOF, -1 on error.
 */
typedef int (*awr_h2_send_cb)(const uint8_t *data, size_t len, void *user_data);
typedef int (*awr_h2_recv_cb)(uint8_t *buf,         size_t len, void *user_data);

/* ── Opaque session handle ────────────────────────────────────────────── */
typedef struct awr_h2_session awr_h2_session_t;

/* ── Response for one stream ──────────────────────────────────────────── *
 *
 * After awr_h2_get_response() succeeds, caller owns |body| and
 * |headers_buf| and must free() them.
 *
 * headers_buf layout: name\0value\0name\0value\0 … (pairs of C strings).
 * Iteration: step through pairs until hdr_pos >= headers_buf_len.
 */
typedef struct {
    uint16_t  status;
    uint8_t  *body;
    size_t    body_len;
    char     *headers_buf;
    size_t    headers_buf_len;
} awr_h2_response_t;

typedef struct {
    const uint8_t *name;
    size_t         name_len;
    const uint8_t *value;
    size_t         value_len;
} awr_h2_header_t;

/* ── Lifecycle ────────────────────────────────────────────────────────── */

/**
 * Create a new client session.
 * Automatically queues the HTTP/2 client connection preface and
 * Chrome-132 SETTINGS.  Call awr_h2_session_run() to send them.
 * Returns NULL on allocation failure.
 */
awr_h2_session_t *awr_h2_session_new(awr_h2_send_cb send_cb,
                                      awr_h2_recv_cb recv_cb,
                                      void          *user_data);

/** Free session and all pending stream state. */
void awr_h2_session_free(awr_h2_session_t *sess);

/* ── Request ──────────────────────────────────────────────────────────── */

/**
 * Submit a GET request.
 * Returns the positive stream_id (odd integer) on success, or -1 on error.
 * The caller should call awr_h2_session_run() after this to flush frames.
 */
int32_t awr_h2_submit_get(awr_h2_session_t *sess,
                            const char       *method,
                            const char       *scheme,
                            const char       *authority,
                            const char       *path);

int32_t awr_h2_submit_get_ex(awr_h2_session_t     *sess,
                              const char           *method,
                              const char           *scheme,
                              const char           *authority,
                              const char           *path,
                              const awr_h2_header_t *headers,
                              size_t                header_count);

/* ── I/O pump ─────────────────────────────────────────────────────────── */

/**
 * Drive one send+recv cycle.
 * Returns 0 on success, or a negative nghttp2 error code.
 * Call in a loop until awr_h2_stream_complete() returns 1 for all streams.
 */
int awr_h2_session_run(awr_h2_session_t *sess);

/* ── Response retrieval ───────────────────────────────────────────────── */

/** Returns 1 if the stream has received END_STREAM, 0 otherwise. */
int awr_h2_stream_complete(awr_h2_session_t *sess, int32_t stream_id);

/**
 * Fill *out with collected response data.
 * Transfers ownership of body/headers_buf to caller — caller must free().
 * Returns 0 on success, -1 if stream not found or not complete.
 */
int awr_h2_get_response(awr_h2_session_t  *sess,
                          int32_t            stream_id,
                          awr_h2_response_t *out);

/* Test helper: verifies the shim's pseudo-header construction order. */
int awr_h2_pseudo_header_order_ok(void);

#ifdef __cplusplus
}
#endif
