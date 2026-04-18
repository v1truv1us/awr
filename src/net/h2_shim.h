/* h2_shim.h — minimal C shim over nghttp2 for the AWR HTTP/2 session.
 *
 * Design: nghttp2 is I/O-agnostic.  It never touches sockets directly;
 * instead the caller feeds incoming bytes in and drains outgoing bytes out.
 * This shim wraps that loop in five functions that are easy to call from Zig.
 *
 * On init the shim immediately submits the Chrome 132 SETTINGS frame and the
 * connection-level WINDOW_UPDATE (increment 15663105) so that the first call
 * to awr_h2_session_send() will include both frames plus the 24-byte client
 * connection preface ("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n").
 */

#ifndef AWR_H2_SHIM_H
#define AWR_H2_SHIM_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>  /* ssize_t */

#ifdef __cplusplus
extern "C" {
#endif

/* ── Callback types the Zig side must provide ──────────────────────────── */

/* Called when nghttp2 wants to send bytes on the wire.
 * Must return the number of bytes consumed, or < 0 on error.
 * The implementation should buffer the bytes; the transport is flushed
 * separately. */
typedef ssize_t (*awr_h2_send_cb)(const uint8_t *data, size_t len,
                                   void *userdata);

/* Called when the shim needs more incoming bytes.
 * Unused in the mem_recv path — kept for interface symmetry. */
typedef ssize_t (*awr_h2_recv_cb)(uint8_t *data, size_t len, void *userdata);

/* Called once per completed response stream.
 * header_names[i] / header_values[i] are nul-terminated C strings.
 * body may be NULL if body_len == 0. */
typedef void (*awr_h2_response_cb)(int32_t stream_id, int status,
                                    const char **header_names,
                                    const char **header_values,
                                    size_t nheaders,
                                    const uint8_t *body, size_t body_len,
                                    void *userdata);

/* ── Session lifetime ───────────────────────────────────────────────────── */

/* Create a new client session.  Submits Chrome 132 SETTINGS + WINDOW_UPDATE
 * immediately (call awr_h2_session_send to flush them).
 * Returns NULL on allocation failure. */
void *awr_h2_session_new(awr_h2_send_cb   send_cb,
                          awr_h2_recv_cb   recv_cb,
                          awr_h2_response_cb resp_cb,
                          void            *userdata);

/* Free the session and all associated memory. */
void awr_h2_session_free(void *session);

/* ── Request submission ─────────────────────────────────────────────────── */

/* Submit a GET/POST/… request.  Returns the new stream_id (>= 1) or < 0
 * on error.  body / body_len may be NULL / 0 for bodyless requests. */
int32_t awr_h2_submit_request(void           *session,
                               const char     *method,
                               const char     *path,
                               const char     *authority,
                               const char     *scheme,
                               const uint8_t  *body,
                               size_t          body_len);

/* ── I/O pump ───────────────────────────────────────────────────────────── */

/* Flush pending outgoing frames.  send_cb will be invoked zero or more
 * times.  Returns 0 on success, < 0 on nghttp2 error. */
int awr_h2_session_send(void *session);

/* Feed `len` bytes of received data into the session.  Parses frames,
 * fires response_cb when a stream completes.
 * Returns 0 on success, < 0 on nghttp2 error. */
int awr_h2_session_recv(void *session, const uint8_t *data, size_t len);

#ifdef __cplusplus
}
#endif

#endif /* AWR_H2_SHIM_H */
