test(() => {
  const el = document.getElementById('node');
  assert_equals(el.dataset.kind, 'primary');
  assert_equals(el.dataset.userId, 'u-42');
}, 'dataset reads attributes with camelCase ↔ data-kebab-case mapping');

test(() => {
  const el = document.getElementById('node');
  el.dataset.flag = 'on';
  assert_equals(el.getAttribute('data-flag'), 'on');
  el.dataset.multiPart = 'x';
  assert_equals(el.getAttribute('data-multi-part'), 'x');
}, 'dataset assignment writes data-kebab-case attributes');
