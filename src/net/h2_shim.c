/**
 * h2_shim.c — nghttp2 client session shim for AWR Phase 1.
 *
 * Uses the non-deprecated nghttp2_ssize-based send/recv callbacks
 * (introduced in nghttp2 1.60.0, present in 1.68.1).
 */
#include "h2_shim.h"
#include <nghttp2/nghttp2.h>
#include <stdlib.h>
#include <string.h>

/* ── Constants ────────────────────────────────────────────────────────── */

#define AWR_H2_MAX_STREAMS   64
#define AWR_H2_BODY_INIT_CAP (64 * 1024)   /* 64 KB initial body buffer  */
#define AWR_H2_HDR_INIT_CAP  (4  * 1024)   /* 4  KB initial header buffer */

/* ── Per-stream state ─────────────────────────────────────────────────── */

typedef struct {
    int32_t  stream_id;
    int      in_use;
    int      complete;   /* 1 after END_STREAM received */
    uint16_t status;

    uint8_t *body;
    size_t   body_len;
    size_t   body_cap;

    char    *hdr_buf;    /* name\0value\0 pairs */
    size_t   hdr_len;
    size_t   hdr_cap;
} stream_slot_t;

/* ── Session struct ───────────────────────────────────────────────────── */

struct awr_h2_session {
    nghttp2_session *ng;
    awr_h2_send_cb   send_cb;
    awr_h2_recv_cb   recv_cb;
    void            *user_data;
    stream_slot_t    slots[AWR_H2_MAX_STREAMS];
};

/* ── Internal helpers ─────────────────────────────────────────────────── */

static stream_slot_t *find_slot(awr_h2_session_t *s, int32_t sid) {
    for (int i = 0; i < AWR_H2_MAX_STREAMS; i++)
        if (s->slots[i].in_use && s->slots[i].stream_id == sid)
            return &s->slots[i];
    return NULL;
}

static stream_slot_t *alloc_slot(awr_h2_session_t *s, int32_t sid) {
    for (int i = 0; i < AWR_H2_MAX_STREAMS; i++) {
        if (!s->slots[i].in_use) {
            memset(&s->slots[i], 0, sizeof(stream_slot_t));
            s->slots[i].in_use    = 1;
            s->slots[i].stream_id = sid;
            return &s->slots[i];
        }
    }
    return NULL;
}

static int slot_append_body(stream_slot_t *sl,
                             const uint8_t *data, size_t len) {
    if (sl->body_len + len > sl->body_cap) {
        size_t ncap = sl->body_cap ? sl->body_cap * 2 : AWR_H2_BODY_INIT_CAP;
        while (ncap < sl->body_len + len) ncap *= 2;
        uint8_t *nb = (uint8_t *)realloc(sl->body, ncap);
        if (!nb) return -1;
        sl->body     = nb;
        sl->body_cap = ncap;
    }
    memcpy(sl->body + sl->body_len, data, len);
    sl->body_len += len;
    return 0;
}

static int slot_append_hdr(stream_slot_t  *sl,
                            const uint8_t  *name,  size_t nlen,
                            const uint8_t  *value, size_t vlen) {
    size_t need = nlen + 1 + vlen + 1;
    if (sl->hdr_len + need > sl->hdr_cap) {
        size_t ncap = sl->hdr_cap ? sl->hdr_cap * 2 : AWR_H2_HDR_INIT_CAP;
        while (ncap < sl->hdr_len + need) ncap *= 2;
        char *nb = (char *)realloc(sl->hdr_buf, ncap);
        if (!nb) return -1;
        sl->hdr_buf = nb;
        sl->hdr_cap = ncap;
    }
    memcpy(sl->hdr_buf + sl->hdr_len, name,  nlen); sl->hdr_len += nlen;
    sl->hdr_buf[sl->hdr_len++] = '\0';
    memcpy(sl->hdr_buf + sl->hdr_len, value, vlen); sl->hdr_len += vlen;
    sl->hdr_buf[sl->hdr_len++] = '\0';
    return 0;
}

/* ── nghttp2 callbacks ────────────────────────────────────────────────── */

static nghttp2_ssize cb_send(nghttp2_session *session,
                              const uint8_t *data, size_t length,
                              int flags, void *user_data) {
    (void)session; (void)flags;
    awr_h2_session_t *s = (awr_h2_session_t *)user_data;
    int n = s->send_cb(data, length, s->user_data);
    if (n < 0) return NGHTTP2_ERR_CALLBACK_FAILURE;
    return (nghttp2_ssize)n;
}

static nghttp2_ssize cb_recv(nghttp2_session *session,
                              uint8_t *buf, size_t length,
                              int flags, void *user_data) {
    (void)session; (void)flags;
    awr_h2_session_t *s = (awr_h2_session_t *)user_data;
    int n = s->recv_cb(buf, length, s->user_data);
    if (n < 0) return NGHTTP2_ERR_CALLBACK_FAILURE;
    if (n == 0) return NGHTTP2_ERR_WOULDBLOCK;
    return (nghttp2_ssize)n;
}

static int cb_on_header(nghttp2_session *session,
                         const nghttp2_frame *frame,
                         const uint8_t *name,  size_t namelen,
                         const uint8_t *value, size_t valuelen,
                         uint8_t flags, void *user_data) {
    (void)session; (void)flags;
    if (frame->hd.type != NGHTTP2_HEADERS) return 0;
    awr_h2_session_t *s = (awr_h2_session_t *)user_data;
    stream_slot_t *sl = find_slot(s, frame->hd.stream_id);
    if (!sl) {
        sl = alloc_slot(s, frame->hd.stream_id);
        if (!sl) return NGHTTP2_ERR_CALLBACK_FAILURE;
    }
    /* Parse :status pseudo-header */
    if (namelen == 7 && memcmp(name, ":status", 7) == 0) {
        uint16_t v = 0;
        for (size_t i = 0; i < valuelen; i++)
            v = (uint16_t)(v * 10 + (value[i] - '0'));
        sl->status = v;
        return 0;
    }
    return slot_append_hdr(sl, name, namelen, value, valuelen) == 0
           ? 0 : NGHTTP2_ERR_CALLBACK_FAILURE;
}

static int cb_on_data_chunk(nghttp2_session *session, uint8_t flags,
                              int32_t stream_id,
                              const uint8_t *data, size_t len,
                              void *user_data) {
    (void)session; (void)flags;
    awr_h2_session_t *s = (awr_h2_session_t *)user_data;
    stream_slot_t *sl = find_slot(s, stream_id);
    if (!sl) return 0;
    return slot_append_body(sl, data, len) == 0
           ? 0 : NGHTTP2_ERR_CALLBACK_FAILURE;
}

static int cb_on_stream_close(nghttp2_session *session, int32_t stream_id,
                               uint32_t error_code, void *user_data) {
    (void)session; (void)error_code;
    awr_h2_session_t *s = (awr_h2_session_t *)user_data;
    stream_slot_t *sl = find_slot(s, stream_id);
    if (sl) sl->complete = 1;
    return 0;
}

/* ── Public API ───────────────────────────────────────────────────────── */

awr_h2_session_t *awr_h2_session_new(awr_h2_send_cb send_cb,
                                      awr_h2_recv_cb recv_cb,
                                      void          *user_data) {
    awr_h2_session_t *s = (awr_h2_session_t *)calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->send_cb   = send_cb;
    s->recv_cb   = recv_cb;
    s->user_data = user_data;

    nghttp2_session_callbacks *cbs;
    if (nghttp2_session_callbacks_new(&cbs) != 0) { free(s); return NULL; }

    nghttp2_session_callbacks_set_send_callback2(cbs, cb_send);
    nghttp2_session_callbacks_set_recv_callback2(cbs, cb_recv);
    nghttp2_session_callbacks_set_on_header_callback(cbs, cb_on_header);
    nghttp2_session_callbacks_set_on_data_chunk_recv_callback(cbs, cb_on_data_chunk);
    nghttp2_session_callbacks_set_on_stream_close_callback(cbs, cb_on_stream_close);

    int rc = nghttp2_session_client_new(&s->ng, cbs, s);
    nghttp2_session_callbacks_del(cbs);
    if (rc != 0) { free(s); return NULL; }

    /* Submit Chrome-132 SETTINGS — flushed on first awr_h2_session_run() */
    nghttp2_settings_entry iv[] = {
        { NGHTTP2_SETTINGS_HEADER_TABLE_SIZE,      65536   },
        { NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS, 1000    },
        { NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE,    6291456 },
        { NGHTTP2_SETTINGS_MAX_HEADER_LIST_SIZE,   262144  },
    };
    nghttp2_submit_settings(s->ng, NGHTTP2_FLAG_NONE,
                             iv, sizeof(iv) / sizeof(iv[0]));
    return s;
}

void awr_h2_session_free(awr_h2_session_t *sess) {
    if (!sess) return;
    nghttp2_session_del(sess->ng);
    for (int i = 0; i < AWR_H2_MAX_STREAMS; i++) {
        free(sess->slots[i].body);
        free(sess->slots[i].hdr_buf);
    }
    free(sess);
}

int32_t awr_h2_submit_get(awr_h2_session_t *sess,
                           const char *method,
                           const char *scheme,
                           const char *authority,
                           const char *path) {
    nghttp2_nv nva[4];
    nva[0].name     = (uint8_t *)":method";    nva[0].namelen  = 7;
    nva[0].value    = (uint8_t *)method;       nva[0].valuelen = strlen(method);
    nva[0].flags    = NGHTTP2_NV_FLAG_NONE;

    nva[1].name     = (uint8_t *)":scheme";    nva[1].namelen  = 7;
    nva[1].value    = (uint8_t *)scheme;       nva[1].valuelen = strlen(scheme);
    nva[1].flags    = NGHTTP2_NV_FLAG_NONE;

    nva[2].name     = (uint8_t *)":authority"; nva[2].namelen  = 10;
    nva[2].value    = (uint8_t *)authority;    nva[2].valuelen = strlen(authority);
    nva[2].flags    = NGHTTP2_NV_FLAG_NONE;

    nva[3].name     = (uint8_t *)":path";      nva[3].namelen  = 5;
    nva[3].value    = (uint8_t *)path;         nva[3].valuelen = strlen(path);
    nva[3].flags    = NGHTTP2_NV_FLAG_NONE;

    /* alloc_slot first so the callback can find it when headers arrive */
    int32_t sid = nghttp2_submit_request(sess->ng, NULL, nva, 4, NULL, NULL);
    if (sid < 0) return -1;
    if (!alloc_slot(sess, sid)) return -1;
    return sid;
}

int awr_h2_session_run(awr_h2_session_t *sess) {
    int rc = nghttp2_session_send(sess->ng);
    if (rc != 0) return rc;
    rc = nghttp2_session_recv(sess->ng);
    if (rc == NGHTTP2_ERR_EOF) return 0;   /* clean connection close */
    return rc;
}

int awr_h2_stream_complete(awr_h2_session_t *sess, int32_t stream_id) {
    stream_slot_t *sl = find_slot(sess, stream_id);
    return (sl && sl->complete) ? 1 : 0;
}

int awr_h2_get_response(awr_h2_session_t  *sess,
                         int32_t            stream_id,
                         awr_h2_response_t *out) {
    stream_slot_t *sl = find_slot(sess, stream_id);
    if (!sl || !sl->complete) return -1;
    out->status          = sl->status;
    out->body            = sl->body;
    out->body_len        = sl->body_len;
    out->headers_buf     = sl->hdr_buf;
    out->headers_buf_len = sl->hdr_len;
    /* Transfer ownership to caller */
    sl->body    = NULL;
    sl->hdr_buf = NULL;
    sl->in_use  = 0;
    return 0;
}
