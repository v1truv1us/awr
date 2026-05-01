test(() => {
  assert_equals(document.visibilityState, 'visible');
  assert_equals(document.hidden, false);
}, 'document.visibilityState defaults to visible and hidden is false');
