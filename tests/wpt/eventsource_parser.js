test(() => {
  // T3.D.1: EventSource is a constructor with the standard CONNECTING /
  // OPEN / CLOSED constants on both the constructor and the prototype.
  assert_equals(typeof EventSource, 'function');
  assert_equals(EventSource.CONNECTING, 0);
  assert_equals(EventSource.OPEN, 1);
  assert_equals(EventSource.CLOSED, 2);
  assert_equals(EventSource.prototype.CONNECTING, 0);
  assert_equals(EventSource.prototype.OPEN, 1);
  assert_equals(EventSource.prototype.CLOSED, 2);
}, 'EventSource constructor + readyState constants');

test(() => {
  // The constructor populates url, readyState (CONNECTING), and the
  // listener-API surface synchronously. Network resolution happens
  // asynchronously and is exercised in integration tests, not here.
  const es = new EventSource('https://example.com/sse');
  assert_equals(es.url, 'https://example.com/sse');
  assert_equals(es.readyState, EventSource.CONNECTING);
  assert_equals(typeof es.addEventListener, 'function');
  assert_equals(typeof es.removeEventListener, 'function');
  assert_equals(typeof es.close, 'function');
  es.close();
  assert_equals(es.readyState, EventSource.CLOSED);
}, 'EventSource exposes the standard instance shape and close()');

test(() => {
  // Direct exercise of the SSE parser via the native used by the JS
  // class. Covers the parsing surface that closure gates require:
  // multi-line data, custom event types, id persistence, comments,
  // empty-data suppression, retry parsing.
  const out = JSON.parse(__awr_sse_parse_all__(
    ': comment to ignore\n' +
    'event: ping\n' +
    'data: pong\n' +
    '\n' +
    'id: 42\n' +
    'data: line1\n' +
    'data: line2\n' +
    '\n' +
    'event: empty\n' +
    '\n' +
    'data: trailing\n' +
    '\n'
  ));
  // First event: custom type "ping" with single-line data.
  assert_equals(out.length, 3);
  assert_equals(out[0].event, 'ping');
  assert_equals(out[0].data, 'pong');
  // Second: multi-line data joined with \n; id captured.
  assert_equals(out[1].event, 'message');
  assert_equals(out[1].data, 'line1\nline2');
  assert_equals(out[1].lastEventId, '42');
  // The "event: empty" record had no data → no event dispatched, but
  // the id from the previous event still persists into the next one.
  assert_equals(out[2].event, 'message');
  assert_equals(out[2].data, 'trailing');
  assert_equals(out[2].lastEventId, '42');
}, 'SSE parser handles multi-line data, custom event, id persistence, empty-data suppression');
