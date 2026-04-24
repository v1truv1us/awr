test(() => {
  const box = document.getElementById('box');
  const rect = box.getBoundingClientRect();

  assert_true(rect.width > 0);
  assert_true(rect.height > 0);
  assert_true(rect.right >= rect.left);
  assert_true(rect.bottom >= rect.top);
}, 'getBoundingClientRect returns real terminal-cell geometry for rendered elements');
