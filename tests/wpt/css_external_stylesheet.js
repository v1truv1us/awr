test(() => {
  const el = document.getElementById('from-external-css');
  const style = getComputedStyle(el);
  assert_equals(style.display, 'none');
  assert_equals(style.getPropertyValue('visibility'), 'hidden');
}, 'external stylesheet rules participate in getComputedStyle');
