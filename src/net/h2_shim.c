/* h2_shim.c — nghttp2 session wrapper for AWR.
 *
 * Wraps nghttp2's client session API with five clean functions callable
 * from Zig.  The session is configured on init with Chrome 132 SETTINGS so
 * the first flush produces an authentic HTTP/2 connection preface.
 *
 * Chrome 132 HTTP/2 SETTINGS (from fingerprint.zig):
 *   HEADER_TABLE_SIZE      = 65536   (0x0001)
 *   MAX_CONCURRENT_STREAMS = 1000    (0x0003)
 *   INITIAL_WINDOW_SIZE    = 6291456 (0x0004)
 *   MAX_HEADER_LIST_SIZE   = 262144  (0x0006)
 *
 * Connection-level WINDOW_UPDATE increment: 15663105
 */

#include "h2_shim.h"

#include <nghttp2/nghttp2.h>
#include <stdlib.h>
#include <string.h>

/* ── Internal session struct ─────────────────────────────────────────────── */

typedef struct {
    nghttp2_session   *ng;
    awr_h2_send_cb     send_cb;
    awr_h2_recv_cb     recv_cb;
    awr_h2_response_cb resp_cb;
    void              *userdata;

    /* Per-stream accumulator: we only track one at a time for simplicity;
     * a production implementation would use a hash-map keyed by stream_id. */
    int32_t   active_stream_id;
    int       active_status;
    char    **hdr_names;
    char    **hdr_values;
    size_t    hdr_count;
    size_t    hdr_cap;
    uint8_t  *body_buf;
    size_t    body_len;
    size_t    body_cap;
} awr_session_t;

/* ── nghttp2 callbacks ────────────────────────────────────────────────────── */

static ssize_t ng_send_cb(nghttp2_session *session,
                           const uint8_t   *data,
                           size_t           length,
                           int              flags,
                           void            *user_data)
{
    (void)session; (void)flags;
    awr_session_t *s = (awr_session_t *)user_data;
    return s->send_cb(data, length, s->userdata);
}

static int on_frame_recv_cb(nghttp2_session       *session,
                              const nghttp2_frame   *frame,
                              void                  *user_data)
{
    (void)session;
    awr_session_t *s = (awr_session_t *)user_data;

    /* Detect end of stream on DATA or HEADERS with END_STREAM flag */
    int end_stream = 0;
    if (frame->hd.type == NGHTTP2_DATA &&
        (frame->hd.flags & NGHTTP2_FLAG_END_STREAM)) {
        end_stream = 1;
    }
    if (frame->hd.type == NGHTTP2_HEADERS &&
        (frame->hd.flags & NGHTTP2_FLAG_END_STREAM)) {
        end_stream = 1;
    }

    if (end_stream && s->active_stream_id == frame->hd.stream_id) {
        /* Fire the response callback */
        s->resp_cb(s->active_stream_id,
                   s->active_status,
                   (const char **)s->hdr_names,
                   (const char **)s->hdr_values,
                   s->hdr_count,
                   s->body_buf,
                   s->body_len,
                   s->userdata);

        /* Reset accumulator */
        for (size_t i = 0; i < s->hdr_count; i++) {
            free(s->hdr_names[i]);
            free(s->hdr_values[i]);
        }
        free(s->hdr_names);
        free(s->hdr_values);
        free(s->body_buf);
        s->hdr_names  = NULL;
        s->hdr_values = NULL;
        s->hdr_count  = 0;
        s->hdr_cap    = 0;
        s->body_buf   = NULL;
        s->body_len   = 0;
        s->body_cap   = 0;
        s->active_stream_id = -1;
    }
    return 0;
}

static int on_header_cb(nghttp2_session            *session,
                         const nghttp2_frame        *frame,
                         const uint8_t              *name,
                         size_t                      namelen,
                         const uint8_t              *value,
                         size_t                      valuelen,
                         uint8_t                     flags,
                         void                       *user_data)
{
    (void)session; (void)flags;
    awr_session_t *s = (awr_session_t *)user_data;

    if (frame->hd.type != NGHTTP2_HEADERS) return 0;

    /* Track active stream */
    if (s->active_stream_id < 0)
        s->active_stream_id = frame->hd.stream_id;

    /* Parse :status pseudo-header */
    if (namelen == 7 && memcmp(name, ":status", 7) == 0) {
        s->active_status = atoi((const char *)value);
    }

    /* Grow header arrays if needed */
    if (s->hdr_count >= s->hdr_cap) {
        size_t new_cap = s->hdr_cap == 0 ? 16 : s->hdr_cap * 2;
        char **nn = realloc(s->hdr_names,  new_cap * sizeof(char *));
        char **nv = realloc(s->hdr_values, new_cap * sizeof(char *));
        if (!nn || !nv) return NGHTTP2_ERR_CALLBACK_FAILURE;
        s->hdr_names  = nn;
        s->hdr_values = nv;
        s->hdr_cap    = new_cap;
    }

    s->hdr_names[s->hdr_count]  = strndup((const char *)name,  namelen);
    s->hdr_values[s->hdr_count] = strndup((const char *)value, valuelen);
    if (!s->hdr_names[s->hdr_count] || !s->hdr_values[s->hdr_count])
        return NGHTTP2_ERR_CALLBACK_FAILURE;
    s->hdr_count++;
    return 0;
}

static int on_data_chunk_recv_cb(nghttp2_session *session,
                                  uint8_t          flags,
                                  int32_t          stream_id,
                                  const uint8_t   *data,
                                  size_t           len,
                                  void            *user_data)
{
    (void)session; (void)flags;
    awr_session_t *s = (awr_session_t *)user_data;
    if (stream_id != s->active_stream_id) return 0;

    /* Grow body buffer */
    if (s->body_len + len > s->body_cap) {
        size_t new_cap = s->body_cap == 0 ? 4096 : s->body_cap * 2;
        while (new_cap < s->body_len + len) new_cap *= 2;
        uint8_t *nb = realloc(s->body_buf, new_cap);
        if (!nb) return NGHTTP2_ERR_CALLBACK_FAILURE;
        s->body_buf = nb;
        s->body_cap = new_cap;
    }
    memcpy(s->body_buf + s->body_len, data, len);
    s->body_len += len;
    return 0;
}

/* ── Public API ──────────────────────────────────────────────────────────── */

void *awr_h2_session_new(awr_h2_send_cb     send_cb,
                          awr_h2_recv_cb     recv_cb,
                          awr_h2_response_cb resp_cb,
                          void              *userdata)
{
    awr_session_t *s = calloc(1, sizeof(awr_session_t));
    if (!s) return NULL;

    s->send_cb  = send_cb;
    s->recv_cb  = recv_cb;
    s->resp_cb  = resp_cb;
    s->userdata = userdata;
    s->active_stream_id = -1;

    /* Wire up nghttp2 callbacks */
    nghttp2_session_callbacks *cbs;
    if (nghttp2_session_callbacks_new(&cbs) != 0) { free(s); return NULL; }

    nghttp2_session_callbacks_set_send_callback2(cbs, ng_send_cb);
    nghttp2_session_callbacks_set_on_frame_recv_callback(cbs, on_frame_recv_cb);
    nghttp2_session_callbacks_set_on_header_callback(cbs, on_header_cb);
    nghttp2_session_callbacks_set_on_data_chunk_recv_callback(
        cbs, on_data_chunk_recv_cb);

    int rc = nghttp2_session_client_new(&s->ng, cbs, s);
    nghttp2_session_callbacks_del(cbs);
    if (rc != 0) { free(s); return NULL; }

    /* Submit Chrome 132 SETTINGS */
    nghttp2_settings_entry iv[4] = {
        { NGHTTP2_SETTINGS_HEADER_TABLE_SIZE,      65536   },
        { NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS, 1000    },
        { NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE,    6291456 },
        { NGHTTP2_SETTINGS_MAX_HEADER_LIST_SIZE,   262144  },
    };
    if (nghttp2_submit_settings(s->ng, NGHTTP2_FLAG_NONE, iv, 4) != 0) {
        nghttp2_session_del(s->ng);
        free(s);
        return NULL;
    }

    /* Submit connection-level WINDOW_UPDATE (Chrome 132 increment) */
    if (nghttp2_submit_window_update(s->ng, NGHTTP2_FLAG_NONE, 0, 15663105) != 0) {
        nghttp2_session_del(s->ng);
        free(s);
        return NULL;
    }

    return s;
}

void awr_h2_session_free(void *session)
{
    if (!session) return;
    awr_session_t *s = (awr_session_t *)session;
    nghttp2_session_del(s->ng);
    for (size_t i = 0; i < s->hdr_count; i++) {
        free(s->hdr_names[i]);
        free(s->hdr_values[i]);
    }
    free(s->hdr_names);
    free(s->hdr_values);
    free(s->body_buf);
    free(s);
}

int32_t awr_h2_submit_request(void          *session,
                               const char    *method,
                               const char    *path,
                               const char    *authority,
                               const char    *scheme,
                               const uint8_t *body,
                               size_t         body_len)
{
    awr_session_t *s = (awr_session_t *)session;

    /* Chrome 132 pseudo-header order: :method :authority :scheme :path */
    nghttp2_nv hdrs[] = {
        { (uint8_t *)":method",    (uint8_t *)method,
          7, strlen(method),    NGHTTP2_NV_FLAG_NONE },
        { (uint8_t *)":authority", (uint8_t *)authority,
          10, strlen(authority), NGHTTP2_NV_FLAG_NONE },
        { (uint8_t *)":scheme",    (uint8_t *)scheme,
          7, strlen(scheme),    NGHTTP2_NV_FLAG_NONE },
        { (uint8_t *)":path",      (uint8_t *)path,
          5, strlen(path),      NGHTTP2_NV_FLAG_NONE },
    };

    nghttp2_data_provider2 *dp = NULL;
    /* Body support omitted for Phase 1 GET requests */
    (void)body; (void)body_len;

    return nghttp2_submit_request2(s->ng, NULL,
                                   hdrs, 4,
                                   dp, s);
}

int awr_h2_session_send(void *session)
{
    awr_session_t *s = (awr_session_t *)session;
    int rc = nghttp2_session_send(s->ng);
    return rc < 0 ? rc : 0;
}

int awr_h2_session_recv(void *session, const uint8_t *data, size_t len)
{
    awr_session_t *s = (awr_session_t *)session;
    ssize_t rc = nghttp2_session_mem_recv2(s->ng, data, len);
    return rc < 0 ? (int)rc : 0;
}
