promise_test(async () => {
  let message = '';
  try {
    await fetch('./xhr_basic.txt', { method: 'POST' });
  } catch (error) {
    message = String(error && error.message || error);
  }
  assert_true(message.includes('only GET'));
}, 'fetch rejects non-GET methods');

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
