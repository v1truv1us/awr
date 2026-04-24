test(() => {
  assert_true(window.innerWidth > 0);
  assert_true(window.innerHeight > 0);
  assert_equals(window.screen.width, window.innerWidth);
  assert_equals(window.screen.height, window.innerHeight);
  assert_equals(window.outerWidth, window.innerWidth);
  assert_equals(window.outerHeight, window.innerHeight);
}, 'viewport dimensions reflect the terminal-backed page viewport');
