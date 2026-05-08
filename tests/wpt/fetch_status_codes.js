// Exercises Response.status / response.ok across success and error
// status codes via the EchoServer's /status/{N} route.

promise_test(() => {
  return fetch('http://127.0.0.1:18488/status/200').then((r) => {
    assert_equals(r.status, 200);
    assert_equals(r.ok, true);
  });
}, 'fetch /status/200 → status=200, ok=true');

promise_test(() => {
  return fetch('http://127.0.0.1:18488/status/204').then((r) => {
    assert_equals(r.status, 204);
    assert_equals(r.ok, true);
  });
}, 'fetch /status/204 → status=204, ok=true (B1 regression)');

promise_test(() => {
  return fetch('http://127.0.0.1:18488/status/304').then((r) => {
    assert_equals(r.status, 304);
    // 304 is not 2xx, so ok must be false. Body is empty either way.
    assert_equals(r.ok, false);
  });
}, 'fetch /status/304 → status=304, ok=false (B1 regression)');

promise_test(() => {
  return fetch('http://127.0.0.1:18488/status/404').then((r) => {
    assert_equals(r.status, 404);
    assert_equals(r.ok, false);
  });
}, 'fetch /status/404 → status=404, ok=false');

promise_test(() => {
  return fetch('http://127.0.0.1:18488/status/500').then((r) => {
    assert_equals(r.status, 500);
    assert_equals(r.ok, false);
  });
}, 'fetch /status/500 → status=500, ok=false');
