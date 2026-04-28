promise_test(async () => {
  // GET and POST are accepted per spec/subspecs/agent-browser.md §2.
  // Other HTTP methods (PUT/DELETE/PATCH/HEAD/OPTIONS) still throw.
  let message = '';
  try {
    await fetch('./xhr_basic.txt', { method: 'PUT' });
  } catch (error) {
    message = String(error && error.message || error);
  }
  assert_true(message.includes('GET and POST'));
}, 'fetch rejects methods other than GET and POST');

promise_test(async () => {
  let message = '';
  try {
    await fetch('./xhr_basic.txt', { headers: { 'x-test': '1' } });
  } catch (error) {
    message = String(error && error.message || error);
  }
  assert_true(message.includes('init.headers'));
}, 'fetch rejects unsupported init.headers');

promise_test(async () => {
  let message = '';
  try {
    await fetch({ url: './xhr_basic.txt' });
  } catch (error) {
    message = String(error && error.message || error);
  }
  assert_true(message.includes('string URLs'));
}, 'fetch rejects non-string resource inputs');

promise_test(async () => {
  // GET requests cannot carry a body — the polyfill rejects this combination.
  let message = '';
  try {
    await fetch('./xhr_basic.txt', { method: 'GET', body: 'oops' });
  } catch (error) {
    message = String(error && error.message || error);
  }
  assert_true(message.includes('GET requests cannot have a body'));
}, 'fetch rejects GET with body');

promise_test(async () => {
  // POST body must be a string or URLSearchParams; objects/FormData/streams
  // are out of MVP scope.
  let message = '';
  try {
    await fetch('./xhr_basic.txt', { method: 'POST', body: { json: 'rejected' } });
  } catch (error) {
    message = String(error && error.message || error);
  }
  assert_true(message.includes('string or URLSearchParams'));
}, 'fetch rejects POST with non-string non-URLSearchParams body');
