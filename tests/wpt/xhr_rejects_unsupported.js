test(() => {
  const xhr = new XMLHttpRequest();
  let message = '';
  try {
    xhr.open('POST', './xhr_basic.txt');
  } catch (error) {
    message = String(error && error.message || error);
  }
  assert_true(message.includes('only async GET'));
}, 'XMLHttpRequest rejects non-GET methods');

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
  const xhr = new XMLHttpRequest();
  xhr.open('GET', './xhr_basic.txt');
  let message = '';
  try {
    xhr.send('body');
  } catch (error) {
    message = String(error && error.message || error);
  }
  assert_true(message.includes('request bodies'));
}, 'XMLHttpRequest rejects request bodies');
