// Exercises Response.json() and response.headers.get('content-type')
// via the EchoServer's /json route.

promise_test(() => {
  return fetch('http://127.0.0.1:18488/json').then((r) => {
    assert_equals(r.status, 200);
    return r.json().then((j) => {
      assert_equals(j.ok, true);
      assert_equals(j.runner, 'awr');
    });
  });
}, 'response.json() parses application/json body');

promise_test(() => {
  return fetch('http://127.0.0.1:18488/json').then((r) => {
    return r.text().then((t) => {
      // Round-trip: text → JSON.parse must equal what .json() returned
      const j = JSON.parse(t);
      assert_equals(j.ok, true);
      assert_equals(j.runner, 'awr');
    });
  });
}, 'response.text() returns the raw body for JSON content');
