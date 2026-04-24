promise_test(async () => {
  const response = await fetch('./xhr_basic.txt');
  const text = await response.text();
  assert_equals(response.status, 200);
  assert_equals(text, 'hello xhr\n');
  assert_true(typeof response.headers.get === 'function');
}, 'fetch performs a basic GET and returns a Response-like object');
