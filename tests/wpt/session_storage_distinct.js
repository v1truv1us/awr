test(() => {
  localStorage.clear();
  sessionStorage.clear();
  sessionStorage.setItem('scope', 'session');
  localStorage.setItem('scope', 'local');

  assert_equals(sessionStorage.getItem('scope'), 'session');
  assert_equals(localStorage.getItem('scope'), 'local');
}, 'sessionStorage and localStorage do not alias the same store');
