// Exercises xhr.status across the canonical 2xx, 3xx, 4xx, 5xx codes
// via the EchoServer's /status/{N} route. Doubles as B1 regression
// coverage at the XHR layer (204/304 must surface, not hang).

function fetchStatus(code) {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.addEventListener('load', () => resolve(xhr.status));
    xhr.addEventListener('error', reject);
    xhr.open('GET', 'http://127.0.0.1:18488/status/' + code);
    xhr.send();
  });
}

promise_test(async () => {
  assert_equals(await fetchStatus(200), 200);
}, 'xhr.status reports 200 OK');

promise_test(async () => {
  assert_equals(await fetchStatus(204), 204);
}, 'xhr.status reports 204 No Content (B1 regression)');

promise_test(async () => {
  assert_equals(await fetchStatus(304), 304);
}, 'xhr.status reports 304 Not Modified (B1 regression)');

promise_test(async () => {
  assert_equals(await fetchStatus(404), 404);
}, 'xhr.status reports 404 Not Found');

promise_test(async () => {
  assert_equals(await fetchStatus(500), 500);
}, 'xhr.status reports 500 Internal Server Error');

promise_test(() => {
  // load event must fire even for non-2xx statuses — onerror is reserved
  // for network/transport errors, NOT HTTP error statuses. This matches
  // the Fetch spec's "ok" boundary semantics.
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.addEventListener('load', () => {
      if (xhr.status === 404) resolve();
      else reject(new Error('expected 404, got ' + xhr.status));
    });
    xhr.addEventListener('error', () => reject(new Error('error event fired for HTTP error')));
    xhr.open('GET', 'http://127.0.0.1:18488/status/404');
    xhr.send();
  });
}, 'xhr.onload (not onerror) fires for HTTP 4xx response');
