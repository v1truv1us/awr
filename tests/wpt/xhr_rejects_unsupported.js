test(() => {
  // GET and POST are accepted per spec/subspecs/agent-browser.md §2.
  // Other methods (PUT/DELETE/PATCH/HEAD/OPTIONS) still throw at open().
  const xhr = new XMLHttpRequest();
  let message = '';
  try {
    xhr.open('PUT', './xhr_basic.txt');
  } catch (error) {
    message = String(error && error.message || error);
  }
  assert_true(message.includes('GET and POST'));
}, 'XMLHttpRequest rejects methods other than GET and POST');

test(() => {
  const xhr = new XMLHttpRequest();
  let message = '';
  try {
    xhr.open('GET', './xhr_basic.txt', false);
  } catch (error) {
    message = String(error && error.message || error);
  }
  assert_true(message.includes('sync mode'));
}, 'XMLHttpRequest rejects sync mode');

test(() => {
  const xhr = new XMLHttpRequest();
  xhr.open('GET', './xhr_basic.txt');
  let message = '';
  try {
    xhr.setRequestHeader('x-test', '1');
  } catch (error) {
    message = String(error && error.message || error);
  }
  assert_true(message.includes('request headers'));
}, 'XMLHttpRequest rejects request headers');

test(() => {
  // GET requests still cannot carry a body — the new restriction is on the
  // method/body combination, not on bodies existing in general.
  const xhr = new XMLHttpRequest();
  xhr.open('GET', './xhr_basic.txt');
  let message = '';
  try {
    xhr.send('body');
  } catch (error) {
    message = String(error && error.message || error);
  }
  assert_true(message.includes('GET requests cannot have a body'));
}, 'XMLHttpRequest rejects GET with body');
