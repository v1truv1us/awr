// Positive POST case for XMLHttpRequest with a URLSearchParams body. The
// polyfill stringifies URLSearchParams to application/x-www-form-urlencoded
// before handing the body to the host; this case asserts the encoding is
// preserved end-to-end through XHR.
promise_test(async () => {
  const url = 'http://127.0.0.1:18488/echo';
  const xhr = new XMLHttpRequest();
  const params = new URLSearchParams();
  params.set('a', '1');
  params.set('b', '2');
  xhr.open('POST', url);
  await new Promise((resolve, reject) => {
    xhr.addEventListener('load', resolve);
    xhr.addEventListener('error', reject);
    xhr.send(params);
  });
  assert_equals(xhr.status, 200, 'status should be 200');
  assert_equals(xhr.responseText, 'POST|a=1&b=2', 'echo body should be METHOD|URL-encoded params');
}, 'XMLHttpRequest POST with URLSearchParams body round-trips through echo server');
