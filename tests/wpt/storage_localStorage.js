test(() => {
  localStorage.clear();
  assert_equals(localStorage.length, 0);

  localStorage.setItem('alpha', '1');
  localStorage.setItem('beta', '2');

  assert_equals(localStorage.getItem('alpha'), '1');
  assert_equals(localStorage.getItem('beta'), '2');
  assert_equals(localStorage.length, 2);
  assert_equals(localStorage.key(0), 'alpha');
  assert_equals(localStorage.key(1), 'beta');

  localStorage.removeItem('alpha');
  assert_equals(localStorage.getItem('alpha'), null);
  assert_equals(localStorage.length, 1);

  localStorage.clear();
  assert_equals(localStorage.length, 0);
}, 'localStorage supports setItem/getItem/removeItem/clear/length/key');

test(() => {
  localStorage.clear();
  localStorage.setItem('gamma', '3');
  assert_equals(localStorage.getItem('gamma'), '3');
}, 'localStorage mutations update the current page store');
