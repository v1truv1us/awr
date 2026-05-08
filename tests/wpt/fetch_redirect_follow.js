// fetch follows 302 redirects by default (Client.options.follow_redirects).
// Uses the EchoServer's /redirect-to?url=X route (302 to X) chained to the
// /status/{N} and /json routes so we can assert the final response.

promise_test(() => {
  // /redirect-to?url=/status/200 → 302 → /status/200 → 200 OK
  return fetch('http://127.0.0.1:18488/redirect-to?url=/status/200').then((r) => {
    assert_equals(r.status, 200, 'should land on /status/200 with 200 OK');
    assert_equals(r.ok, true);
  });
}, 'fetch follows a single 302 to a 200 endpoint');

promise_test(() => {
  // /redirect-to?url=/json → 302 → /json → 200 + application/json body
  return fetch('http://127.0.0.1:18488/redirect-to?url=/json').then((r) => {
    assert_equals(r.status, 200);
    return r.json().then((j) => {
      assert_equals(j.ok, true);
      assert_equals(j.runner, 'awr');
    });
  });
}, 'fetch follows a 302 then parses the final JSON body');

promise_test(() => {
  // After following the redirect, response.url must reflect the FINAL URL,
  // not the original. Some agents rely on this for correctness.
  return fetch('http://127.0.0.1:18488/redirect-to?url=/json').then((r) => {
    assert_true(r.url.indexOf('/json') >= 0, 'final url should reach /json (got: ' + r.url + ')');
    assert_false(r.url.indexOf('redirect-to') >= 0, 'final url should not reflect /redirect-to');
  });
}, 'fetch sets response.url to the final hop after redirect');

promise_test(() => {
  // Redirect to /status/404 — 302 → 404. The post-redirect status surfaces.
  return fetch('http://127.0.0.1:18488/redirect-to?url=/status/404').then((r) => {
    assert_equals(r.status, 404);
    assert_equals(r.ok, false);
  });
}, 'fetch redirect chain ending in 404 surfaces 404 status');
