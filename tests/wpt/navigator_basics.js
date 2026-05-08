test(() => {
  assert_equals(typeof navigator, 'object');
  assert_equals(typeof navigator.userAgent, 'string');
  assert_true(navigator.userAgent.length > 0);
  assert_equals(typeof navigator.language, 'string');
  assert_equals(navigator.onLine, true);
  // Phase C.9 wired document.cookie to the page's cookie jar, so
  // navigator.cookieEnabled now reflects that state and is true.
  assert_equals(navigator.cookieEnabled, true);
}, 'navigator exposes the basic platform identity surface');

test(() => {
  assert_true(Array.isArray(navigator.languages));
  assert_true(navigator.languages.length >= 1);
  assert_equals(navigator.languages[0], navigator.language);
}, 'navigator.languages is an array starting with navigator.language');
