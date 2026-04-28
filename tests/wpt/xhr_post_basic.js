// Positive POST case for XMLHttpRequest. Open + send a string body, wait
// for load, assert the echo body matches METHOD|BODY. This proves that
// XHR's polyfill in src/dom/bridge.zig now routes POST through fetch with
// the right init shape.
promise_test(async () => {
  const url = 'http://127.0.0.1:18488/echo';
  const xhr = new XMLHttpRequest();
  xhr.open('POST', url);
  await new Promise((resolve, reject) => {
    xhr.addEventListener('load', resolve);
    xhr.addEventListener('error', reject);
    xhr.send('hello=world');
  });
  assert_equals(xhr.status, 200, 'status should be 200');
  assert_equals(xhr.responseText, 'POST|hello=world', 'echo body should be METHOD|BODY');
}, 'XMLHttpRequest POST with string body round-trips through echo server');
