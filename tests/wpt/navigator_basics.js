test(() => {
  assert_equals(typeof navigator, 'object');
  assert_equals(typeof navigator.userAgent, 'string');
  assert_true(navigator.userAgent.length > 0);
  assert_equals(typeof navigator.language, 'string');
  assert_equals(navigator.onLine, true);
  assert_equals(navigator.cookieEnabled, false);
}, 'navigator exposes the basic platform identity surface');

test(() => {
  assert_true(Array.isArray(navigator.languages));
  assert_true(navigator.languages.length >= 1);
  assert_equals(navigator.languages[0], navigator.language);
}, 'navigator.languages is an array starting with navigator.language');
