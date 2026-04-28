// Positive POST case for fetch() with a URLSearchParams body. The polyfill
// stringifies URLSearchParams to application/x-www-form-urlencoded form
// before passing through to the host; this case asserts the encoding is
// preserved end-to-end.
promise_test(async () => {
  const url = 'http://127.0.0.1:18488/echo';
  const params = new URLSearchParams();
  params.set('a', '1');
  params.set('b', '2');
  const response = await fetch(url, { method: 'POST', body: params });
  assert_equals(response.status, 200, 'status should be 200');
  const text = await response.text();
  assert_equals(text, 'POST|a=1&b=2', 'echo body should be METHOD|URL-encoded params');
}, 'fetch() POST with URLSearchParams body round-trips through echo server');
