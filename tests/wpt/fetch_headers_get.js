// Response.headers.get() — case-insensitive lookup of response headers.
// Uses the EchoServer's /json route (Content-Type: application/json) and
// the default /echo route (Content-Type: text/plain; charset=utf-8).

promise_test(() => {
  return fetch('http://127.0.0.1:18488/json').then((r) => {
    assert_equals(typeof r.headers.get, 'function', 'headers.get should be a function');
    assert_equals(r.headers.get('content-type'), 'application/json',
      'lowercase lookup should return application/json');
  });
}, 'response.headers.get returns the content-type for /json');

promise_test(() => {
  return fetch('http://127.0.0.1:18488/json').then((r) => {
    // Header lookup MUST be case-insensitive per Fetch spec.
    assert_equals(r.headers.get('Content-Type'), 'application/json');
    assert_equals(r.headers.get('CONTENT-TYPE'), 'application/json');
    assert_equals(r.headers.get('cOnTeNt-TyPe'), 'application/json');
  });
}, 'response.headers.get is case-insensitive');

promise_test(() => {
  return fetch('http://127.0.0.1:18488/json').then((r) => {
    // Missing header returns null, not undefined or empty string.
    assert_equals(r.headers.get('x-does-not-exist'), null);
  });
}, 'response.headers.get returns null for missing header');

promise_test(() => {
  return fetch('http://127.0.0.1:18488/echo').then((r) => {
    // Default route emits text/plain; charset=utf-8.
    const ct = r.headers.get('content-type');
    assert_true(ct !== null);
    assert_true(ct.indexOf('text/plain') >= 0,
      'echo content-type should contain text/plain (got: ' + ct + ')');
  });
}, 'response.headers.get returns text/plain for /echo');
